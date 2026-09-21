# Combat Engine — Durable Audit

> Read-only architecture audit performed against LIVE Supabase on 2026-09-19.
> This document records the current combat pipeline and the minimum structural prerequisite for ACS.
> It does not change gameplay rules by itself.

## 1. Current authoritative pipeline

LIVE combat currently converges on the V2 path:

```
combat_battles
  -> combat_individual_units (round state)
  -> combat_round_snapshot_units
  -> combat_shots + rapid-fire expansion
  -> combat_round_damage
  -> per-target damage resolution
  -> apply_combat_round_damage()
  -> finish_combat_round_v1()
  -> combat_rounds
  -> create_combat_next_round()
  -> repeat through round 6
  -> run_expedition_combat() finalization
  -> resolve_attack_arrival() post-combat settlement
       -> attacker fleet survivors
       -> stationary planet ships/defences
       -> loot
       -> defence repair
       -> debris
       -> attacker RETURNING
```

`combat_round_units` is not part of this active path. The current state authority is `combat_individual_units`.

## 2. LIVE battle model

`combat_battles` currently represents exactly one attacking fleet against one target planet:

- `fleet_id` = the attacking fleet.
- `attacker_player_id` = owner of that fleet.
- `defender_planet_id` = target planet.
- Result/count columns aggregate one attacker side and one defender side.
- There is no defender-fleet identity in the battle.

`resolve_combat(p_fleet_id)` locks the attack movement, creates one battle, and initializes:

- attacker units from `fleet_movement_ships`;
- defender ships from `planet_ships`;
- defender fixed defences from `planet_defenses`.

`initialize_individual_combat_units()` resolves combat stats using the attacker and defender planet owners, but writes only `side`, `unit_type`, `unit_id`, and `unit_number` as unit identity.

## 3. Why ACS cannot be bolted onto the current model

The current combat identity is insufficient for multiple defending fleets.

`combat_individual_units` has a uniqueness key equivalent to:

```
battle_id + round_number + side + unit_type + unit_id + unit_number
```

Two support fleets can legitimately contain the same ship type and both have unit number 1. They would collide if both were simply inserted as `DEFENDER` units.

The same ambiguity propagates into:

- `combat_round_snapshot_units`;
- `combat_shots` source/target identity;
- `combat_round_damage` target identity;
- round aggregates;
- final survivor settlement.

Most importantly, `resolve_attack_arrival()` currently settles the single attacking fleet and the target planet. It has no durable mapping from a combat survivor to a support fleet's owner/origin, so it cannot safely return multiple ACS fleets independently.

**Conclusion:** do not patch ACS into `resolve_attack_arrival()` by inspecting mission rows. The combat model must first gain explicit participant identity.

## 4. Minimum multi-defender model

The smallest durable extension is an explicit battle-participant layer, without replacing the current battle table.

### Proposed `combat_battle_participants`

One row per combat participant:

- `id uuid primary key`
- `battle_id uuid not null`
- `side text` — `ATTACKER` / `DEFENDER`
- `participant_type text` — `FLEET` / `PLANET`
- `fleet_id uuid nullable` — populated for mobile fleet participants
- `player_id uuid not null`
- `origin_planet_id uuid nullable` — required for fleet participants
- `mission_type text nullable`
- `created_at timestamptz`

Recommended invariants:

- one attacker fleet participant per battle in the first ACS-compatible version;
- zero or one stationary `PLANET` defender participant;
- zero or more defending `FLEET` participants;
- fleet participant identity is unique per battle;
- `FLEET` participants require `fleet_id`, `player_id`, and `origin_planet_id`;
- `PLANET` participant requires the target planet identity through the battle and does not require an origin return.

This deliberately reuses `fleet_movements` as the movement source of truth. No second fleet/support state table is required.

### Participant identity in combat units

Add `participant_id` to:

- `combat_individual_units`
- `combat_round_snapshot_units`
- `combat_shots` (source and target participant identity)
- `combat_round_damage` (target participant identity)

Then the effective unit identity becomes:

```
participant_id + unit_type + unit_id + unit_number
```

The round number remains part of the round-state key.

This is the minimum change that makes two defender fleets with identical ships unambiguous while preserving the existing V2 shot/damage machinery.

## 5. Round engine compatibility

The current round engine is already structurally suitable for several defenders because targeting uses the snapshot and the side is currently a coarse grouping.

The required change is identity propagation, not a second combat engine:

```
snapshot participant-aware units
    ↓
shots carry source + target participant
    ↓
damage ledger carries target participant
    ↓
damage resolution locks that participant's target unit
    ↓
round state aggregates by side for battle result
    ↓
participant-level survivors remain available for settlement
```

The existing simultaneous-damage property must remain:

- snapshots are the source for shot generation;
- pending damage is accumulated before state application;
- live unit state is not consulted to create a new shot inside the same round.

## 6. Post-combat settlement

The current `resolve_attack_arrival()` performs all single-battle settlement in one transaction path:

1. update attacker movement ships from final combat units;
2. update stationary planet ships;
3. update stationary planet defences;
4. apply attacker loot;
5. repair destroyed planet defences;
6. create debris;
7. put the attack fleet into `RETURNING`.

ACS requires that this be split conceptually into participant settlement while preserving the existing single-attacker semantics:

- attacker fleet: surviving ships -> its own `fleet_movement_ships`;
- stationary planet participant: surviving ships/defences -> target planet;
- each defending fleet participant: surviving ships -> its own `fleet_movement_ships`;
- each surviving defending fleet: `HOLDING` -> `RETURNING` using its persisted movement timing;
- destroyed fleet participant: no surviving ships to return, but its movement/battle result remains attributable;
- loot remains attached to the attacking fleet only;
- defence repair remains attached to stationary planet defences only;
- debris is generated once per battle.

No ACS settlement should mutate another player's fleet or planet by inference from `player_id` alone; the participant's `fleet_id` and `origin_planet_id` are the durable settlement keys.

## 7. Existing result/summary limitations

`combat_rounds` and `combat_battles` aggregate defender counts as one side. That can remain the battle-level result representation for the first multi-defender implementation, but participant-level survival must be queryable from the unit/participant relationship.

Do not make `combat_battles` contain one column per defender fleet. That would encode a variable-size ACS battle into a fixed-width row and would not scale.

## 8. Existing post-combat functions audited

### `run_expedition_combat()`
- drives rounds 1–6 through `process_combat_round_v2()`;
- derives the final battle result from aggregate attacker/defender alive counts;
- writes final aggregate counts to `combat_battles`.

The orchestration can remain aggregate-side aware, provided participant identity is preserved below it.

### `apply_attack_loot()`
- correctly treats loot as an attacker-fleet transaction;
- locks the battle and attacker fleet;
- uses the attack arrival timestamp for resource settlement;
- is not a defender-participant settlement function.

For ACS, keep this semantic unchanged.

### `repair_defenses_after_combat()`
- derives destroyed stationary defences from the combat result;
- writes repaired quantities back to the target planet;
- should continue to operate only on the stationary planet participant.

### `create_combat_debris()`
- is battle-scoped and idempotent through `combat_debris_generations`;
- should remain battle-scoped for ACS.

## 9. Additional observations

- `combat_unit_state` exists in LIVE but is not part of the audited active V2 pipeline; do not revive it as an ACS shortcut without a separate audit.
- `finish_combat_round_v1` is still the active round-closing function despite its legacy name. Renaming is hygiene, not a prerequisite for ACS participant identity.
- The audited combat tables have RLS enabled in LIVE. Their exact policies were not expanded in this bounded architecture audit; final security/RLS review remains a separate project phase unless a concrete exposed-access defect is encountered.
- The current individual-unit model is intentionally one row per physical combat unit. The ACS extension should preserve that granularity rather than switching to aggregate quantities.

## 10. ACS prerequisite decision

**CLOSED for audit/design:** ACS must use explicit combat participants and participant-aware unit identity.

**OPEN for implementation:**

1. choose exact participant schema/constraints;
2. write a forward-only migration;
3. migrate/initialize current single-attacker battles into the participant model without breaking historical records;
4. update combat initialization, snapshots, shots, damage and finalization to carry participant identity;
5. update arrival settlement for per-fleet survivor return;
6. add regression fixtures for one attacker + planet and one attacker + planet + two support fleets;
7. only then implement `start_acs_hold` / `start_defend`.

### Non-goals

- no ACS dispatch implementation in this audit;
- no alliance/buddy system invented;
- no combat-rule rewrite;
- no second combat engine;
- no migration-history rewrite;
- no changes to live schema were made by this audit.


## 11. Participant schema migration — 2026-09-19

Implemented forward-only migration 20260919070000_add_combat_battle_participants.

### Durable identity added

combat_battle_participants now provides one stable identity per battle participant with:

- ATTACKER/FLEET support for the existing mobile attacker;
- DEFENDER/PLANET for the stationary target;
- DEFENDER/FLEET for future ACS/HOLDING fleets;
- player_id, fleet_id, planet_id, and origin_planet_id for deterministic ownership/settlement;
- mission_type retained as movement provenance rather than as the participant identity.

Participant-aware nullable foreign keys are now present on:

- combat_individual_units.participant_id;
- combat_round_snapshot_units.participant_id;
- combat_shots.attacker_participant_id;
- combat_shots.target_participant_id;
- combat_round_damage.target_participant_id.

### Compatibility boundary

The existing combat writers still operate unchanged. The old unit uniqueness constraints were intentionally not removed yet. This migration therefore adds the identity layer without pretending that ACS is implemented. Historical rows remain valid with participant_id NULL.

The next migration must, in one controlled step:

1. create/backfill participants for the active single-attacker battle path;
2. populate participant IDs through initialization/snapshot/shot/damage writers;
3. replace the old unit uniqueness keys with participant-aware keys;
4. add participant-aware regression fixtures;
5. only then enable multiple defending fleet participants.

LIVE verification after application: combat_battle_participants exists and currently contains 0 rows; no historical combat data was rewritten by this migration.


## 12. Participant propagation — 2026-09-19

The next forward-only step is now implemented in LIVE and checked into
`supabase/migrations/20260919080000_propagate_combat_participants_v2.sql`.

The existing V2 single-attacker + stationary-planet behavior remains the combat model. The change is identity propagation only:

```
resolve_combat()
  -> ATTACKER/FLEET participant
  -> DEFENDER/PLANET participant
  -> combat_individual_units.participant_id
  -> combat_round_snapshot_units.participant_id
  -> combat_shots.attacker_participant_id / target_participant_id
  -> combat_round_damage.target_participant_id
  -> participant-aware damage application
  -> participant-aware final attacker/planet settlement
```

Updated LIVE writers:

- `resolve_combat()`
- `initialize_individual_combat_units()`
- `create_combat_round_snapshot()`
- `generate_combat_round_v2()`
- `expand_rapidfire_chain_v2()`
- `calculate_combat_round_pending_damage()`
- `apply_combat_round_damage()`
- `create_combat_next_round()`
- `resolve_attack_arrival()`

The settlement path now explicitly resolves the attacker fleet participant and stationary planet participant before applying survivors. The existing loot, defence repair, debris and return semantics are unchanged.

### Deliberate compatibility boundary

The old unit/snapshot uniqueness constraints are still present. They have **not** been replaced yet. Historical combat rows remain untouched and may still have NULL participant IDs.

This means the participant layer is now genuinely used by the current combat path, but multi-fleet ACS is still not enabled. The next safe step is regression coverage for a fresh single-attacker battle, followed by a controlled replacement of the old uniqueness keys with participant-aware keys.

### OGameX adaptation note

The reference check against current OGameX confirms the architectural direction: its battle engine tracks defending fleets separately and its Rust engine explicitly supports multiple attacker/defender fleets with per-fleet identity. L.G.I. is not importing OGameX's PHP/Rust implementation or gameplay rules; only the durable participant-attribution pattern is being adapted.


## 13. Participant propagation regression fixture — 2026-09-19

Added `supabase/tests/combat_participant_propagation.sql`.

The fixture is fully transactional and rolls back all generated battle/fleet/planet/RF changes. It creates a fresh single-attacker + stationary-planet combat and exercises the real V2 pipeline.

Verified LIVE with **15/15 PASS**:

| Stage | Result |
|---|---|
| Exactly two participants | PASS |
| Unit initialization | PASS — 30/30 units attributed |
| Unit participant correctness | PASS — 0 mismatches |
| Snapshots | PASS — 30/30 attributed |
| Snapshot participant correctness | PASS — 0 mismatches |
| Initial shots | PASS — 162 attributed shots |
| Shot NULL participant check | PASS — 0 |
| Rapidfire chain | PASS — 142 RF shots attributed |
| Damage ledger | PASS — 162 rows with correct target participant |
| Damage ledger NULL check | PASS — 0 |
| Damage application identity preservation | PASS — 0 NULL participant IDs |
| Next-round cloning | PASS — 20 units retained participant identity |
| Settlement survivor mapping | PASS |
| Complete fresh-combat NULL check | PASS — 0 |

The fixture also verifies `resolve_attack_arrival()` against the same participant IDs used by the combat path. No gameplay rule or historical combat row is changed.

### Base-engine boundary

This closes the **participant propagation requirement for the existing V2 single-attacker + planet model**.

It does **not** close ACS/HOLDING/DEFEND. The old uniqueness keys remain deliberately unchanged, and multi-fleet participant insertion is still a separate future step.

### Version boundary

Lifeform-specific combat updates are intentionally **out of scope for this engine version**. They belong to the next version after the base combat engine is certified.

---

## 14. PHASE 0 AUDIT — COMBAT ENGINE CORE (read-only, LIVE-verified 2026-09-21)

> Scope: architecture, dependency and canonical-formula audit of the Combat Engine **before** any combat
> implementation. No migration, schema, RLS, ACL, formula, Fleet, Defense or Research change was made.
> Method: repository code + LIVE Supabase definitions (`pg_proc`, `pg_constraint`, `pg_indexes`, `pg_policies`,
> `has_function_privilege`, live row counts) + existing project documentation. Names alone were never treated as
> evidence: every claim below follows a real caller, a LIVE definition or a LIVE row count.

### 14.1 Sync gate at audit time

| Item | Value |
|---|---|
| Branch | `main` |
| HEAD | `234ec4ee8b8098163d2129948051ddd4202fe39e` (`feat(defense): close defense engine lifecycle`) |
| `origin/main` | `50faddfee713cb1a744e957cc93ae519069fb17b` |
| Relationship | **AHEAD 8**, not diverged (`origin/main` is an ancestor of `HEAD`; `git fetch --dry-run` clean) |
| Working tree | `M docs/systems/README_FLEET_ENGINE.md` (protected Fleet work, uncommitted) |
| Unstaged deletions | the three protected migrations `20260920120500/120600/120700_*` |
| Untracked | the three re-timestamped protected migrations `20260921044623/044643/044659_*` (byte-identical to the deleted ones — verified with `git hash-object` vs `git rev-parse HEAD:...`) plus four **0-byte** artefacts (`complete_research`, `process_planet_tick`, `process_universe_clock`, `process_universe_tick`) |
| Staged | none |
| Stashes | `stash@{0}` "WIP antes de integrar origin/main", `stash@{1}` "WIP Buildings before sync main" |

Every dirty entry was **declared protected material in the mission itself**, so ownership was clear and no stop
condition applied. Nothing protected was touched, and the 0-byte artefacts were deliberately **not** committed.

### 14.2 Answer to the CORE question

> **Yes.** LGI has **one authoritative, production-reachable Combat Engine chain** for the normal `ATTACK`
> mission, from Fleet arrival to battle persistence, reachable in production through
> `pg_cron → run_fleet_worker() → process_fleet_movements() → resolve_attack_arrival()`.
> There are **residual legacy/orphan objects** (8 functions + 1 legacy table + 2 invariant gaps) but **no
> competing authoritative combat path**. What must be resolved before a new Combat implementation are
> invariants and schema defects, not a parallel architecture: expedition combat regression (CB-01), the two
> missing battle foreign keys (CB-02), and the absence of a runnable combat test (§14.18).

### 14.3 Authoritative pipeline (real LIVE call chain)

LIVE entry point is `pg_cron` job `2`: `SELECT public.run_fleet_worker();` at **1 second** cadence
(job `4` = `process_universe_heartbeat()` once per minute).

```text
pg_cron job 2 (every 1s)
  → run_fleet_worker()                       SECURITY DEFINER
      → process_fleet_movements()            SECURITY DEFINER (global advisory xact lock)
          loop: status='OUTBOUND' and arrives_at<=clock_timestamp()
                order by arrives_at, id   FOR UPDATE SKIP LOCKED
              UPDATE status='OUTBOUND' → 'ARRIVED'
              dispatch by mission_type:
                ATTACK           → resolve_attack_arrival(fleet_id)      ← Fleet → Combat boundary
                TRANSPORT        → resolve_transport_arrival
                DEPLOY           → resolve_deploy_arrival
                COLONIZE         → resolve_colonize_arrival
                ESPIONAGE        → resolve_espionage_arrival
                EXPEDITION       → resolve_expedition_arrival (may create a combat battle)
                RECYCLE          → collect_debris
                ACS_HOLD/HOLDING → status='HOLDING'
                DEFEND           → RAISE WARNING, fleet kept in 'ARRIVED' (not implemented)
                other            → status='RETURNING'

resolve_attack_arrival(p_fleet_id uuid) RETURNS uuid
  1. lock fleet row FOR UPDATE; require mission_type='ATTACK'
  2. replay guard: status <> 'ARRIVED' → return the existing battle id (raise if none)
  3. catch up the target planet at the fleet's own arrival timestamp
     (update_planet_resources_until / process_shipyard_queue_until / process_defense_queue_until)
  4. battle_id := resolve_combat(p_fleet_id)
       → composition snapshot from fleet_movement_ships / planet_ships / planet_defenses
       → INSERT combat_battles (with loot columns) + the two combat_battle_participants rows
       → initialize_individual_combat_units(battle_id)   (one row per unit, tech-scaled stats)
  5. resolve attacker/defender participant ids (raises 'missing settlement participants' if absent)
  6. if the battle is not finished → run_expedition_combat(battle_id)   ← generic round runner
       loop rounds 1..6:
         skip a round already present in combat_rounds
         process_combat_round_v2(battle_id, round)
           → create_combat_round_snapshot         (round-start state)
           → generate_combat_round_v2             (initial shots: one per alive unit)
           → expand_all_rapidfire_v2              (RF chain per initial shot)
           → calculate_combat_round_pending_damage(shots → damage ledger)
           → resolve_pending_target_damage ×N     (per target: bounce, per-shot damage, explosion)
           → apply_combat_round_damage            (ledger → combat_individual_units)
           → finish_combat_round_v1               (result + next round)
           → INSERT combat_rounds aggregate       (round report)
           → create_combat_next_round + snapshot  (survivors only, shields reset to max)
       → set combat_battles.finished_at, attacker_win/defender_win/draw and the *_after counts
  7. sync_combat_battle_final_counts(battle_id)
  8. rewrite fleet_movement_ships = surviving ATTACKER ships of the last round
     rewrite planet_ships / planet_defenses = surviving DEFENDER units of the last round
  9. apply_attack_loot(battle_id)             (attacker_win only; 50 % caps; cargo capacity)
 10. repair_defenses_after_combat(battle_id)  (70 % roll per destroyed defense unit)
 11. create_combat_debris(battle_id)          (ship + defense debris, at most once per battle)
 12. fleet_movements.status='RETURNING', returns_at = arrives_at + (arrives_at - started_at)
```

Verified caller map (scan of `pg_proc.prosrc` over the whole `public` schema):

| Function | LIVE callers |
|---|---|
| `resolve_attack_arrival` | `process_fleet_movements` |
| `resolve_combat` | `resolve_attack_arrival` |
| `initialize_individual_combat_units` | `resolve_combat` |
| `get_combat_ship_*`, `get_combat_defense_*` | `initialize_individual_combat_units` |
| `run_expedition_combat` | `resolve_attack_arrival`, `resolve_expedition_aliens`, `resolve_expedition_pirates` |
| `process_combat_round_v2` | `run_expedition_combat` |
| `create_combat_round_snapshot`, `generate_combat_round_v2`, `expand_all_rapidfire_v2`, `calculate_combat_round_pending_damage`, `apply_combat_round_damage`, `resolve_pending_target_damage`, `finish_combat_round_v1`, `create_combat_next_round` | `process_combat_round_v2` |
| `expand_rapidfire_chain_v2` | `expand_all_rapidfire_v2` |
| `apply_attack_loot`, `repair_defenses_after_combat`, `create_combat_debris`, `sync_combat_battle_final_counts` | `resolve_attack_arrival` |
| `calculate_combat_ship|defense_losses` → `calculate_combat_ship|defense_debris` → `create_combat_total_debris` | `create_combat_debris` |

`resolve_attack_arrival` is **the authoritative arrival boundary** — not a thin dispatcher, not a duplicate and
not legacy: it owns replay safety, pre-combat economic catch-up, battle creation, the settlement write-back and
the return transition. Only the name is historical (`run_expedition_combat` plays the rounds for `ATTACK` too).

### 14.4 Function inventory and classification (LIVE)

| Classification | Objects |
|---|---|
| **AUTHORITATIVE** | `resolve_attack_arrival`, `resolve_combat`, `initialize_individual_combat_units`, `run_expedition_combat`, `process_combat_round_v2`, `create_combat_round_snapshot`, `generate_combat_round_v2`, `expand_all_rapidfire_v2`, `expand_rapidfire_chain_v2`, `calculate_combat_round_pending_damage`, `resolve_pending_target_damage`, `apply_combat_round_damage`, `finish_combat_round_v1`, `create_combat_next_round`, `sync_combat_battle_final_counts`, `apply_attack_loot`, `repair_defenses_after_combat`, `create_combat_debris`, `add_debris_field` |
| **DERIVED (read-only projections of live battle state)** | `calculate_combat_ship_losses`, `calculate_combat_defense_losses`, `calculate_combat_ship_debris`, `calculate_combat_defense_debris`, `calculate_combat_total_debris` |
| **HELPER** | `calculate_shield_bounce` (1 % shield threshold, IMMUTABLE), `combat_hull_from_integrity` (unused trivial `/10`) |
| **CANONICAL STAT READERS (certified Defense/Fleet interfaces)** | `get_combat_ship_attack|shield|hull`, `get_combat_defense_attack|shield|hull`, `get_player_research_level` |
| **LEGACY / ORPHAN (0 callers anywhere in LIVE)** | `simulate_defender_losses`, `initialize_combat_unit_state`, `snapshot_combat_round`, `apply_combat_hull_damage`, `calculate_combat_damage`, `get_combat_round_snapshot`, `get_combat_unit_snapshot`, `combat_hull_from_integrity` |
| **LEGACY TABLE** | `combat_unit_state` (0 rows, written only by the orphan `initialize_combat_unit_state`) |

Orphan detail (all LIVE-verified; no caller in any schema function, no trigger on combat tables, no cron job,
and no client path because RLS denies the underlying tables):

- `simulate_defender_losses(p_planet_id, p_total_damage)` — aggregate legacy approximation reading
  `planet_defenses`/`planet_ships` with **raw** `*_definitions` stats. This answers mission §10: it is **not**
  production combat logic and **not** a simulation helper of the live path; it is retired legacy code.
- `initialize_combat_unit_state(p_battle_id)` — writes the legacy `combat_unit_state` aggregate table.
- `snapshot_combat_round(p_battle_id, p_round_number)` — despite its name it only **counts** rows in
  `combat_individual_units`; it no longer snapshots anything.
- `apply_combat_hull_damage(...)` — V1 per-unit hull/explosion helper, superseded by
  `resolve_pending_target_damage` + `apply_combat_round_damage`.
- `calculate_combat_damage(p_attack, p_shield_current, p_hull_current)` — pure math without shield bounce or
  explosion, superseded by the ledger path.
- `get_combat_unit_snapshot(p_battle_id)` — reader that uses **another statistic source**
  (`ship_definitions.attack/shield/hull` raw, no technology); it would contradict the authoritative path.
- `get_combat_round_snapshot(...)`, `combat_hull_from_integrity(...)` — unused reader/helper.

Security posture of the LIVE combat surface: every mutating combat function is `service_role`-only
(`resolve_attack_arrival`, `resolve_combat`, `run_expedition_combat`, `process_combat_round_v2`,
`create_combat_debris`, `repair_defenses_after_combat`, `apply_attack_loot`, `add_debris_field`,
`process_fleet_movements`, `run_fleet_worker`, `simulate_defender_losses`, `get_combat_ship_*`), and
`search_path` is pinned on all of them (`'public','pg_temp'` or `'pg_catalog','public'`), matching the repo
hardening migrations `20260914223208` / `20260914223220`. The **read-only** calculators keep `EXECUTE` for
`anon`/`authenticated` (`calculate_combat_*`, `get_combat_round_snapshot`, `get_combat_unit_snapshot`,
`combat_hull_from_integrity`, `finish_combat_round_v1`, `expand_all_rapidfire_v2`). That is **surface, not
exploit**: every combat table carries an ALL-command `deny_direct_api_access` policy (`qual = false`,
`with_check = false`) for `anon`/`authenticated`, and `combat_battle_participants` has RLS enabled with **no**
policy, so unprivileged reads return zero rows and writes are rejected. `expand_all_rapidfire_v2` is
nevertheless **not self-idempotent** (it re-walks every RF chain), so it must stay un-callable by clients —
today only the `combat_rounds`-exists guard inside `process_combat_round_v2` prevents a second expansion.

### 14.5 Combat data model

```text
combat_battles (PK id)                    ← authoritative battle header
   fleet_id FK → fleet_movements(id) ON DELETE CASCADE, UNIQUE (ux_combat_battles_one_per_fleet)
   attacker_player_id FK → players(id) · defender_planet_id FK → planets(id) (nullable: expeditions)
   finished_at · attacker_win · defender_win · draw (NOT NULL)
   attacker_ships_before/after · defender_ships_before/after
   defender_defenses_before/after · defender_combat_units_before/after
   loot_metal/crystal/deuterium · loot_applied_at
   ↓
combat_battle_participants (PK id)        ← explicit participant identity (added 2026-09-19)
   battle_id FK → combat_battles(id) CASCADE · side ATTACKER|DEFENDER · participant_type FLEET|PLANET
   fleet_id FK RESTRICT · planet_id/origin_planet_id FK RESTRICT · player_id FK RESTRICT · mission_type
   UNIQUE (battle_id, fleet_id) · UNIQUE (battle_id, planet_id)   ← NULL-fleet rows are deduplicated
   ↓
combat_individual_units (PK id)           ← AUTHORITATIVE per-unit round state
   battle_id FK CASCADE · participant_id FK → participants CASCADE
   UNIQUE (battle_id, round_number, side, unit_type, unit_id, unit_number)   ← legacy key, still in force
   attack · shield_max · shield_current · structural_integrity · hull_max · hull_current · alive
   ↓
combat_round_snapshot_units (PK id)       ← round-start snapshot (history)
   participant_id FK · UNIQUE (battle_id, round_number, side, unit_type, unit_id, unit_number)
   *** NO FK ON battle_id ***   → orphans possible (CB-02)
combat_shots (PK id)                      ← shot ledger (history)
   battle_id FK CASCADE · attacker_participant_id FK · target_participant_id FK
   UNIQUE (battle_id, round_number, shot_number)
combat_round_damage (PK id)               ← per-shot damage ledger (history)
   target_participant_id FK · UNIQUE (battle_id, round_number, source_shot_number)
   *** NO FK ON battle_id ***   → orphans possible (CB-02)
combat_rounds (PK id)                     ← per-round aggregate report
   battle_id FK CASCADE · UNIQUE (battle_id, round_number)
combat_rapidfire (PK id)                  ← RF matrix: 52 LIVE rows, 14 of them vs DEFENSE, values 2..1250
   UNIQUE (attacker_unit_type, attacker_unit_id, target_unit_type, target_unit_id)
combat_defense_repairs (PK id)            ← repair ledger · battle_id FK CASCADE · UNIQUE (battle_id, defense_id)
combat_debris_generations (PK id)         ← debris provenance · battle_id FK CASCADE · UNIQUE (battle_id)
combat_unit_state (PK id)                 ← LEGACY aggregate table (0 rows; orphan writer)
debris_fields (PK id)                     ← live debris at a coordinate
   UNIQUE (universe_id, galaxy, system, position) · universe_id FK CASCADE
```

The schema does represent `battle → participants → rounds → result → losses → debris/repairs`, with two
corrections to the naive reading: **losses are derived** (computed from `combat_individual_units`, never stored),
and **two round-history tables have no cascade to the battle** (CB-02). Authoritative state =
`combat_battles` + `combat_individual_units` + `planet_ships`/`planet_defenses`; derived history = snapshots,
shots, damage ledger, round aggregates, repairs, debris provenance.

LIVE residue checked during this audit (read-only counts):

| Table | Rows | Orphan rows (battle_id not in `combat_battles`) |
|---|---|---|
| `combat_battles` | 0 | — |
| `combat_individual_units` | 0 | 0 |
| `combat_rounds` | 0 | 0 |
| `combat_shots` | 0 | 0 |
| `combat_debris_generations` | 0 | 0 |
| `combat_defense_repairs` | 0 | 0 |
| `combat_round_snapshot_units` | **661** (17 battles) | **661** |
| `combat_round_damage` | **681** (17 battles) | **681** |
| `debris_fields` | **3** (1:2:1 / 1:2:2 / 1:2:3, universe `86900cbc…`) | no provenance rows |

Written 2026-09-12 → 2026-09-16, i.e. before the participant model of 2026-09-19. The two tables that hold the
orphans are exactly the two that have no `battle_id` FK, which is what makes CB-02 a real defect rather than a
cosmetic one; the three debris fields are live, recyclable game state whose generating battles no longer exist.

### 14.6 Ship statistics — canonical contract

Combat consumes `ship_definitions.attack|shield|hull` **through the certified readers**, never directly:

```text
get_combat_ship_attack (player, ship) = ship_definitions.attack * (1 + weapons_technology  * 0.10)
get_combat_ship_shield (player, ship) = ship_definitions.shield * (1 + shielding_technology * 0.10)
get_combat_ship_hull   (player, ship) = (ship_definitions.hull / 10) * (1 + armour_technology * 0.10)
```

- All three are `STABLE SECURITY DEFINER`, `search_path = 'public','pg_temp'`; their only callers are
  `initialize_individual_combat_units`. Each side's **own** owner technologies are applied (attacker techs to
  attacker units, defender techs to defender units).
- Persisted per unit: `attack` (tech-scaled), `shield_max = shield_current`,
  `structural_integrity = hull*10` (armour-scaled raw structural value) and `hull_max = hull_current = hull`
  (the normalized `/10` value that the damage engine actually uses).
- **Snapshot semantics:** stats are frozen when the battle is created. `create_combat_next_round` clones
  `attack`, `shield_max`, `structural_integrity` and `hull_max` and carries `hull_current`, so research
  completed during a battle cannot affect it.
- `resolve_combat` also aggregates `sum(definitions.stat * quantity)` into local variables, but those are
  **never persisted**; the battle header stores unit *counts* only. No second stat source is authoritative.
- Modifiers other than the three combat technologies are **not applied**: there is no evolution, lifeform or
  item combat-stat modifier in the pipeline today.

### 14.7 Defense statistics — canonical Defense Engine interfaces

```text
planet_defenses (quantity per defense_definitions.id)          → one unit row per defense
get_combat_defense_attack (player, defense) = defense_definitions.attack * (1 + weapons_technology  * 0.10)
get_combat_defense_shield (player, defense) = defense_definitions.shield * (1 + shielding_technology * 0.10)
get_combat_defense_hull   (player, defense) = (defense_definitions.hull / 10) * (1 + armour_technology * 0.10)
```

Verified properties:

- **Every** defense type participates (no filter beyond `quantity > 0`); quantity is expanded into individual
  units with `generate_series(1, quantity)`, attributed to the DEFENDER/PLANET participant.
- Defenses are ordinary units in the ledger: they fire, take damage, explode and die. There is **no
  shield-dome-specific branch** anywhere in the damage engine (see the gap in §14.21).
- Repair stays Defense-owned (`repair_defenses_after_combat`, §14.12); Combat did not modify it and does not
  reimplement it.
- `resolve_attack_arrival` writes survivors back into `planet_defenses` and repair then *adds* repaired units;
  debris is computed from the unit ledger, so repair can never cancel debris (ordering in §14.11/§14.12).

### 14.8 Technology routing — weapons / shielding / armour

| Technology | Status | Where it is applied |
|---|---|---|
| `weapons_technology` | **IMPLEMENTED** | `get_combat_ship_attack`, `get_combat_defense_attack` → unit `attack` |
| `shielding_technology` | **IMPLEMENTED** | `get_combat_ship_shield`, `get_combat_defense_shield` → `shield_max`/`shield_current` |
| `armour_technology` | **IMPLEMENTED** | `get_combat_ship_hull`, `get_combat_defense_hull` → `hull_max`/`hull_current` (+ `structural_integrity`) |

- Reader: `get_player_research_level(player, research_id)` → `player_research.level`, defaulting to 0
  (`STABLE SECURITY DEFINER`); all three ids exist in LIVE `research_definitions`.
- Scaling is **linear, +10 % per level**, read once at battle creation (snapshot semantics, §14.6).
- Only the three combat technologies participate. The only stat reads that bypass the tech helpers are
  `resolve_combat`'s count aggregation and the orphan `get_combat_unit_snapshot`, and neither feeds combat state.
- Do **not** read this as "Research completion routes into combat by itself": the routing exists because
  `initialize_individual_combat_units` calls these helpers. Classification per mission §8: all three are
  **IMPLEMENTED**; none is "defined only" or "partially implemented".

### 14.9 Round formula — the existing chain

The battle is **round-based, maximum 6 rounds, simultaneous fire by construction** (all initial shots are
generated from the round-start snapshot before any damage is applied).

```text
ROUND START (round r, r in 1..6)
  create_combat_round_snapshot(r)   copies surviving units into combat_round_snapshot_units
                                    (attack, shield_max, shield_start, hull_max, hull_start, alive_start)
INITIAL SHOTS
  generate_combat_round_v2(r)       for each unit with alive_start = true, in RANDOM order, pick a RANDOM
                                    target on the opposite side (alive_start): 1 shot per unit → combat_shots
                                    (is_initial_shot = true)
RAPIDFIRE
  expand_all_rapidfire_v2(r)        walk each initial shot's chain:
    expand_rapidfire_chain_v2(...)    rf := combat_rapidfire(row) ELSE 1
                                      probability := 1 - (1/rf) ; roll := random() ; triggered := roll < p
                                      if triggered → insert the next RF shot (same attacker, new random target
                                      on the opposite side, is_initial_shot = false) and continue, else stop
DAMAGE LEDGER
  calculate_combat_round_pending_damage(r)   delete existing round rows, then one ledger row per shot
                                             (target identity + source_shot_number + attack_value)
PER-TARGET RESOLUTION               for each distinct target (ordered by side/type/id/number):
  resolve_pending_target_damage(...)
     shield := snapshot.shield_start ; hull := snapshot.hull_start
     for each shot of that target ordered by source_shot_number:
        if hull > 0:
           calculate_shield_bounce(attack, shield_max) → threshold := shield_max * 0.01
              attack < threshold → the shot does NOTHING (bounce: no shield, no hull damage)
              else shield_damage := least(shield, attack) ; shield -= shield_damage
                   hull_damage := least(hull, greatest(attack - shield_damage, 0)) ; hull -= hull_damage
                   if hull > 0 and hull/hull_start < 0.70:
                        explode := random() < (1 - hull/hull_start)
                        explode → hull := 0 ; shield := 0
        persist shield_damage/hull_damage/exploded into combat_round_damage and mirror the resolved values
        (target_shield_before, raw_damage, effective_damage, shield_damage, hull_damage, target_destroyed)
        back into combat_shots
APPLY
  apply_combat_round_damage(r)       aggregate the ledger per target and write it into combat_individual_units
                                    (shield_current, hull_current, alive := hull_current > 0); exploded → 0/false
FINISH
  finish_combat_round_v1(r)         attacker_alive / defender_alive counted from alive units
                                    both 0 → DRAW | attacker 0 → DEFENDER_WIN | defender 0 → ATTACKER_WIN
                                    else CONTINUE ; if CONTINUE at r = 6 → DRAW (next_round := NULL)
  INSERT combat_rounds(r)           round report: attack/shield/hull sums + before/after unit counts
                                    (defender attack/shield/hull sums cover DEFENDER *SHIP* units only, while
                                     defender_units_* count all defender units — a reporting asymmetry)
NEXT ROUND
  create_combat_next_round(r)       clone only alive units into r+1 with shield_current := shield_max
                                    (full shield regeneration) and hull_current carried over
  create_combat_round_snapshot(r+1)
```

Documented facts of the current formula contract:

- **Destruction threshold:** a unit dies only when its hull reaches 0 — by per-shot hull subtraction and/or the
  explosion roll below 70 % structural integrity. There is no instant death by raw damage.
- **Partial damage persists** across rounds for survivors (`hull_current` is carried); **shields regenerate
  fully at the start of every round**.
- **Damage accumulation is per target**, not global: many shots stack onto the same unit.
- **Composition changes during a battle only through destruction**; retargeting is re-randomised every shot.
- **It is stochastic, not deterministic**: target selection and rapidfire use `random()` and no seed is
  persisted (unlike the deterministic expedition event streams of `20260914202536`), so a battle cannot be
  reproduced bit-for-bit from persisted rows.
- Round numbers outside 1..6 raise (`process_combat_round_v2`, `create_combat_next_round`).
- Missing pieces of the contract are listed in §14.21 (no defense-rebuild or shield-dome-specific rule, no
  explicit extra defender-fleet concept, no seeded determinism).

### 14.10 Losses (attacker and defender)

Losses are **derived, not authoritative**: they are recomputed from `combat_individual_units` (round 1 versus the
last round) by two symmetric readers.

```text
calculate_combat_ship_losses(battle)      initial   := count(unit rows, round 1, unit_type 'SHIP')
                                          surviving := count(alive = true, LAST round)
                                          destroyed := initial - surviving
                                          metal/crystal/deuterium_lost := destroyed × ship_definitions.base_*
calculate_combat_defense_losses(battle)   identical logic with unit_type = 'DEFENSE' and
                                          defense_definitions.metal_cost/crystal_cost/deuterium_cost
```

- Both are `LANGUAGE sql` and read-only, and their only callers are the debris chain
  (`calculate_combat_*_debris` → `calculate_combat_total_debris` → `create_combat_debris`).
- **Attacker and defender share the same ledger and the same loss semantics**; no asymmetric formula exists.
  The only asymmetry is representational: attacker survivors are rewritten into `fleet_movement_ships`, defender
  survivors into `planet_ships`/`planet_defenses`, by `resolve_attack_arrival`.
- `simulate_defender_losses` is **not** part of this path (orphan, §14.4). Losses are never allocated from a
  global damage pool. Mission §10 is answered: one path, ledger-based, symmetric.
- Loss valuation uses **base** `*_definitions` costs (no technology/scaling), which is also the canonical debris
  valuation.

### 14.11 Debris

```text
create_combat_debris(battle)                     — idempotent, called once by resolve_attack_arrival
  1. if combat_debris_generations already has a row for the battle → return it with already_generated = true
  2. universe/coordinate := defender planet's universe, galaxy, system, position
  3. totals := calculate_combat_total_debris(battle)
        ship_debris    = sum(calculate_combat_ship_debris)     = destroyed_ship_value    × universes.fleet_debris_percentage / 100
        defense_debris = sum(calculate_combat_defense_debris)  = destroyed_defense_value × universes.defense_debris_percentage / 100
  4. if both debris amounts are 0 → return without touching debris_fields (no generation row is created)
  5. otherwise add_debris_field(universe, galaxy, system, position, metal, crystal)
        INSERT ... ON CONFLICT (universe_id, galaxy, system, position) DO UPDATE SET metal = df.metal + EXCLUDED.metal,
        crystal = df.crystal + EXCLUDED.crystal          ← debris at a coordinate is ACCUMULATED, never overwritten
  6. INSERT combat_debris_generations(battle_id, debris_field_id, metal_generated, crystal_generated)
        ON CONFLICT (battle_id) DO NOTHING                ← exactly-once provenance per battle
```

- Debris therefore has **one canonical calculation** (destroyed units × base cost × universe percentage) and
  **one persistence path**; there is no recalculation entrypoint, and `add_debris_field` has no other caller.
- Losses (and thus debris) come from the combat ledger, **not** from `planet_ships`/`planet_defenses`, so the
  defense-repair step that runs immediately before cannot cancel or duplicate debris.
- LIVE configuration: `fleet_debris_percentage = 30`, `defense_debris_percentage = 0` for both universes → in the
  current LIVE configuration **defenses produce no debris at all** (they are still fully repaired/lost normally).
- Recycler interaction is Fleet-owned and untouched by this audit (`can_recycle_debris`, `collect_debris`, the
  `RECYCLE` mission branch in `process_fleet_movements`) — debris is created exactly once per battle and then
  belongs to the coordinate.
- CB-03 (§14.20) records the one theoretical double-count window inside `create_combat_debris`.

### 14.12 Defense repair

```text
repair_defenses_after_combat(p_battle_id)   — SECURITY DEFINER, service_role only
  1. lock combat_battles row FOR UPDATE; if defender_planet_id is NULL → return (expedition battles)
  2. for each destroyed defense type (calculate_combat_defense_losses, side DEFENDER, destroyed > 0):
        if a combat_defense_repairs row already exists for (battle_id, defense_id) → CONTINUE   ← per-defense guard
        repaired := count of generate_series(1, destroyed) where random() < 0.70                  ← 70 % repair roll
        INSERT combat_defense_repairs(battle_id, planet_id, defense_id, destroyed, repaired)
        UPDATE planet_defenses SET quantity = quantity + repaired (or INSERT the row if missing)
```

- **Call boundary:** inside `resolve_attack_arrival`, after the survivor write-back and after loot, immediately
  before `create_combat_debris`. It is called **once** per battle in the production path.
- **Normalization is per defense type and combined with the authoritative `planet_defenses` state**, which is
  why it is safe: `resolve_attack_arrival` has already set the surviving quantities, so the `+=` adds exactly the
  repaired units of this battle.
- **Transactionality:** same transaction as the battle (no autonomous transaction, no commit of its own), so
  repair either exists with the battle or not at all.
- **Duplicate-repair risk:** guarded twice — the `CONTINUE` on the existing `combat_defense_repairs` row and the
  `UNIQUE (battle_id, defense_id)` constraint. Independently callable only by `service_role`.
- **Shield domes:** no special rule. All defense types use the same 70 % repair roll (see §14.21).
- Repair is Defense-owned; **this audit did not modify it**.

### 14.13 Transaction and atomicity

Verified from LIVE definitions:

- The whole combat settlement is **one implicit transaction**: `run_fleet_worker()` → `process_fleet_movements()`
  → `resolve_attack_arrival()` → `resolve_combat()` → round pipeline → loot/repair/debris → return transition.
  No `COMMIT`, no autonomous transaction and no `EXCEPTION` handler exists anywhere on that path.
- Concurrency is serialised twice over: the global advisory xact lock in `process_fleet_movements`
  (`pg_advisory_xact_lock(hashtextextended('fleet-processing-global',0))`) plus per-row locks — `FOR UPDATE
  SKIP LOCKED` on the fleet queue, `FOR UPDATE` on the fleet in `resolve_attack_arrival`/`resolve_combat`,
  `FOR UPDATE` on `combat_battles` in `apply_attack_loot`/`repair_defenses_after_combat`, and `FOR UPDATE` on the
  target snapshot/ledger rows in `resolve_pending_target_damage`.
- Therefore the mission's partial-state scenarios are **structurally impossible inside a normal run**:

| Scenario | Verdict |
|---|---|
| battle exists but losses not applied | impossible in one transaction (units are written before settlement; any failure rolls the whole batch back) |
| losses applied but debris missing | impossible for the same reason; a failure also rolls back the fleet status change |
| defenses repaired but battle result missing | impossible: `finished_at` and the win flags are written by `run_expedition_combat` in the same transaction |
| attack fleet consumed but combat not persisted | impossible: `fleet_movement_ships` is rewritten only after the battle is persisted |

- The **real** gap is the opposite direction: `process_fleet_movements` processes **all** due fleets in one
  transaction and raises hard exceptions for malformed rows (`SUPPORT_HOLDING_WINDOW_MISSING`,
  `SUPPORT_HOLDING_WINDOW_INVALID`, `Expedition battle % finished without rounds`, and every exception raised
  inside `resolve_attack_arrival`). `run_fleet_worker` has no per-fleet error isolation, so **one poisoned fleet
  rolls back the whole batch and the same failure repeats every second** (head-of-line blocking). Evidence: no
  `BEGIN … EXCEPTION` block in `run_fleet_worker`/`process_fleet_movements` plus the explicit `raise exception`
  sites above. This is a robustness gap (CB-04), not a data-corruption gap.

### 14.14 Idempotency and replay

Attack arrival is worker-triggered, so replay safety is architectural. LIVE-verified guards:

| Guard | Object | Behaviour on replay |
|---|---|---|
| Fleet row lock + status gate | `resolve_attack_arrival` | `status <> 'ARRIVED'` → returns the existing battle id, or raises if none exists |
| Existing-battle lookup | `resolve_combat` | returns the existing battle instead of creating a second one |
| `UNIQUE (fleet_id)` | `combat_battles.ux_combat_battles_one_per_fleet` | DB-level guarantee: **one battle per attacking fleet** |
| Round-closed guard | `process_combat_round_v2` | `combat_rounds` row exists → raises `Combat round % is already closed` |
| Resumable round loop | `run_expedition_combat` | a round already present in `combat_rounds` is skipped and re-counted, never repeated |
| `UNIQUE (battle_id, round_number)` | `combat_rounds` | a second aggregate insert for the same round is impossible |
| Shot guard | `generate_combat_round_v2` | shots already exist for the round → returns existing counts, creates none |
| Loot timestamp | `combat_battles.loot_applied_at` in `apply_attack_loot` | second call returns the stored loot and mutates nothing |
| Repair ledger | `combat_defense_repairs` UNIQUE (battle_id, defense_id) + `CONTINUE` | a second repair call adds nothing |
| Debris provenance | `combat_debris_generations.battle_id` UNIQUE + `ON CONFLICT DO NOTHING` | a second debris call returns `already_generated = true` |
| Worker serialisation | global advisory xact lock | two worker ticks cannot interleave on the same fleet |

Verdict: **an authoritative replay guard exists**, and the strongest element is the DB-level `UNIQUE (fleet_id)`.
Repeating the same attack arrival cannot create a second battle, apply losses twice, duplicate debris, repair
defenses twice or consume the same fleet twice.

Residual weaknesses (all verified, none currently exploitable):

- `combat_battles.fleet_id` uniqueness is an **index**, not a declared constraint, so it is invisible when
  listing constraints — sound for integrity, weaker as documentation.
- `expand_all_rapidfire_v2` is **not self-idempotent** (it re-walks chains and would add duplicate RF shots if
  called twice for the same round); only the round-closed guard inside `process_combat_round_v2` protects it
  (CB-05).
- `create_combat_debris` can theoretically credit debris twice in the race window between its provenance check and
  the `ON CONFLICT` insert, because the field is credited *before* the provenance row is written. The fleet and
  battle locks make it unreachable in the current production path (CB-03).

### 14.15 Fleet → Combat contract (actual, not desired)

Inputs Combat consumes from Fleet — all read inside `resolve_attack_arrival`/`resolve_combat`, never passed by a
caller (the only parameter on the boundary is `p_fleet_id`):

| Consumed value | Source |
|---|---|
| attacker player | `fleet_movements.player_id` → `combat_battles.attacker_player_id`, participant `player_id` |
| source planet | `fleet_movements.origin_planet_id` → participant `origin_planet_id` |
| target planet | `fleet_movements.destination_planet_id` → `combat_battles.defender_planet_id` and the planet participant |
| defender owner | `planets.player_id` of the destination planet |
| ship composition | `fleet_movement_ships` (ship_id, quantity) |
| mission identity | `fleet_movements.mission_type` (must be `ATTACK`) |
| arrival identity | `fleet_movements.id` (the battle key), `started_at`, `arrives_at` (economic catch-up timestamp and return timing) |
| technologies | `player_research` per side, read inside the stat helpers |

Outputs Combat returns to Fleet:

| Returned value | Where it lands |
|---|---|
| battle identifier | `resolve_attack_arrival` return value / `combat_battles.id` |
| winner/result | `combat_battles.attacker_win`, `defender_win`, `draw`, `finished_at` |
| attacker survivors | `fleet_movement_ships`, rewritten from the last round's alive ATTACKER units |
| defender survivors | `planet_ships` / `planet_defenses`, rewritten from the last round's alive DEFENDER units |
| loot | `combat_battles.loot_*` plus the attacker's cargo columns, applied by the return path |
| defense repairs | `combat_defense_repairs` + `planet_defenses` |
| debris | `debris_fields` + `combat_debris_generations` |
| fleet completion | `fleet_movements.status = 'RETURNING'`, `returns_at = arrives_at + duration` |

Deviations from the conceptual shape, recorded exactly as found:

- Combat is **not** a pure function of an input payload: it is a stored-procedure chain that reads and writes
  Fleet tables directly. The contract is therefore a shared-state contract, not a message contract.
- Combat consumes **no defender fleet identity** and no modifier payload (no items, no lifeform modifiers, no
  universe scaling).
- The return leg is Fleet-owned: Combat only flips the fleet to `RETURNING`; the resource settlement and the
  `COMPLETED` transition happen in the `RETURNING` branch of `process_fleet_movements`.

### 14.16 Special missions — classification only

| Mission | Combat-relevant handling | Classification |
|---|---|---|
| `ATTACK` | full pipeline (`resolve_attack_arrival` → `resolve_combat` → rounds → loot/repair/debris → return) | **IMPLEMENTED** |
| `ESPIONAGE` | `resolve_espionage_arrival` (no combat) | **IMPLEMENTED** (non-combat) |
| `RECYCLE` | `collect_debris` reads `debris_fields` created by combat | **IMPLEMENTED** (non-combat consumer) |
| `EXPEDITION` | `resolve_expedition_arrival` may create a battle via `resolve_expedition_pirates`/`resolve_expedition_aliens` → `run_expedition_combat` | **PARTIAL / BROKEN — see CB-01** |
| `COLONIZE` | `resolve_colonize_arrival` (no combat) | **IMPLEMENTED** (non-combat) |
| `TRANSPORT` | `resolve_transport_arrival` (no combat) | **IMPLEMENTED** (non-combat) |
| `DEPLOY` | `resolve_deploy_arrival` (no combat) | **IMPLEMENTED** (non-combat) |
| `ACS_HOLD` | dispatch-only holding lifecycle; no combat participation | **DEFINITION ONLY for combat** |
| `HOLDING` | lifecycle state, never player-facing; no combat participation | **DEFINITION ONLY for combat** |
| `DEFEND` | blocked at dispatch with `COMBAT_SUPPORT_NOT_READY`; if it somehow arrives, the worker only raises a warning and the fleet stays `ARRIVED` | **NOT IMPLEMENTED** |
| `ACS` (multi-fleet attack) | no mission, no model, no dispatcher | **NOT IMPLEMENTED** |

This audit did not expand into general Fleet auditing; only combat-relevant handling is classified.

### 14.17 ACS / multi-fleet combat — classification only

| Capability | Status | Evidence |
|---|---|---|
| explicit participant identity layer | **IMPLEMENTED** (single attacker fleet + one planet) | `combat_battle_participants`, populated by `resolve_combat`, consumed by settlement |
| multiple attacker fleets | **NOT IMPLEMENTED** | `combat_battles.fleet_id` is UNIQUE; `resolve_combat` creates exactly one ATTACKER/FLEET participant |
| multiple attacker players | **NOT IMPLEMENTED** | `combat_battles.attacker_player_id` is single-valued |
| multiple defender fleets | **NOT IMPLEMENTED** | the only defender participant is `DEFENDER`/`PLANET`; `resolve_attack_arrival` refuses to settle if either participant is missing, and has no mapping from a survivor to a supporting fleet's owner/origin |
| defender reinforcements (`DEFEND`) | **NOT IMPLEMENTED** | blocked at dispatch; worker only warns |
| ACS holding (`ACS_HOLD`/`HOLDING`) | implemented as a **holding lifecycle without combat participation** | `start_support_fleet`, `planet_support_authorizations`, worker `HOLDING` branch |
| battle ordering across participants | **NOT IMPLEMENTED** | shot order is random within a round; no participant ordering concept |
| shared battle result | **IMPLEMENTED only for the single-fleet model** | one result per battle row |

The old uniqueness keys that would collide for multi-fleet participants are still in force
(`combat_individual_units` and `combat_round_snapshot_units`: `battle_id, round_number, side, unit_type, unit_id,
unit_number`) — exactly as documented in §3/§12 of this file. ACS must not be bolted onto
`resolve_attack_arrival` by inspecting mission rows.

### 14.18 Tests — inventory and coverage

| Test | Combat content | Classification |
|---|---|---|
| `supabase/tests/combat_participant_propagation.sql` | 15 assertions over the real V2 pipeline (`resolve_combat`, `run_expedition_combat`, `resolve_attack_arrival`) inside a rolled-back transaction | **STALE / BLOCKED** |
| `supabase/tests/fleet_acs_hold_lifecycle.sql` | asserts `DEFEND → COMBAT_SUPPORT_NOT_READY` (dispatch guard) | **RUNNABLE**, combat-adjacent only |
| `supabase/tests/fleet_speed_classes.sql` | 2 incidental mentions | structural only |
| `buildings_lifecycle.sql`, `research_lifecycle.sql`, `shipyard_defense_lifecycle.sql` | no combat content | — |

Why the only combat suite is blocked: it hardcodes LIVE identifiers that no longer exist — attacker
`60f1043a-2fa6-416c-80db-2a83215b5404`, origin planet `c0d77158-78ca-4631-98f2-b01d571d627c`, defender planet
`bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb`, defender player `aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa`. All four return
**0 rows** in LIVE today, while the fixture inserts `fleet_movements` (FK → `players`, `planets`) and
`planet_ships` (FK → `planets`), so it now fails on foreign keys before asserting anything. Its documented
"15/15 PASS" belongs to the 2026-09-19 database state, not to the current one.

Missing assertions on production paths (to be added by a later mission, not by this audit):

1. A fresh real-path battle running `resolve_attack_arrival` end-to-end on a fixture built from **LIVE-resolved**
   player/planet ids (the pattern already used by `shipyard_defense_lifecycle.sql`).
2. Replay assertion: a second `resolve_attack_arrival(fleet)` returns the same `battle_id`, creates no second
   `combat_battles` row and adds no second `combat_rounds` / `combat_debris_generations` /
   `combat_defense_repairs` row.
3. Loss/debris consistency: ledger `destroyed_quantity` equals the drop in `planet_ships`/`planet_defenses`, and
   the debris credited equals `destroyed_value × universe percentage`.
4. Participant coverage assertion for the **expedition** path (currently zero participants → CB-01).
5. No coverage at all for loot caps, defense repair probability or the 6-round DRAW boundary.

### 14.19 OGameX — conceptual reference only (clearly separated from LGI reality)

Conceptual comparison based only on the reference repository's public structure and the map already recorded in
[`docs/reference/OGAMEX_LGI_MAP.md`](../reference/OGAMEX_LGI_MAP.md) §5C. No PHP/Laravel/Rust code, formula,
schema or implementation was copied, and nothing below describes LGI:

| Concept in OGameX | LGI reality (verified in this audit) |
|---|---|
| battle logic isolated in a dedicated battle engine/service, separate from the mission and event layer | LGI has **no** isolated battle component: the engine is the `combat_*` SQL function family, called directly by the Fleet worker |
| explicit per-fleet battle participants (its engine supports multiple attacker and defender fleets) | LGI added explicit participants on 2026-09-19 but supports only **one attacker fleet + one planet**; multi-fleet is unimplemented (§14.17) |
| battle simulation reachable standalone | LGI rounds are only reachable through the worker chain; the only standalone entry points are orphan readers |
| round-based resolution with rapidfire, shield bounce and explosion | the same domain concepts exist in LGI, implemented independently in SQL (§14.9) |

Conclusion: OGameX validates the direction already recorded in §12 (participant attribution before ACS) and the
legitimacy of a separate battle boundary. It does **not** justify reshaping LGI combat now; the next step is to
make the existing single-defender chain correct and testable, not to port a foreign architecture.

### 14.20 Real bugs found (confirmed only)

```text
CB-01  Severity: HIGH
Object:    resolve_expedition_pirates(uuid), resolve_expedition_aliens(uuid) vs
           calculate_combat_round_pending_damage(uuid,int) and create_combat_round_snapshot(uuid,int)
Evidence:  LIVE resolve_expedition_pirates/aliens insert combat_individual_units rows WITHOUT participant_id
           and never insert combat_battle_participants rows (verified: neither function mentions
           `participant`; only resolve_combat + initialize_individual_combat_units create participants).
           LIVE create_combat_round_snapshot copies `cui.participant_id`, and LIVE
           calculate_combat_round_pending_damage joins shots to the snapshot with
           `t.participant_id = s.target_participant_id`. For an expedition battle both sides are NULL, so the
           join matches nothing → zero combat_round_damage rows → resolve_pending_target_damage has no
           targets → apply_combat_round_damage updates nothing → units never die.
           The same path also initialises units from RAW ship_definitions.attack|shield|hull (no technology
           scaling and hull NOT divided by 10) while the normal path uses get_combat_ship_*, so the two paths
           do not even share the same stat contract.
           Timeline: combat functions were last defined by 20260914202536; the participant model arrived
           afterwards in 20260919080000 and was never extended to the expedition creators.
LIVE/LOCAL: LIVE (definitions verified); no local migration fixes it.
Impact:    Expedition pirate/alien combat cannot produce losses or debris; it would run to the 6-round
           boundary and end as a DRAW with the fleet intact. Latent in LIVE only because
           expedition_results, fleet_movements and combat_battles are currently empty (0 rows).
```

```text
CB-02  Severity: MEDIUM (data integrity)
Object:    combat_round_damage, combat_round_snapshot_units (missing FK to combat_battles)
Evidence:  `has_fk_to_combat_battles` is FALSE for exactly these two tables (all other combat* tables are
           TRUE). LIVE holds 661 orphan rows in combat_round_snapshot_units and 681 in combat_round_damage,
           all belonging to 17 battle ids absent from combat_battles (written 2026-09-12 → 2026-09-16).
           Three debris_fields rows (1:2:1, 1:2:2, 1:2:3) also survive without provenance rows.
LIVE/LOCAL: LIVE.
Impact:    round history can outlive its battle; any future battle report built from these tables would surface
           orphan rows, and deleting a battle cannot clean its damage ledger.
```

```text
CB-03  Severity: LOW (unreachable in the current production path)
Object:    create_combat_debris(uuid)
Evidence:  the function credits the field through add_debris_field BEFORE writing the
           combat_debris_generations provenance row (`on conflict (battle_id) do nothing`). Two concurrent
           calls could both pass the initial provenance check and both credit debris_fields; the second
           provenance insert is discarded while the extra debris stays.
LIVE/LOCAL: LIVE.
Impact:    possible duplicated debris; unreachable today because resolve_attack_arrival locks the fleet row and
           combat_battles is unique per fleet.
```

```text
CB-04  Severity: MEDIUM (robustness)
Object:    run_fleet_worker(), process_fleet_movements()
Evidence:  no EXCEPTION handler anywhere in the chain; process_fleet_movements raises for malformed rows
           (SUPPORT_HOLDING_WINDOW_MISSING / _INVALID, 'Expedition battle % finished without rounds', and every
           exception raised by resolve_attack_arrival) and the single-transaction batch is rolled back entirely.
LIVE/LOCAL: LIVE.
Impact:    one poisoned fleet blocks every other due fleet permanently — the cron job retries the same failing
           batch every second, so combat settlements behind it are never reached.
```

```text
CB-05  Severity: LOW (hardening, not an exploit)
Object:    expand_all_rapidfire_v2(uuid,int), finish_combat_round_v1(uuid,int), get_combat_unit_snapshot(uuid),
           get_combat_round_snapshot(uuid,int), calculate_combat_* family, combat_hull_from_integrity(numeric)
Evidence:  has_function_privilege('anon'|'authenticated', 'EXECUTE') = true for this set; only the
           round-closed guard inside process_combat_round_v2 keeps RF expansion single-shot, and RLS
           (deny_direct_api_access on all combat tables; no policy at all on combat_battle_participants) is what
           currently blocks any client use.
LIVE/LOCAL: LIVE.
Impact:    a wider EXECUTE surface than the internal-step design requires. No mutation and no data leak is
           currently possible, but the surface should be closed with the same pattern already used in
           20260914223220.
```

Deliberately **not** classified as bugs (design decisions, not defects): stochastic non-determinism of rounds; the
absence of a client battle-report read path; per-battle technology snapshot semantics; the retained legacy
uniqueness keys for participant-aware rows; `DEFEND` being closed on purpose; `defense_debris_percentage = 0`.

### 14.21 Open design gaps, not-implemented items and future work (separated)

```text
BUG (confirmed, see §14.20)
  CB-01 expedition combat produces no losses (participant NULL join + divergent stat contract)
  CB-02 combat_round_damage / combat_round_snapshot_units missing the battle FK (+ LIVE orphans)
  CB-03 create_combat_debris double-credit race window
  CB-04 one poisoned fleet blocks the whole fleet batch
  CB-05 over-broad EXECUTE surface on read-only combat helpers

DESIGN GAP (no confirmed defect; the contract is simply incomplete)
  DG-01 no client battle-report read path: every combat table denies anon/authenticated and there is no
        player-scoped policy or RPC, so the COMBATE feed in src/App.tsx (combat_battles select, App.tsx:70)
        can only ever render nothing — a dead UI path, not a security hole
  DG-02 no seeded determinism: rounds use random() and rapidfire rolls, so a battle cannot be replayed or
        audited bit-for-bit, while expedition events already have deterministic streams
  DG-03 no defender-fleet identity: the participant model cannot express reinforcing fleets, so
        resolve_attack_arrival can never attribute survivors to a second fleet's owner/origin
  DG-04 legacy uniqueness keys (battle_id, round_number, side, unit_type, unit_id, unit_number) are still the
        only key on the unit/snapshot tables; participant-aware keys are required before multi-fleet work
  DG-05 shield domes have no distinct rule (uniform unit, uniform 70 % repair)
  DG-06 round report aggregates exclude DEFENDER defenses from the attack/shield/hull sums (ships only)
  DG-07 the two history tables that hold LIVE orphans have no retention/cleanup path, and three debris fields
        exist without provenance
  DG-08 combat_unit_state plus 8 orphan functions remain in LIVE after the repo cleanup migrations; repo and
        LIVE agree they are retired, but they are still callable by service_role

NOT IMPLEMENTED (deliberate; out of scope for Phase 0)
  multi-attacker fleets, multi-defender fleets, defender reinforcement (DEFEND), ACS combat integration,
  combat-related items/lifeforms/officers/merchant/auction, battle-report UI

FUTURE UPDATE (do not start)
  lifeform-specific combat effects (explicitly deferred to a later engine version), any combat balance change
```

### 14.22 Verified closed — not reopened

- Defense Engine certification (2026-09-21): this audit only consumed its interfaces
  (`planet_defenses`, `defense_definitions.attack|shield|hull`, `get_combat_defense_*`,
  `repair_defenses_after_combat`) and modified nothing.
- Research certification (2026-09-21): only `get_player_research_level` was read, as a canonical reader.
- Identity/Guest, Buildings, Universe Evolution and the single-attacker participant propagation are untouched.
- The three protected migrations and `docs/systems/README_FLEET_ENGINE.md` were not modified;
  `supabase/migrations/20260921044623…044659` remain exactly as the Block 1 closeout left them.
- No migration, schema, RLS, ACL, formula, frontend or balance change was made by this audit.

### 14.23 Recommended next mission (smallest safe CORE step)

```text
MISSION: COMBAT CORE PHASE 1 — INVARIANT AND COVERAGE REPAIR (no new gameplay)

Step 1 (highest value, no gameplay change): restore a runnable combat fixture.
  Rewrite supabase/tests/combat_participant_propagation.sql so it resolves its player/planet ids from LIVE at
  run time (the shipyard_defense_lifecycle.sql pattern) while keeping the rolled-back transaction. That makes
  the real ATTACK pipeline verifiable again.

Step 2: fix CB-01 with a forward-only migration that gives expedition battles the same contract as the normal
  path — participants for the two expedition sides and stats sourced from the certified get_combat_* readers —
  without touching the ATTACK path. Validate with the new fixture plus one expedition case.

Step 3 (bounded hygiene, one migration): add the missing battle FKs (CB-02) with the orphan rows handled
  explicitly, close the CB-05 EXECUTE surface with the 20260914223220 pattern, and optionally add the per-fleet
  error isolation behind CB-04.

Do NOT in that mission: implement ACS/DEFEND, change formulas, change balance, touch Defense/Fleet/Research, or
build a battle-report UI. Do not create a second combat architecture: extend the existing chain.
```

### 14.24 CORE question — explicit answer

> **Does LGI currently have one authoritative Combat Engine chain from Fleet arrival → combat snapshot →
> technologies → rounds → losses → debris → defense repair → battle result, or are there parallel/orphaned paths
> that must be resolved before implementation?**

**It has exactly one authoritative chain, and it is production-reachable.**
`process_fleet_movements → resolve_attack_arrival → resolve_combat → initialize_individual_combat_units →
run_expedition_combat → process_combat_round_v2 → … → sync_combat_battle_final_counts → apply_attack_loot →
repair_defenses_after_combat → create_combat_debris → RETURNING` covers snapshot, technologies, rounds, losses,
debris, defense repair and battle result inside a single transaction, with technologies routed through the
certified `get_combat_ship_*` / `get_combat_defense_*` readers and replay safety anchored on
`combat_battles.ux_combat_battles_one_per_fleet`.

The parallel/orphaned material is **real but inert**: eight legacy functions with zero callers and one legacy
table (`combat_unit_state`) are still present in LIVE after the repo's cleanup migrations, and the expedition
branch of combat is a genuine second *entry* into the same pipeline that the participant migration left behind
(CB-01). Neither is a competing architecture and neither requires replacing the current design.

The preconditions for Combat Phase 1 are therefore **not architectural**: they are (1) a runnable combat test,
(2) the expedition participant/stat contract, and (3) the two missing battle foreign keys. Once those are closed, a
new Combat implementation can extend the existing chain without creating a second combat engine.

### 14.25 Mission closeout — preserve / integrate / commit / sync gate

- The audit remained **read-only**: no migration, schema, RLS, ACL, formula, frontend or Fleet/Defense/Research
  change. All LIVE work was read-only inspection (`pg_proc`, `pg_constraint`, `pg_indexes`, `pg_policies`,
  `has_function_privilege`, row counts); no `BEGIN … ROLLBACK` diagnostic mutation was executed against
  production, precisely because the only available combat fixture's identifiers no longer exist (CB/stale test).
- The full forensic audit lives here, in the canonical Combat document; `docs/PROJECT_CONTEXT_PROMPT.md` was
  updated with the operational control-panel state only.
- Protected material (`docs/systems/README_FLEET_ENGINE.md`, the three `20260921044623…044659` migrations, the
  four 0-byte artefacts, both stashes) was preserved untouched and was **not** committed.
- Commit scope: this file plus `docs/PROJECT_CONTEXT_PROMPT.md`. No push.

---

## 15. PHASE 1 — INVARIANT, FIXTURE AND PRODUCTION-CONTRACT REPAIR (2026-09-21)

> Scope executed: runnable combat fixture, CB-01 forward-only repair, CB-02 forward-only repair,
> CB-05 combat-scoped ACL review, production-path assertions, documentation of the resulting contract.
> No formula, balance, Fleet, Defense, Research, Identity, ACS or DEFEND change.

### 15.1 Status

| Finding | Before Phase 1 | After Phase 1 |
|---|---|---|
| **CB-01** expedition combat | HIGH — units without `participant_id`, raw statistics **and** an aborting ambiguity error | **FIXED — verified LIVE** |
| **CB-02** battle foreign keys | MEDIUM — two history tables without a battle FK, 1,342 orphan rows | **FIXED (forward integrity); orphans deliberately preserved** |
| **CB-05** EXECUTE surface | LOW — 12 combat helpers executable by PUBLIC/anon/authenticated | **FIXED — 12/12 narrowed, `service_role` intact** |
| **CB-03** debris double-credit window | LOW, unreachable | **OPEN (unchanged, still unreachable)** |
| **CB-04** one poisoned fleet blocks the batch | MEDIUM robustness | **OPEN** |
| Test coverage | the only combat suite was stale/blocked | **2 runnable production-path fixtures** |
| **CB-06** (new, found in Phase 1) | — | **FIXED** (see §15.3) |

Combat Engine overall status: **OPEN — not certified** (Phase 1 removed the known blockers; the engine still
has no client battle-report contract and no ACS/DEFEND model).

### 15.2 Migrations applied to LIVE during Phase 1

| Version | Name | Purpose |
|---|---|---|
| `20260921165815` | `fix_expedition_combat_participant_and_stat_contract` | CB-01: ENEMY participant type + expedition participants + canonical statistics |
| `20260921165859` | `add_combat_history_battle_fks` | CB-02: battle FKs on the two history tables (`NOT VALID`, `ON DELETE CASCADE`) |
| `20260921165917` | `harden_combat_internal_execute_surface` | CB-05: narrow 12 combat helpers to `service_role` |
| `20260921170345` | `fix_expedition_combat_ambiguous_battle_id_reference` | CB-06: remove the aborting ambiguous `battle_id` references |
| `20260921170435` | `fix_expedition_survivor_round_scope` | CB-01: survivor write-back scoped to the final round |
| `20260921170453` | `fix_expedition_last_round_lookup_ambiguity` | CB-01: qualify the new last-round lookup |

All six are forward-only and minimal, and each carries either occurrence assertions or explicit
post-conditions. The local files use the server-assigned ledger versions, following repository convention.

### 15.3 CB-01 / CB-06 — expedition combat

Investigation of the LIVE definitions found **three** defects on the expedition branch, not one:

```text
1. participants (Phase 0 finding)
   resolve_expedition_pirates / resolve_expedition_aliens inserted combat_individual_units without
   participant_id and never created combat_battle_participants rows. The participant-aware ledger joins
   shots to the round snapshot on participant equality, so NULL = NULL never matched, no
   combat_round_damage row was produced and apply_combat_round_damage updated nothing → no losses.

2. divergent statistics (Phase 0 finding)
   the same inserts used RAW ship_definitions.attack|shield|hull: no technology scaling and a hull value
   ten times the normalized hull used by the ATTACK path (structural_integrity = hull, not hull*10).

3. aborting ambiguity (NEW — CB-06)
   both creators declare an OUT parameter named `battle_id`, and their counter UPDATE used an unqualified
   `battle_id` inside subqueries. With plpgsql.variable_conflict = error (the default) that raises
     ERROR: column reference "battle_id" is ambiguous
   proven LIVE in this session. Expedition combat therefore did not even reach the DRAW Phase 0 inferred:
   the function aborted, and because the fleet worker resolves every due fleet in one transaction, the
   error rolled back the whole tick (the CB-04 poison-pill path).
```

Repair (forward-only; no formula touched):

- `combat_battle_participants` gained the `ENEMY` participant type (an NPC hostile squadron: no fleet, no
  planet, no player) with explicit shape/side checks, and `player_id` is nullable **only** for `ENEMY`
  through a replacement CHECK (`participant_type = 'ENEMY' OR player_id IS NOT NULL`). Every FLEET/PLANET
  participant still requires a player.
- both creators insert `ATTACKER/FLEET` (the real expedition movement) and `DEFENDER/ENEMY` participants,
  and every combat unit row carries the matching `participant_id`.
- both creators take unit statistics from the certified readers `get_combat_ship_attack|shield|hull`
  (attacker = the fleet owner's technologies; enemy = canonical base values at research level 0 with the
  existing alien multiplier preserved verbatim) and set `structural_integrity = hull * 10` like the ATTACK
  path.
- the ambiguous counter subqueries are qualified through an alias.
- the survivor write-back (quantity rewrite **and** cleanup) is scoped to the final round, exactly like
  `resolve_attack_arrival`.

Numeric consequences (intended convergence, not a balance change):

- expedition **attack/shield values are unchanged** for both sides (base × the same multipliers); the
  enemy hull is now expressed in the same normalized scale as every other unit, so expedition battles
  behave like normal battles instead of using units ten times tankier per point of attack.
- the attacker's own weapons/shielding/armour technologies now apply (canonical contract).
- **recorded, not changed:** the alien technology lookup in `resolve_expedition_aliens` searches
  `research_definitions` for the ids `weapons` / `shielding` / `armour`, which **do not exist** (LIVE uses
  `weapons_technology`, `shielding_technology`, `armour_technology`), so `alien_tech` is always `0 + 3`.
  Repairing that lookup would change expedition difficulty — balance — so it stays a reported finding.

### 15.4 CB-02 — battle foreign keys

- `combat_round_snapshot_units.battle_id` and `combat_round_damage.battle_id` now reference
  `combat_battles(id)` with `ON DELETE CASCADE`, matching every other battle child table
  (`combat_battle_participants`, `combat_rounds`, `combat_shots`, `combat_individual_units`,
  `combat_debris_generations`, `combat_defense_repairs`).
- Both constraints are deliberately **`NOT VALID`**: new and updated rows are enforced while the 1,342
  historical orphan rows (661 + 681, belonging to 17 deleted battles) are **left untouched**. No DELETE,
  no data archaeology. A future, separately verified cleanup mission may remove them and then
  `VALIDATE CONSTRAINT`.
- No index was added: both tables already carry a unique index whose leading column is `battle_id`.
- Verified LIVE after the migration: both FKs exist, `convalidated = false`, `confdeltype = 'c'`, orphan
  counts unchanged (661 / 681).

### 15.5 CB-05 — combat-scoped EXECUTE narrowing

Twelve combat helpers were executable by `PUBLIC`/`anon`/`authenticated`
(`calculate_shield_bounce`, `calculate_combat_damage`, `calculate_combat_ship_losses`,
`calculate_combat_defense_losses`, `calculate_combat_ship_debris`, `calculate_combat_defense_debris`,
`calculate_combat_total_debris`, `combat_hull_from_integrity`, `get_combat_round_snapshot`,
`get_combat_unit_snapshot`, `expand_all_rapidfire_v2`, `finish_combat_round_v1`). Each was checked against
the five mission conditions before changing anything:

1. **unnecessary** — no client caller exists: the frontend RPC surface is
   `sync_current_planet_resources`, `can_start_building`, `can_start_research`, `can_build_ship`,
   `can_build_defense`, `start_fleet_mixed`, `start_fleet`, `get_universe_evolution_monitor_public`
   (repository search over `src/`, `worker/`, `scripts/`), and the tables they read deny direct API access
   to client roles, so a client call could not read a single row;
2. **production callers unaffected** — every internal caller chain runs under `SECURITY DEFINER` functions
   owned by `postgres`, and all twelve functions are owned by `postgres`;
3. **no client contract** — none is a documented client entry point;
4. **combat-scoped** — only combat functions are touched;
5. **verifiable** — `has_function_privilege` was measured before and after, and both production-path
   fixtures were re-run afterwards.

Result verified LIVE: all twelve are `anon = false`, `authenticated = false`, `PUBLIC = false`,
`service_role = true`; every other combat function is unchanged (`get_combat_ship_*`,
`get_combat_defense_*`, `resolve_attack_arrival`, `resolve_combat`, `process_combat_round_v2`, …).

### 15.6 Test fixtures

| File | Covers | Assertions |
|---|---|---|
| `supabase/tests/combat_participant_propagation.sql` | full ATTACK production path: fleet arrival → battle → participants → units → snapshot → shots → damage ledger → losses → loot → repair → debris → RETURNING, plus replay | 12 |
| `supabase/tests/combat_expedition_combat.sql` | repaired expedition path (pirates + aliens) → participants → units → damage ledger → losses → survivors | 10 |

Fixture strategy (why the old fixture stopped working and how this one is built):

- identifiers are **resolved from LIVE at run time** (a HUMAN player with a real planet, and another real
  planet in the same universe as the target), following `shipyard_defense_lifecycle.sql`; no historical
  player/planet/battle UUID is hardcoded. The only fixed UUIDs are two synthetic `fleet_movements.id`
  values inside the expedition fixture, which exist to make the expedition RNG tiers reproducible.
- the fleet write trigger `enforce_player_write_access` requires an authenticated identity, so the fixture
  simulates a real client session with
  `set_config('request.jwt.claims', json_build_object('sub', <player user_id>, 'role','authenticated'))`
  — the same convention as the shipyard and research suites — and clears it again before exiting.
- **rollback safety does not depend on the client**: the whole fixture + battle runs inside a nested
  PL/pgSQL block that is undone by a sentinel exception before the block exits, so the file is safe even in
  an auto-committing SQL editor. The file-level `begin;/rollback;` only wraps the report temp table.

### 15.7 Test results (LIVE, 2026-09-21)

ATTACK production path — **12/12 PASS**:

| # | Assertion | Observed |
|---|---|---|
| 01 | battle created, `fleet_id`/attacker/defender correct, fleet was ARRIVED | PASS |
| 02 | exactly two participants with correct ownership | PASS |
| 03 | units attributed (attacker / defender / null) | PASS — 20 / 12 / 0 |
| 04 | round snapshot belongs to the battle, no null participants | PASS — 32 rows |
| 05 | damage ledger resolves real damage | PASS — 92–149 rows, 790 damage |
| 06 | battle finished, one result flag, attacker win | PASS |
| 07 | losses derived (defender ships 10/10, defenses 2/2, attacker losses 0) | PASS |
| 08 | survivors persisted to `fleet_movement_ships` / `planet_ships` | PASS |
| 09 | debris generated once and consistent with losses (metal 6000 = 30 % of 20000) | PASS |
| 10 | loot applied exactly once | PASS |
| 11 | defense repair recorded once and applied to `planet_defenses` | PASS |
| 12 | replay idempotent: same battle, no second battle/debris/repair, fleet RETURNING | PASS |

Expedition path — **10/10 PASS**, repeated with different (stochastic) outcomes:

| # | Assertion | Observed |
|---|---|---|
| P1 | pirate battle has ATTACKER/FLEET + DEFENDER/ENEMY participants | PASS |
| P2 | pirate units attributed | PASS — 20 attacker / 10–13 enemy / 0 null |
| P3 | pirate snapshot rows, no null participants | PASS |
| P4 | pirate damage ledger resolves REAL damage | PASS — 41–46 rows, 4100–4820 damage |
| P5 | pirate battle finished, one flag, result returned | PASS — ATTACKER_WIN |
| P6 | pirate defenders destroyed, losses derivable | PASS — 10–13 destroyed |
| P7 | pirate survivors written back from the final round | PASS — fleet = last-round alive |
| A1 | alien battle has ATTACKER/FLEET + DEFENDER/ENEMY participants | PASS |
| A2 | alien units attributed | PASS — 20 / 15 / 0 |
| A3 | alien damage ledger resolves real damage | PASS — 48–71 rows, 9406–14820 damage |
| A4 | alien battle finished with consistent survivors | PASS — ATTACKER_WIN and DEFENDER_WIN observed |

Before the repair the expedition call could not even complete (CB-06 ambiguity); for the participant-less
units the damage ledger stayed empty, so no loss was possible.

Execution note (environment limitation, recorded honestly): this session has no local `psql` and no
database credentials, and the available database tool executes SQL text but not a local file. The two
committed fixtures were therefore executed against LIVE through their exact statement sequence inlined in a
single call each (same fixture, same functions, same assertions, same values). Both files were additionally
verified mechanically: balanced `$test$` quoting, one `begin;`/`rollback;`, single trailing newline,
42/42 and 24/24 declared-and-used variables with no undeclared or unused variable.

### 15.8 LIVE verification performed

- **Rollback safety:** after every fixture run the LIVE state was compared against the pre-run baseline —
  `combat_battles` 0, `combat_battle_participants` 0, `combat_individual_units` 0, `combat_rounds` 0,
  `combat_shots` 0, `combat_debris_generations` 0, `combat_defense_repairs` 0, `fleet_movements` 0,
  `expedition_results` 0, `planet_defenses` 0, `planet_ships` quantity 1, `debris_fields` 3 with an
  identical metal total, orphans 661 / 681. No residue.
- **Definitions:** expedition creators re-read after each migration (participant inserts present, canonical
  readers present, no raw-stat tuple left, no ambiguous reference left).
- **Constraints:** participant type/shape/side/player CHECKs, both new battle FKs (`NOT VALID`, cascade).
- **ACLs:** before/after `has_function_privilege` for the twelve helpers plus the untouched engine entry
  points.
- **Migration ledger:** the six versions in §15.2 are recorded in `supabase_migrations.schema_migrations`.

### 15.9 Remaining open items

```text
BUG
  CB-03 create_combat_debris can credit a debris field twice in the race window between its provenance
        check and the ON CONFLICT insert (unreachable in the current locked path; LOW).
  CB-04 process_fleet_movements resolves every due fleet in one transaction with no per-fleet error
        isolation: a single malformed/aborting fleet rolls back the whole tick and repeats every second
        (MEDIUM). CB-06 was exactly such an aborting fleet before this repair.
  Alien technology lookup ids (`weapons`/`shielding`/`armour`) do not exist, so alien_tech is always 3.
        Reported only: fixing it changes difficulty (balance).

DESIGN GAP
  DG-01 no client battle-report read path: all combat tables deny anon/authenticated and no owner-scoped
        policy or RPC exists, so the COMBATE feed in src/App.tsx cannot render anything (dead UI path).
  DG-02 no seeded determinism in rounds (random targeting and rapidfire rolls).
  DG-03 no defender-fleet identity in the participant model (ACS prerequisite).
  DG-04 legacy unit/snapshot uniqueness keys still in force.
  DG-05 shield domes have no distinct rule.
  DG-06 round report aggregates exclude DEFENDER defenses from the attack/shield/hull sums.
  DG-07 1,342 historical orphans and 3 provenance-less debris fields remain; the new FKs stay NOT VALID
        until a separate cleanup mission validates them.
  DG-08 combat_unit_state + 8 orphan functions remain in LIVE (inert).

NOT IMPLEMENTED
  multi-attacker / multi-defender fleets, defender reinforcement (DEFEND), ACS combat integration,
  combat items/lifeforms/officers, battle-report UI.

FUTURE UPDATE
  lifeform-specific combat effects; any balance change.
```

### 15.10 Recommended next mission

```text
MISSION: COMBAT CORE PHASE 2 — CLIENT BATTLE REPORT CONTRACT + ROBUSTNESS (bounded)

  1. DG-01: define the owner-scoped battle-report contract (SECURITY DEFINER reader or owner RLS policy
     over combat_battles/participants/rounds) so the existing UI feed can read real results, then refresh
     the generated client types. This is the only combat capability currently invisible to players.
  2. CB-04: per-fleet error isolation in the fleet worker (bounded savepoint or per-fleet exception) so a
     malformed fleet can no longer freeze the whole queue.
  3. CB-03: make create_combat_debris provenance-first (provenance row before crediting the field).

Do NOT in that mission: implement ACS/DEFEND, change formulas or balance, or touch Defense/Fleet/Research.
The engine is not certified yet; certification should follow these three items.
```

---

## 16. PHASE 2 — BATTLE-REPORT CONTRACT, WORKER ISOLATION, DEBRIS PROVENANCE (2026-09-21)

> Scope executed: DG-01 client battle-report read contract, CB-04 per-fleet worker error isolation,
> CB-03 debris provenance hardening, plus the tests, LIVE verification and documentation for each.
> No formula, balance, Fleet/Defense/Research/Identity change, no ACS/DEFEND, no battle UI redesign,
> no historical cleanup, no legacy removal.

### 16.1 Status

| Item | Before Phase 2 | After Phase 2 |
|---|---|---|
| **DG-01** client battle-report contract | none (every combat table denied to clients, COMBATE feed dead) | **IMPLEMENTED — `get_player_battle_reports`, authenticated-only, 7/7 PASS** |
| **CB-04** worker error isolation | one malformed fleet rolled back the whole tick | **FIXED — per-fleet subtransaction, 8/8 PASS** |
| **CB-03** debris double-credit window | real at function level, reachable only out-of-band | **HARDENED — battle-scoped advisory lock + observable branch, 5/5 PASS** |
| Phase 1 ATTACK path | 12/12 PASS | **12/12 PASS (re-verified after Phase 2 changes)** |
| Phase 1 expedition path | 10/10 PASS | **10/10 PASS (re-verified after Phase 2 changes)** |
| Combat Engine | OPEN — not certified | **OPEN — not certified** (unchanged: no ACS/DEFEND, no certification claim) |

### 16.2 Migrations applied to LIVE during Phase 2

| Version | Name | Purpose |
|---|---|---|
| `20260921174955` | `add_player_battle_report_contract` | DG-01 read contract (SECURITY DEFINER projection, authenticated only) |
| `20260921175038` | `add_worker_fleet_error_isolation` | CB-04 per-fleet subtransaction isolation in `process_fleet_movements` |
| `20260921175114` | `harden_combat_debris_provenance` | CB-03 battle-scoped advisory lock + observable conflict branch |

All three are forward-only; the local files carry the server-assigned ledger versions. `process_fleet_movements`
keeps its exact signature (no worker-boundary API change), so `run_fleet_worker` and `process_universe_tick`
were not modified at all.

### 16.3 DG-01 — the battle-report contract

```text
client (src/App.tsx COMBATE feed)
        ↓  supabase.rpc('get_player_battle_reports', { p_limit })
public.get_player_battle_reports(p_limit integer default 25)
        ↓  SECURITY DEFINER (owner postgres), search_path pinned
auth.uid() → players.user_id → players.id
        ↓  authorized only when that player id is a
combat_battle_participants.player_id of the battle
        ↓  projection of PERSISTED state only
combat_battles · combat_battle_participants · combat_rounds ·
calculate_combat_ship_losses / calculate_combat_defense_losses ·
combat_debris_generations · combat_defense_repairs
```

Authorization derivation (no new identity system): the attacking player is
`combat_battles.attacker_player_id`; the defending player is the `DEFENDER/PLANET` participant's `player_id`
(which is the target planet's owner); both appear as participant rows, so a single participant lookup
authorizes exactly the two sides. Expedition `ENEMY` participants have `player_id IS NULL` and therefore
authorize nobody, which correctly restricts expedition battles to the expedition owner. An unauthenticated
caller always receives an empty set (the player-mapping CTE is empty).

Returned contract (one row per battle, newest first, `p_limit` clamped to 1..100):

| Group | Columns |
|---|---|
| identity | `battle_id`, `created_at`, `finished_at`, `outcome` (`UNRESOLVED`/`ATTACKER_WIN`/`DEFENDER_WIN`/`DRAW`), `caller_role` (`ATTACKER`/`DEFENDER`) |
| participants | `attacker_player_id`, `defender_planet_id`, `defender_player_id`, `participants` (jsonb: side, type, player, fleet, planet) |
| persisted counters | `attacker_ships_before/after`, `defender_ships_before/after`, `defender_defenses_before/after` |
| economy | `loot_metal/crystal/deuterium`, `loot_applied_at` |
| combat effects | `debris_metal`, `debris_crystal`, `defenses_repaired` |
| report body | `rounds_played`, `rounds` (jsonb per-round summary), `losses` (jsonb per-unit destroyed quantities from the certified derived readers) |

Explicitly **not** done: no raw combat table is exposed (every `deny_direct_api_access` policy stays), no combat
formula is recomputed, no client-side reconstruction of outcomes, no new identity/ownership concept, no battle
UI redesign — the existing COMBATE feed consumes the contract and formats the same row shape (title/body) it
already had, now including the caller's own losses, debris and round count.

Client footprint: `src/App.tsx` (`loadMessages`) now calls the RPC instead of selecting `combat_battles`; the
generated `src/lib/database.types.ts` gained the matching `Functions` entry. `npx tsc -b` and `npm run build`
both pass.

### 16.4 CB-04 — per-fleet worker isolation

```text
pg_cron (1s) → run_fleet_worker() → process_fleet_movements()      [unchanged signature]
                                        │
                     global advisory xact lock (unchanged)
                                        │
   for each due fleet:  begin  … one fleet's whole resolution …  exception when others then
                                (status change, dispatch, combat, loot, repair, debris, return)   raise warning
                                                                                                FLEET_RESOLUTION_FAILED
                        end;   ← subtransaction: rolled back COMPLETELY, other fleets unaffected
```

- The isolation is a **subtransaction per fleet** (a PL/pgSQL block with an `EXCEPTION` handler), applied to all
  three worker loops (OUTBOUND dispatch, HOLDING expiry, RETURNING settlement). The database provides the
  subtransaction rollback, so no partial combat can survive a failure — combat stays atomic per fleet.
- Failures are **not swallowed**: each one raises
  `FLEET_RESOLUTION_FAILED fleet=<id> mission=<type> sqlstate=<code> error=<message>` into the Postgres logs
  (the same observability channel the worker already uses for its DEFEND warning), and the fleet keeps its previous
  status, so it stays visible and retryable by the next tick (queryable signal: an `OUTBOUND` row whose
  `arrives_at` is already in the past).
- Preserved invariants: combat atomicity, replay/idempotency guards, economic settlement, return-fleet behaviour,
  the global advisory lock, worker semantics and the function signature. `run_fleet_worker` and
  `process_universe_tick` are untouched, and the Fleet Engine architecture was not modified.

### 16.5 CB-03 — debris provenance disposition

Reachability analysis (recorded, not assumed):

- `create_combat_debris` is `service_role`-only (re-verified), so no client can reach it;
- its only engine caller is `resolve_attack_arrival`, which runs inside `process_fleet_movements` under the global
  advisory lock, holds the fleet row lock and is protected by `UNIQUE (fleet_id)` on `combat_battles` — the same
  battle cannot be resolved twice concurrently;
- the residual exposure is an out-of-band concurrent `service_role` invocation, which the previous
  check-then-credit-then-record order could double-credit.

Hardening applied (no formula, percentage, balance or historical data touched):

1. the whole function now takes a **battle-scoped advisory lock**
   (`pg_advisory_xact_lock(hashtextextended('combat_debris:'||p_battle_id::text, 0))`), so concurrent invocations
   serialize; the second observes the committed provenance row and returns `already_generated = true` without
   crediting anything — this also survives the per-fleet retry boundary introduced by CB-04;
2. the defensive `ON CONFLICT (battle_id)` branch (unreachable while the lock is held) now raises
   `COMBAT_DEBRIS_CONFLICT …` instead of silently continuing, so any future re-entry is observable.

Documented limitation: two genuinely concurrent sessions cannot be created from this environment, so the
concurrency guard is proven structurally (lock + observable branch present in the LIVE definition) and
behaviourally through replay (the same battle processed repeatedly credits exactly once). No historical debris was
cleaned and no debris field was modified in LIVE.

### 16.6 Phase 2 tests and results (LIVE, 2026-09-21)

| File | Covers | Result |
|---|---|---|
| `supabase/tests/combat_report_contract.sql` | DG-01: attacker read, losses == derived ledger, defender read, unrelated player, unauthenticated caller, raw-table closure under `authenticated`, limit guard | **7/7 PASS** |
| `supabase/tests/combat_worker_isolation.sql` | CB-04: failing fleet isolated, valid fleet resolved in the same call, failing fleet unchanged/retryable, valid battle complete, retry safe, handlers observable | **8/8 PASS** |
| `supabase/tests/combat_debris_idempotency.sql` | CB-03: single credit equal to the provenance amount, re-entry no-op, replay stability, structural guard, internal ACL | **5/5 PASS** |

Observed LIVE values: attacker report `outcome=ATTACKER_WIN`, `caller_role=ATTACKER`, 2 participants, ≥1 round,
losses payload `small_cargo destroyed = 10` equal to the derived ledger, debris > 0; defender read returned the same
battle as `caller_role=DEFENDER`; unrelated and unauthenticated callers 0 rows; `combat_battles` returned 0 rows for
role `authenticated` while the contract returned the battle; worker isolation: 1 row returned, no battle for the
invalid fleet, invalid fleet still `OUTBOUND`, valid battle with 2 participants / 32 units / 1 debris generation,
retry returned 0 rows without duplication; debris: 1 generation row, field delta == `metal_generated`, re-entries
returned `already_generated = true` with zero delta.

Regression gates re-run after the Phase 2 changes: **ATTACK 12/12 PASS**, **EXPEDITION 10/10 PASS** (attack: 106
ledger rows, 790 damage; expedition: 53 rows, 3300 damage, all defenders destroyed; alien: 48 rows, 8625 damage).
No Phase 1 assertion was weakened or removed.

All fixtures are rollback-safe by construction (nested block + sentinel) and resolve their identifiers from LIVE at
run time. The DG-01 defender branch is exercised without creating identities: the real auth account is re-pointed at
the defending player inside the rolled-back block, because `players.user_id` is FK-constrained to `auth.users`.

### 16.7 LIVE verification and residue proof

- After every fixture the full combat/fleet surface was compared against the pre-mission baseline:
  `combat_battles` 0, `combat_battle_participants` 0, `combat_individual_units` 0, `combat_rounds` 0,
  `combat_shots` 0, `combat_debris_generations` 0, `combat_defense_repairs` 0, `fleet_movements` 0,
  `fleet_movement_ships` 0, `expedition_results` 0, `planet_defenses` 0, `planet_ships` quantity 1,
  `debris_fields` 3 with an identical metal total, orphans 661 / 681, exactly 1 player with a `user_id`.
  No poison fleet, battle, round, participant, debris, expedition, test player/planet or altered resource remained.
- Grants verified LIVE: `get_player_battle_reports` → `anon = false`, `authenticated = true`, `PUBLIC = false`;
  `create_combat_debris` → client roles `false`; `deny_direct_api_access` on `combat_battles` still present.
- Definitions verified LIVE after each migration (three handlers present, advisory lock present, signature
  unchanged), and the three Phase 2 versions are recorded in `supabase_migrations.schema_migrations`.
- Static gates: `npx tsc -b` exit 0, `npm run build` exit 0 (worker + client), `git diff --check` clean.

### 16.8 Remaining open items after Phase 2

```text
BUG
  Alien technology lookup ids (`weapons`/`shielding`/`armour`) do not exist, so alien_tech is always 3.
        Reported only: fixing it changes expedition difficulty (balance).
  (CB-03 and CB-04 are closed by this phase: CB-03 hardened with the battle-scoped advisory lock,
   CB-04 fixed with per-fleet subtransaction isolation.)

DESIGN GAP
  DG-02 no seeded determinism in rounds (random targeting and rapidfire rolls).
  DG-03 no defender-fleet identity in the participant model (ACS prerequisite).
  DG-04 legacy unit/snapshot uniqueness keys still in force.
  DG-05 shield domes have no distinct rule.
  DG-06 round report aggregates exclude DEFENDER defenses from the attack/shield/hull sums.
  DG-07 1,342 historical orphans and 3 provenance-less debris fields remain; the two battle FKs stay NOT VALID
        until a separate cleanup mission validates them.
  DG-08 combat_unit_state + 8 orphan functions remain in LIVE (inert).
  DG-09 the battle-report contract is a list projection; a dedicated per-battle screen is not implemented
        beyond the jsonb payloads (participants, rounds, losses) it already exposes.

NOT IMPLEMENTED
  multi-attacker / multi-defender fleets, defender reinforcement (DEFEND), ACS combat integration,
  combat items/lifeforms/officers, battle-report screen beyond the existing COMBATE feed.

FUTURE UPDATE
  lifeform-specific combat effects; any balance change.
```

### 16.9 Recommended next mission

```text
MISSION: COMBAT CORE PHASE 3 — CERTIFICATION CANDIDATE (read-only + bounded hardening)

  1. Re-run the five combat fixtures (attack 12/12, expedition 10/10, report 7/7, worker 8/8, debris 5/5)
     as one certification evidence pack, capturing before/after LIVE state for each.
  2. Observe the CB-04 warning channel end-to-end in the real cron path (one deliberately malformed fleet
     seen once in the logs, then removed), so the observability claim is proven and not only asserted.
  3. Decide DG-07 as a separate, explicitly approved mission (still out of scope here): remove the 1,342
     historical orphans and VALIDATE the two battle FKs, or document them as permanent residue.
  4. Only then consider certifying the base Combat Engine (single attacker fleet vs one planet) as CLOSED,
     keeping ACS/DEFEND and multi-fleet explicitly outside the certified scope.

Do NOT in that mission: implement ACS/DEFEND, change formulas or balance, or start Lifeforms/Items/Officers.
```
