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

> **Historical context (2026-09-19) — superseded in part.** This section describes the pre-participant state.
> The participant layer it asks for was implemented afterwards (§11, §12), Phase 1/2 repaired and Phase 3
> certified the base engine, and the remaining single-fleet blockers are the battle header and the legacy
> uniqueness keys — see §18 (Phase 4 audit, 2026-09-21). Kept verbatim as provenance.

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

> **Historical context (2026-09-19) — superseded in part.** The `combat_battle_participants` table proposed
> here now exists in LIVE (with a later `ENEMY` participant type added in Phase 1), so this section is the
> design origin of §11/§12. The current gaps are re-audited in §18 (Phase 4). Kept verbatim as provenance.

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

---

## 17. PHASE 3 — CERTIFICATION AUDIT (2026-09-21)

> Read-only mission. **Zero implementation changes**: no migration, no schema, no code, no test edit,
> no formula, no balance, no Fleet/Defense/Research/Identity change, no ACS/DEFEND, no historical cleanup.
> Every claim below is marked PROVEN / INFERRED / NOT TESTED / OUT OF SCOPE, with provenance stated
> (deployed definition · LIVE observation · existing fixture re-run).

### 17.1 Certification decision

```text
COMBAT ENGINE — CERTIFIED
```

Certified scope (exactly what the evidence covers):

```text
ONE attacking fleet vs ONE planet (ATTACK)                 single-attacker model
plus the expedition combat branch (pirates / aliens)      same participant + ledger contract
on the deployed chain:  pg_cron(1s) → run_fleet_worker → process_fleet_movements →
                        resolve_attack_arrival → resolve_combat → initialize_individual_combat_units →
                        rounds (≤6) → losses → survivor write-back → loot → defense repair → debris →
                        RETURNING, with per-fleet isolation and an authenticated report contract
```

Explicitly **outside** the certified scope (stated, not treated as defects): ACS / DEFEND / multi-fleet
combat, defender fleets, seeded determinism, the shield-dome rule, the DG-07 historical-residue cleanup,
legacy-object removal, and the alien-technology balance item.

### 17.2 Evidence matrix

| # | Requirement | Verdict | Provenance |
|---|---|---|---|
| A1 | production worker reaches `resolve_attack_arrival` | **PROVEN** | deployed: `pg_cron` job 2 `SELECT public.run_fleet_worker()` (active, 1 s) → `process_fleet_movements` → `perform public.resolve_attack_arrival(v.id)` under `mission_type='ATTACK'` |
| A2 | ATTACK uses the authoritative chain | **PROVEN** | deployed: `resolve_attack_arrival` has exactly one caller (`process_fleet_movements`); `resolve_combat` has exactly one caller (`resolve_attack_arrival`) |
| A3 | no competing production combat entry | **PROVEN** | deployed: only three functions insert into `combat_battles` — `resolve_combat` (ATTACK) and the two expedition creators; `resolve_attack_arrival`, `resolve_combat` and `process_fleet_movements` are not executable by `authenticated` (LIVE privilege check) |
| A4 | legacy residue stays inert | **PROVEN** | all eight legacy objects (`simulate_defender_losses`, `initialize_combat_unit_state`, `snapshot_combat_round`, `apply_combat_hull_damage`, `calculate_combat_damage`, `get_combat_round_snapshot`, `get_combat_unit_snapshot`, `combat_hull_from_integrity`) have **no caller** and `anon` EXECUTE = false |
| B1 | attacker participant attribution | **PROVEN** | fixture 01/02 and P1 plus deployed `resolve_combat` inserting `ATTACKER/FLEET` with fleet, player and origin planet |
| B2 | defender participant attribution | **PROVEN** | fixture 02 (planet owner) plus deployed `resolve_combat` inserting `DEFENDER/PLANET` |
| B3 | expedition ENEMY participant supported | **PROVEN** | deployed: both creators insert `'DEFENDER','ENEMY'`; CHECK constraints allow `ENEMY` with the player-required rule; fixtures P1/A1 |
| B4 | every authoritative unit carries the correct participant | **PROVEN** | deployed: the unit inserts of `initialize_individual_combat_units`, both expedition creators and `create_combat_next_round` are 3/3, 3/3, 3/3 and 1/1 with `participant_id`; fixtures report 0 NULL participants |
| B5 | no NULL-participant path remains | **PROVEN** | no other function inserts combat units; runtime fixtures show exact attribution for planet and expedition battles |
| C1 | canonical ship/defence readers used | **PROVEN** | deployed: the six `get_combat_ship_*` / `get_combat_defense_*` readers apply `*(1 + level*0.10)` via `get_player_research_level`; `initialize_individual_combat_units` references them 12× (ships) + 6× (defences); each expedition creator 18× |
| C2 | technology routing unchanged | **PROVEN** | readers use `weapons_technology` / `shielding_technology` / `armour_technology`; no raw `x.attack,x.shield` tuple feeds unit rows (the remaining raw `SELECT … INTO x` is dead assignment) |
| C3 | no statistics drift introduced | **PROVEN** | `universes.fleet_debris_percentage = 30`, `defense_debris_percentage = 0` (unchanged since Phase 0) |

| D1 | maximum six rounds | **PROVEN** | deployed: `run_expedition_combat` `WHILE r<=6`; `process_combat_round_v2` raises for round > 6; `finish_combat_round_v1` forces DRAW at round 6 |
| D2 | round-start snapshots | **PROVEN** | `create_combat_round_snapshot` writes `shield_start`/`hull_start`/`alive_start`; `resolve_pending_target_damage` resolves from them |
| D3 | one target per alive unit, simultaneous construction | **PROVEN** | `generate_combat_round_v2` walks `alive_start` units in random order, picks one random opposite-side target per unit and writes the whole shot ledger before any damage (`is_initial_shot = true` tail) |
| D4 | rapidfire behaviour | **PROVEN** | `1-(1/v_rf)` probability with a random roll in `generate_combat_round_v2` and `expand_rapidfire_chain_v2` (RF shots carry the `false` tail); fixtures show RF-expanded ledgers (20 units → 143 rows) |
| D5 | shield absorption, hull damage, explosion | **PROVEN** | `resolve_pending_target_damage` → `calculate_shield_bounce` (1 % threshold), shield-first absorption, hull remainder, explosion roll below 70 % |
| D6 | shield regeneration, persistent partial hull | **PROVEN** | `create_combat_next_round` resets `shield_current := shield_max` and carries `hull_current` for survivors |
| D7 | winner/draw determination | **PROVEN** | `finish_combat_round_v1` (per round) and `run_expedition_combat` (battle flags); fixtures show exactly one result flag true, with `ATTACKER_WIN` and `DEFENDER_WIN` both observed |
| E1 | losses derived from the authoritative ledger, symmetric | **PROVEN** | both loss readers read `combat_individual_units` with no side bias; fixture R1b shows the reported payload equals the derived ledger |
| E2 | no orphan production loss calculator | **PROVEN** | `simulate_defender_losses` has no caller (see A4) |
| E3 | loot exactly once and replay-safe | **PROVEN** | deployed `loot_applied_at` guard plus fixtures 10 and the replay assertion 12 |
| E4 | defence repair called once, idempotent, transactional | **PROVEN** | deployed: `resolve_attack_arrival` calls it exactly once; per-defence `CONTINUE` guard + `UNIQUE (battle_id, defense_id)`; fixture 11 |
| E5 | repair cannot fabricate or cancel debris | **PROVEN** | the defence-loss and debris readers read `combat_individual_units` + definitions and do **not** read `planet_defenses` |
| E6 | one debris generation per battle, one field credit | **PROVEN** | fixture C1 (field delta == `metal_generated`, one generation row); C2/C3 replay returns `already_generated = true` with zero delta |
| F1 | replay/idempotency guards exist | **PROVEN** | unique fleet→battle index, arrival status gate, existing-battle return, closed-round exception, `loot_applied_at`, repair/round/shot/damage uniqueness, debris provenance + battle-scoped advisory lock |
| F2 | no second battle/loot/repair/debris/duplicate survivor write-back on replay | **PROVEN** | fixture 12 asserts exactly one battle, one debris generation, one repair row, unchanged `fleet_movement_ships`, status `RETURNING`, identical battle id |
| G1 | worker per-fleet isolation (deployed) | **PROVEN (presence, scope, effect)** | deployed `process_fleet_movements` contains exactly three per-fleet `EXCEPTION` handlers (OUTBOUND, HOLDING, RETURNING), each raising `FLEET_RESOLUTION_FAILED …` inside a subtransaction |
| G2 | worker isolation in production | **PROVEN by fixture, NOT OBSERVED in production** | fixture W1–W8 (bad fleet rolled back to `OUTBOUND`, valid fleet resolved in the same invocation, retry safe); production job 2 ran 1,765 times in 30 minutes with **0 failures** and 0 `FLEET_RESOLUTION_FAILED` log lines (128,546 log rows inspected) — no production fleet was poisoned |
| H1 | report contract authorization | **PROVEN** | fixtures R1 (attacker), R2 (defender-side owner, `caller_role=DEFENDER`), R3 (unrelated authenticated → 0 rows), R4 (unauthenticated → 0 rows) |
| H2 | no raw-table exposure | **PROVEN** | fixture R5: under `SET LOCAL ROLE authenticated`, `combat_battles` returns 0 rows while the contract returns the battle; all `deny_direct_api_access` policies intact; `anon` cannot execute the contract |
| H3 | no client-side combat reconstruction | **PROVEN** | the contract returns persisted counters, per-round summaries and derived per-unit losses; the client only formats them (R1b) |
| I1 | DG-07 non-blocking | **PROVEN** | see §17.4 |

### 17.3 Regression evidence (re-run in this mission, LIVE)

| Suite | Result |
|---|---|
| `supabase/tests/combat_participant_propagation.sql` (attack production path) | **12/12 PASS** |
| `supabase/tests/combat_expedition_combat.sql` | **10/10 PASS** |
| `supabase/tests/combat_report_contract.sql` | **7/7 PASS** |
| `supabase/tests/combat_worker_isolation.sql` | **8/8 PASS** |
| `supabase/tests/combat_debris_idempotency.sql` | **5/5 PASS** |

Static gates: `npx tsc -b` exit 0 · `npm run build` exit 0 (worker + client) · `git diff --check` clean.
No assertion was weakened, removed or replaced.

Same-session observations: attack battle 20 attacker / 12 defender units, 32 snapshot rows, 143 ledger rows,
790 damage, debris 6,000 metal, repair recorded; expedition pirates 113 ledger rows / 4,420 damage with all
defenders destroyed and survivors written back from the final round; aliens 48 rows / 6,595 damage.

### 17.4 DG-07 — historical residue disposition: NON-BLOCKING (proven)

| Question | Answer | Evidence |
|---|---|---|
| 1. unreachable from current production combat? | Yes | the 661 + 681 rows belong to 17 battle ids that no longer exist (`combat_battles` = 0), and every reader of those tables is keyed by a live `battle_id`; nothing enumerates them by any other means |
| 2. can they affect current combat calculations? | No | the loss readers read `combat_individual_units`, the debris readers read the unit ledger + definitions, repair reads the defence ledger, loot reads resources — none reads the two orphan tables |
| 3. can they be exposed through the battle-report contract? | No | the contract reads `combat_battles`, `combat_battle_participants`, `combat_rounds`, `combat_debris_generations`, `combat_defense_repairs` and the loss readers only |
| 4. can they affect replay/idempotency? | No | every guard is keyed on a live battle/fleet (`UNIQUE(fleet_id)`, status gate, per-battle uniqueness, debris provenance) |
| 5. can they affect losses/debris/repair/loot? | No | same reason as (2) |
| 6. are the three provenance-less debris fields reachable by combat? | No | they sit in **TEST - Universe 1** at coordinates with **no planet**, while combat credits debris at the defender planet's coordinate; the production universe holds 0 debris fields |
| 7. is `NOT VALID` acceptable for certification? | Yes | the constraints are enforced for every new row: a rolled-back probe attempting to insert an orphan row into both tables raised `foreign_key_violation` on both, so **new orphans are impossible**; `convalidated = false` only reflects the untouched history |

Disposition: historical residue isolated from the certified production path → **non-blocking**. No rows were
deleted, no FK was validated, no archaeology was performed.

### 17.5 Remaining items after certification (all non-blocking)

| Item | Classification | Note |
|---|---|---|
| Alien research ids `weapons`/`shielding`/`armour` do not exist → `alien_tech` is always 3 | **balance / design decision** (future) | PROVEN isolated: the dead lookup and `alien_tech` exist in exactly one function (`resolve_expedition_aliens`), and the ATTACK path functions contain no `alien_tech` or expedition RNG reference, so ordinary combat is unaffected. Value intentionally unchanged (changing it would rebalance expedition difficulty, explicitly out of scope) |
| DG-02 seeded determinism | non-blocking design gap | rounds are intentionally stochastic; not a defect |
| DG-03 defender-fleet identity | non-blocking design gap (ACS prerequisite) | no defender fleets in the certified scope |
| DG-04 legacy uniqueness keys | non-blocking design gap | only relevant to multi-fleet participants |
| DG-05 shield-dome rule | non-blocking design gap | uniform unit/repair semantics; a balance decision, not a defect |
| DG-06 defence stats excluded from round aggregates | non-blocking reporting gap | affects the round report's stat sums, not resolution or losses |
| DG-07 historical orphans / provenance-less debris | **historical residue** | §17.4 |
| DG-08 inert legacy table + 8 orphan functions | **historical residue** | A4: no callers, not client-executable |
| DG-09 report contract is a list projection | non-blocking design gap | a dedicated battle screen is future UI work; the data contract already exposes participants/rounds/losses |
| ACS / DEFEND / multi-fleet combat | NOT IMPLEMENTED | outside the certified scope by design |
| Combat items / lifeforms / officers | FUTURE UPDATE | not started |
| Residual dead `SELECT … INTO x` statements in the expedition creators | cleanliness (non-blocking) | leftover from the Phase 1 canonical-stat convergence; they feed no unit row and can be removed by a future hygiene mission |

No P0/P1/P2 core-engine defect remains open: the two historical bugs (CB-03, CB-04) were closed in Phase 2,
CB-01/CB-02/CB-05/CB-06 in Phase 1, and this mission found no new defect in the certified path.

### 17.6 Next engineering boundary

```text
COMBAT BASE ENGINE — CERTIFIED (single attacker fleet vs one planet + expedition branch)

Next work is explicitly OUTSIDE this certification:

  1. ACS / DEFEND / multi-fleet combat — a new engine block: it first requires explicit participant
     identity for multiple fleets (DG-03) and the participant-aware uniqueness keys (DG-04).
  2. Battle-report screen — a UI mission on top of the existing `get_player_battle_reports` contract
     (DG-09), no engine change required.
  3. DG-07 cleanup/validation decision — a separate, explicitly approved mission if the historical
     residue is ever to be removed and the two battle FKs VALIDATED.
  4. Alien-technology balance decision — product/balance work, not engine work.
  5. The other BLOCK 2 items (Identity/Guest decommission, browser certification) remain as recorded in
     PROJECT_CONTEXT.

Do not reopen the certified chain without new evidence of a defect.
```

---

## 18. PHASE 4 — ACS / DEFEND / MULTI-FLEET ARCHITECTURE AUDIT (read-only, 2026-09-21)

> Read-only audit. **Zero implementation changes**: no migration, no schema/constraint/index change, no
> function edit, no test edit, no Fleet/Defense/Research/Identity touch, no ACS/DEFEND/HOLDING
> implementation. The certified Combat Engine (§17) was not modified.
>
> Evidence levels: **LIVE VERIFIED** (catalog/inspection against the deployed database), **STATIC VERIFIED**
> (repository/code inspection), **INFERRED** (derived from verified facts), **NOT VERIFIED** (explicitly not
> checked), **OUT OF SCOPE**.

### 18.1 The map (deliverable)

```text
CURRENT CERTIFIED COMBAT  (§17)
        │
        ├── ATTACK      single attacking fleet vs one planet                     CERTIFIED
        │
        └── EXPEDITION  pirates / aliens, ATTACKER/FLEET + DEFENDER/ENEMY        CERTIFIED
                 │
                 ▼
        MULTI-FLEET EXPANSION  (NOT IMPLEMENTED — audited here)
                 │
        ┌────────┼────────────┬──────────────────┐
        ▼        ▼            ▼                  ▼
       ACS     DEFEND      HOLDING         multi-fleet ATTACK
   (attack     (defend     (achieved        (several attacking
    support)    support)    lifecycle)       fleets on one side)
```

Per block: **WHAT EXISTS · WHAT IS MISSING · ASSUMPTIONS · WHAT WOULD BREAK · WHAT IS SAFE · WHAT REQUIRES DESIGN**

| Block | Exists today | Missing | Single-fleet assumption that would break |
|---|---|---|---|
| **ATTACK (certified)** | full chain, participant layer, report contract | — | `combat_battles.fleet_id` + `ux_combat_battles_one_per_fleet` + `attacker_player_id` are single-valued |
| **EXPEDITION (certified)** | same chain, `ENEMY` participant | — | none beyond the above |
| **multi-fleet ATTACK** | the participant table can already hold several `ATTACKER/FLEET` rows (`UNIQUE (battle_id, fleet_id)` permits N distinct fleets) | per-fleet unit initialisation, participant-aware unit/snapshot keys, per-fleet settlement, loot attribution | `initialize_individual_combat_units` derives one attacker participant; `resolve_attack_arrival` settles one fleet; `apply_attack_loot` uses one fleet's cargo |
| **ACS (attack support)** | nothing beyond the general participant schema | dispatch, grouping, arrival semantics, combat participation | same as multi-fleet ATTACK |
| **DEFEND (defend support)** | mission name accepted by the CHECK, speed class, refusal guard, worker warning | everything else (dispatch allowed, holding fleet visible to combat, per-fleet defender participation, settlement home) | defenders are read **only** from `planet_ships`/`planet_defenses`; no function creates a `DEFENDER/FLEET` participant |
| **HOLDING** | lifecycle `OUTBOUND → ARRIVED → HOLDING → RETURNING → COMPLETED`, `holding_until`, authorization table, worker branch, speed class | combat participation, recall, fuel/max-duration product decisions, UI | a `HOLDING` fleet is invisible to combat: `resolve_combat` never reads `fleet_movements` for defenders |

### 18.2 A. Battle identity (LIVE VERIFIED)

```text
combat_battles
  id uuid PK
  fleet_id            uuid NOT NULL  FK → fleet_movements(id) ON DELETE CASCADE   ← single fleet
  attacker_player_id  uuid NOT NULL  FK → players(id)                             ← single attacker player
  defender_planet_id  uuid NULL      FK → planets(id)                             ← single defender planet
  UNIQUE INDEX ux_combat_battles_one_per_fleet (fleet_id)                         ← one battle per fleet
  INDEX idx_combat_battles_fleet (fleet_id) · idx_combat_battles_attacker_player_id
  INDEX idx_combat_battles_defender (defender_planet_id)
```

- What identifies a battle today: `combat_battles.id`, plus the one-fleet key `fleet_id`.
- `fleet_id` **presupposes exactly one attacking fleet**: `NOT NULL`, uniquely indexed, and used by
  `resolve_combat` as its replay key ("return the existing battle for this fleet").
- Columns that prevent multiple attackers: `fleet_id` (NOT NULL + unique) and `attacker_player_id` (single).
  `defender_planet_id` stays single by design (the battle's location).
- Separate fleet/participant identity **does** exist: `combat_battle_participants.fleet_id` is a separate
  nullable reference with `UNIQUE (battle_id, fleet_id)` — the participant layer is already N-fleet capable;
  only the battle header is not.
- Functions reading `combat_battles.fleet_id` (LIVE VERIFIED): `resolve_combat` (writes it),
  `initialize_individual_combat_units` (derives the attacker participant from it), `resolve_attack_arrival`
  (settles that fleet), `apply_attack_loot` (cargo capacity of that fleet), plus the inert legacy readers
  `get_combat_unit_snapshot` and `initialize_combat_unit_state`. Both expedition creators write `fleet_id`
  for the expedition movement.

### 18.3 B. Participant model (LIVE VERIFIED)

```text
combat_battle_participants
  id uuid PK · battle_id FK CASCADE
  side             CHECK IN ('ATTACKER','DEFENDER')
  participant_type CHECK IN ('FLEET','PLANET','ENEMY')
  shape CHECK:  FLEET  → fleet_id NOT NULL, origin_planet_id NOT NULL, planet_id NULL
                PLANET → planet_id NOT NULL, fleet_id NULL, origin_planet_id NULL
                ENEMY  → fleet_id, planet_id, origin_planet_id all NULL
  side/type CHECK: ATTACKER → FLEET only · DEFENDER → FLEET | PLANET | ENEMY
  player_id (FK players) NOT NULL except ENEMY (player_required CHECK)
  mission_type text NULL · created_at
  UNIQUE (battle_id, fleet_id) · UNIQUE (battle_id, planet_id)
  indexes: (battle_id, side, participant_type) · (player_id)
```

**Can the model represent two or more attacker fleets without ambiguity?** At the row level **yes**:
several `ATTACKER/FLEET` rows sharing a `battle_id` with distinct `fleet_id` satisfy every CHECK and both
unique keys (`UNIQUE (battle_id, fleet_id)` allows N distinct fleets; NULL-fleet `ENEMY` rows do not
collide). Nothing in the participant table caps the number of attackers.

What is blocked today (LIVE VERIFIED):

| Object | Constraint / behaviour | Effect on multi-fleet |
|---|---|---|
| `combat_battles.fleet_id` | `NOT NULL` + `ux_combat_battles_one_per_fleet` | one battle per fleet; a second attacking fleet cannot join the same battle through the header |
| `combat_battles.attacker_player_id` | single column | multi-attacker **players** are only representable through participant rows |
| `combat_individual_units` | `UNIQUE (battle_id, round_number, side, unit_type, unit_id, unit_number)` | two fleets fielding the same ship type both start at `unit_number = 1` → **collision** |
| `combat_round_snapshot_units` | same legacy unique key, plus `ON CONFLICT` on it | the snapshot insert silently skips the second fleet's identical unit → **silent data loss** |
| `combat_shots` | `UNIQUE (battle_id, round_number, shot_number)` | SAFE — a single battle-wide shot sequence |
| `combat_round_damage` | `UNIQUE (battle_id, round_number, source_shot_number)` | SAFE — keyed by shot |
| `combat_rounds` | `UNIQUE (battle_id, round_number)` | SAFE — battle-level aggregate |
| `combat_defense_repairs` | `UNIQUE (battle_id, defense_id)` | SAFE — planet-scoped |
| `combat_debris_generations` | `UNIQUE (battle_id)` | SAFE — debris is battle-level |
| no function creates `DEFENDER/FLEET` | verified: only `resolve_combat` and the two expedition creators insert participants | defending fleets have **no** code path at all |

`combat_individual_units.participant_id` is already written for every unit (Phases 1 and 3), which is exactly
what an N-fleet model needs; what remains are the two legacy uniqueness keys and the single-fleet header.

### 18.4 C. Uniqueness / replay invariants vs multi-fleet

| # | Invariant | Classification |
|---|---|---|
| 1 | `UNIQUE (battle_id, fleet_id)` on participants (N distinct fleets allowed) | **SAFE FOR MULTI-FLEET** |
| 2 | `UNIQUE (battle_id, planet_id)` on participants | **SAFE FOR MULTI-FLEET** |
| 3 | `combat_shots (battle_id, round_number, shot_number)` | **SAFE FOR MULTI-FLEET** |
| 4 | `combat_round_damage (battle_id, round_number, source_shot_number)` | **SAFE FOR MULTI-FLEET** |
| 5 | `combat_rounds (battle_id, round_number)` | **SAFE FOR MULTI-FLEET** |
| 6 | `combat_defense_repairs (battle_id, defense_id)` | **SAFE FOR MULTI-FLEET** |
| 7 | `combat_debris_generations (battle_id)` + battle-scoped advisory lock | **SAFE FOR MULTI-FLEET** |
| 8 | `ux_combat_battles_one_per_fleet` (one battle per fleet) + `combat_battles.fleet_id NOT NULL` | **REQUIRES CHANGE** for multi-fleet (the header merges N fleets into one battle) |
| 9 | `combat_individual_units (battle_id, round_number, side, unit_type, unit_id, unit_number)` | **REQUIRES CHANGE** for multi-fleet (identical units from different fleets collide) |
| 10 | `combat_round_snapshot_units` same key + `ON CONFLICT … DO NOTHING` | **REQUIRES CHANGE** for multi-fleet (collision silently drops units) |
| 11 | `resolve_attack_arrival` status gate + per-fleet settlement (`FOR UPDATE` on the one fleet) | **REQUIRES CHANGE** for multi-fleet settlement (N fleets per battle, each needing its own write-back and status transition) |
| 12 | `apply_attack_loot` idempotency (`loot_applied_at`) + capacity from `battle.fleet_id` | idempotency **SAFE**; capacity source **REQUIRES CHANGE** (whose cargo carries the loot is a design decision) |
| 13 | global fleet advisory lock + process-fleet per-fleet subtransaction | **SAFE FOR MULTI-FLEET** (unchanged) |
| 14 | round-closed exception, `generate_combat_round_v2` shot guard, `expand_all_rapidfire_v2` caller guard | **SAFE FOR MULTI-FLEET** (battle-scoped) |
| 15 | `combat_battles.attacker_player_id` single | **REQUIRES CHANGE** only if one battle must expose several attacker *players* at header level (participants already carry per-fleet players) |

**Answer to the core question:** the invariants that depend *accidentally* on a single attacking fleet are
(8) the battle header key and (9)/(10) the two legacy unit/snapshot uniqueness keys, plus (11) the
single-fleet settlement and (12) the loot capacity source. Everything else is either battle-scoped or already
participant-aware.

### 18.5 D. Attack path — where `fleet_id` becomes identity

```text
pg_cron(1s) → run_fleet_worker() → process_fleet_movements()
   OUTBOUND loop, per fleet, subtransaction                       [1] fleet identity = fleet_movements.id
     ATTACK → resolve_attack_arrival(p_fleet_id)                  [2] arrival boundary keyed by ONE fleet
        status gate: ARRIVED only (replay returns the existing battle)
        economic catch-up on the target planet
        battle_id := resolve_combat(p_fleet_id)                   [3] battle identity keyed by ONE fleet
             locks the fleet row; SELECT … FROM combat_battles WHERE fleet_id = p_fleet_id (replay key)
             INSERT combat_battles (fleet_id, attacker_player_id, defender_planet_id)
             INSERT participants: ATTACKER/FLEET (this fleet) + DEFENDER/PLANET (target planet)
             initialize_individual_combat_units(battle_id)        [4] attacker units from THIS fleet only
        participant ids resolved by (battle, fleet) and (battle, planet)
        run_expedition_combat(battle_id)                          [5] side-based rounds (fleet-agnostic)
        sync_combat_battle_final_counts                            [6] side-based totals
        fleet_movement_ships rewritten from THIS fleet's survivors [7] survivor write-back keyed by ONE fleet
        planet_ships / planet_defenses rewritten from DEFENDER units
        apply_attack_loot(battle_id)                               [8] cargo capacity of battle.fleet_id
        repair_defenses_after_combat(battle_id)                    [9] planet-scoped (fleet-agnostic)
        create_combat_debris(battle_id)                           [10] battle-level (fleet-agnostic)
        fleet_movements.status = 'RETURNING'                      [11] ONE fleet returns
```

Where a second fleet breaks the assumption:

| Step | Break |
|---|---|
| [3] | `ux_combat_battles_one_per_fleet` + the `fleet_id` replay lookup: a second fleet cannot join the same battle row, and `resolve_combat(second_fleet)` would create a **separate** battle for the same target |
| [4] | attacker units are created from one fleet: a second fleet's units are never initialised into the battle |
| [7] | survivor write-back targets the single `battle.fleet_id`: per-fleet survivor attribution has no home |
| [8] | loot capacity comes from one fleet: multi-fleet cargo accounting is undefined (design decision) |
| [11] | only one fleet transitions to `RETURNING`: other fleets would stay in their arrival state |
| [9]/[10] | **safe** — repair is planet-scoped and debris is battle-level, so both are already fleet-agnostic |

### 18.6 E. DEFEND infrastructure (LIVE + STATIC VERIFIED)

```text
IMPLEMENTED
  · mission name 'DEFEND' accepted by fleet_movements_mission_type_check
  · speed class: calculate_mission_fleet_speed_multiplier maps DEFEND → universes.holding_fleet_speed
  · refusal guard: start_support_fleet raises COMBAT_SUPPORT_NOT_READY for DEFEND
  · worker: process_fleet_movements emits
      "DEFEND movement % arrived but combat support is not implemented; kept in ARRIVED"
    and never moves a DEFEND row to HOLDING (defensive branch only: the dispatcher refuses DEFEND, so the
    branch is unreachable through the product path today)

NOT IMPLEMENTED
  · no dispatcher accepts DEFEND (BLOCKED BY COMBAT ENGINE, by design)
  · no defending-fleet storage: no table matches defender/stationed/reinforce/fleet_group/acs, and no column
    exists on planets / planet_ships / planet_defenses for an attached fleet
  · no DEFENDER/FLEET participant is ever created (verified across all deployed functions)
  · combat reads defenders only from planet_ships + planet_defenses; holdings are invisible to combat
  · no per-fleet defender settlement, no defender return semantics, no UI, no client types
```

Consequence (INFERRED from verified facts): a DEFEND fleet that somehow arrived would remain in `ARRIVED`
indefinitely — which is exactly why the dispatcher refuses it up front. A documented product boundary rather
than a bug.

### 18.7 F. HOLDING / ACS inventory (LIVE + STATIC VERIFIED)

```text
IMPLEMENTED (Fleet Engine "ACS_HOLD Fase A", migrations 20260919100000 + 20260919101000)
  data:      planet_support_authorizations(id, destination_planet_id, owner_player_id, guest_player_id,
             authorized_at, expires_at, revoked_at) — deny_direct_api_access policy, 0 rows in LIVE
  dispatch:  start_support_fleet(p_player_id, p_origin_planet_id, p_destination_planet_id, p_ships jsonb,
             p_support_mission, p_holding_until, p_idempotency_key) — SECURITY DEFINER, authenticated-
             callable, ACS_HOLD only; HOLDING refused as an internal state; DEFEND → COMBAT_SUPPORT_NOT_READY
  authz:     grant_planet_support_authorization / revoke_planet_support_authorization (authenticated)
  lifecycle: status OUTBOUND → ARRIVED → HOLDING → RETURNING → COMPLETED, holding_until absolute UTC window
             validated in the worker · speed class holding_fleet_speed

MISSING / NOT IMPLEMENTED
  · combat participation of a holding fleet (the visible target of this audit)
  · any ACS grouping: no fleet-group table, no grouping column, no join/split, no multi-fleet dispatch
  · recall during outbound/holding, holding fuel, maximum holding duration (documented product decisions)
  · UI: src/ (React/TypeScript) contains ZERO references to ACS_HOLD / HOLDING / DEFEND / support_fleet, and
    the mission selector offers only TRANSPORT, ATTACK, DEPLOY, ESPIONAGE, RECYCLE, EXPEDITION
  · generated client types carry no support-mission contract

LIVE STATE (this audit)
  · fleet_movements rows with mission_type in (ACS_HOLD, HOLDING, DEFEND) = 0
  · rows with status = HOLDING = 0 · planet_support_authorizations = 0
  → the Fase A feature has never been exercised in production; its only test
    (supabase/tests/fleet_acs_hold_lifecycle.sql) is repository-only and, per the Fleet Engine closeout, its
    LIVE run is still pending (NOT executed by this audit — Fleet Engine verification is OUT OF SCOPE)
```

Caller categories (§15 distinction) for the support objects: `start_support_fleet`,
`grant_planet_support_authorization` and `revoke_planet_support_authorization` have **database callers = 0**
and **runtime callers = 0** (no UI, no LIVE test run) yet are **client-callable** (`authenticated` EXECUTE =
true) — ready APIs, not dead code. `planet_support_authorizations` has three real consumers (the two
authorisation RPCs plus the dispatcher).

### 18.8 G. Fleet Engine interface it would have to expose (OUT OF SCOPE to change)

Treated as CLOSED per the Fleet Engine closeout; listed only as the contract Combat would consume:

| Interface element | Present today | Would be needed for |
|---|---|---|
| fleet identity | `fleet_movements.id` (uuid) + `fleet_movement_ships` composition | already sufficient per fleet |
| mission identity | `mission_type` CHECK includes ATTACK / ACS_HOLD / HOLDING / DEFEND | already sufficient |
| arrival | `arrives_at`, `status='ARRIVED'` transition in the worker | already sufficient |
| holding window | `holding_until` + `status='HOLDING'` | already sufficient (Fase A) |
| return | `returns_at` + `status='RETURNING'` computed from the outbound duration | already sufficient |
| participant hand-off | nothing: Combat reads `fleet_movements`/`fleet_movement_ships` directly and writes survivors back | a per-fleet hand-off that can occur N times for one battle (multi-fleet) |
| fleet grouping | **nothing** (no group/join/split concept exists) | ACS attack groups |
| defender attachment | **nothing** (a holding fleet is only a row in `fleet_movements` at the target planet) | DEFEND visibility: Combat must learn to read holding fleets as defenders |

Fleet Engine itself does **not** need redesign for ACS/DEFEND: its arrivals, holdings and returns are already
per-fleet; what is missing is the *Combat-side* consumption of more than one fleet per battle.

### 18.9 H. Round-engine compatibility matrix (LIVE VERIFIED, structural)

| Function | Multi-participant readiness | Evidence |
|---|---|---|
| `initialize_individual_combat_units` | **REQUIRES CHANGE** | participant-aware (12 refs) but derives **one** attacker participant from `combat_battles.fleet_id`; a second fleet's units are never created |
| `run_expedition_combat` | **SAFE** | side-based only; counts alive units per side regardless of how many fleets form that side |
| `process_combat_round_v2` | **REQUIRES CHANGE** | 0 participant references; its per-target loop uses `DISTINCT (target_side, target_unit_type, target_unit_id, target_unit_number)` → two fleets with identical units are conflated |
| `create_combat_round_snapshot` | **REQUIRES CHANGE** | writes `participant_id` but its `ON CONFLICT (battle_id, round_number, side, unit_type, unit_id, unit_number) DO NOTHING` silently drops a second fleet's identical unit |
| `generate_combat_round_v2` | **SAFE** (with participant-aware keys) | shot rows carry `attacker_participant_id`/`target_participant_id`; target choice is side-based by design |
| `expand_all_rapidfire_v2` | **SAFE** | delegates; no identity logic of its own |
| `expand_rapidfire_chain_v2` | **SAFE** | participant-aware (8 refs) attacker/target lookups |
| `calculate_combat_round_pending_damage` | **SAFE** | joins shots to the snapshot **on `participant_id`** |
| `resolve_pending_target_damage` | **REQUIRES CHANGE** | 0 participant references: it resolves a target by `(battle, round, side, unit_type, unit_id, unit_number)` only → ambiguous for identical units in two fleets |
| `apply_combat_round_damage` | **SAFE** | participant-aware (4 refs) update keyed by `target_participant_id` |
| `finish_combat_round_v1` | **SAFE** | side-based survivor counts |
| `create_combat_next_round` | **REQUIRES CHANGE (key only)** | carries `participant_id`, but its INSERT is subject to the legacy uniqueness key |
| `sync_combat_battle_final_counts` | **SAFE** (battle-level) | side-based totals; per-fleet totals would come from participants |
| `resolve_attack_arrival` | **REQUIRES CHANGE** | 20 participant refs, but the settlement is single-fleet (`single_attacker_lookup` by `fleet_id`, one `DEFENDER/PLANET` id, one fleet's ship write-back and one status transition) |
| `apply_attack_loot` | **REQUIRES CHANGE (design)** | 0 participant references; capacity taken from `v_battle.fleet_id` |
| `repair_defenses_after_combat` | **SAFE** | planet-scoped (`defender_planet_id`); fleet-agnostic |
| `create_combat_debris` | **SAFE** | battle-level provenance + defender planet coordinate |

Net shape: the round engine is *mostly* participant-aware already (shots, damage ledger, RF chains, damage
application) because Phases 1–3 propagated `participant_id`; the three real code changes needed are the two
legacy uniqueness keys, the target identity used by `resolve_pending_target_damage` /
`process_combat_round_v2`, and per-fleet initialisation + settlement.

### 18.10 I. Attribution domains for multi-fleet (ENGINE FACT vs DESIGN DECISION)

| Domain | Today (ENGINE FACT) | For multi-fleet | Classification |
|---|---|---|---|
| loss attribution | `calculate_combat_ship_losses` / `calculate_combat_defense_losses` group by `(side, unit_id)`; **no participant** | per-fleet loss reporting needs `participant_id` in the grouping | **NOT IMPLEMENTED** (side-level only) |
| survivor attribution | `resolve_attack_arrival` rewrites `fleet_movement_ships` for the single `battle.fleet_id` | each participating fleet needs its own survivor write-back and status transition | **DESIGN DECISION REQUIRED** |
| loot attribution | capacity from the single fleet; 50 % caps; stored on the battle | whose cargo counts and how loot is shared between attacking fleets | **DESIGN DECISION REQUIRED** |
| repair attribution | planet-scoped; writes the defender planet's `planet_defenses` | unchanged by multi-fleet | **ENGINE FACT — no change needed** |
| debris attribution | one battle-level generation credited at the defender planet's coordinate | unchanged by multi-fleet (battlefield-level) | **ENGINE FACT — no change needed** |
| damage/shot attribution | already per `participant_id` (attacker + target) | unchanged | **ENGINE FACT — already multi-fleet ready** |

No gameplay decision was taken here: the two "DESIGN DECISION REQUIRED" rows are exactly the questions the
product must answer before any multi-fleet implementation, and they are **not** bugs.

### 18.11 J. Battle-report contract levels (LIVE VERIFIED)

| Level | Fields in `get_player_battle_reports` | Multi-attacker representable? |
|---|---|---|
| battle-level | `battle_id`, `created_at`, `finished_at`, `outcome`, `attacker_player_id`, `defender_planet_id`, counters, `loot_*`, `loot_applied_at`, `debris_*`, `defenses_repaired`, `rounds_played` | **yes** (battle-wide aggregates) |
| participant-level | `participants` jsonb: `side`, `participant_type`, `player_id`, `fleet_id`, `planet_id` | **yes** — the payload already carries `ATTACKER A/B/C` plus the defender, because it is built from participant rows |
| caller-level | `caller_role` (`ATTACKER` / `DEFENDER`) | **yes** — a caller is on one side whatever the fleet count |
| defender identity | `defender_player_id` (single `DEFENDER/PLANET` lookup) | **yes** for one defended planet |
| round-level | `rounds` jsonb: round number + before/after unit counts (side-based) | **yes**, but per-fleet round detail is absent |
| unit-level | `losses` jsonb: `side`, `unit_type`, `unit_id`, `destroyed_quantity` | **NO** — no `participant_id`/`fleet_id` key, so per-fleet loss detail is not representable today |

The contract would not *break* with multiple attackers (authorization, battle identity and the participant
payload all scale), but a per-fleet report needs `participant_id` added to `losses` (and optionally `rounds`).

### 18.12 Classification of findings (Phase 4 taxonomy)

```text
BUG
  (none found — the certified chain was not re-opened and no defect was observed in it)

DESIGN GAP
  DG-10 combat_battles is single-fleet by header (fleet_id NOT NULL + unique + single attacker_player_id)
        while the participant layer is already N-fleet: the two layers disagree about cardinality.
  DG-11 the legacy unit/snapshot uniqueness keys (battle_id, round_number, side, unit_type, unit_id,
        unit_number) collide for identical units from different fleets, and the snapshot INSERT uses
        ON CONFLICT DO NOTHING on that key → silent data loss instead of an error.
  DG-12 target identity in process_combat_round_v2 / resolve_pending_target_damage omits participant_id.
  DG-13 loss grouping (side, unit_id) and the report `losses` payload carry no participant key → no per-fleet
        loss reporting.
  DG-14 loot capacity source is a single fleet (design decision pending, not a defect).
  DG-03 / DG-04 (recorded in Phase 0/3) are the same class as DG-10..DG-13 and remain open.
  DG-06 defence stats excluded from round aggregates (unchanged by this audit).

NOT IMPLEMENTED
  · ACS (attack support): no grouping, no dispatch, no combat participation.
  · DEFEND (defend support): dispatcher refuses it; no defending-fleet storage; no DEFENDER/FLEET participant.
  · multi-fleet ATTACK: no per-fleet initialisation or settlement.
  · HOLDING combat participation: holdings are invisible to resolve_combat.
  · support-mission UI and client types.

LEGACY / DEAD
  · the 8 inert combat functions + combat_unit_state (no callers, not client-executable) — unchanged here.
  · residual dead SELECT … INTO x statements in the expedition creators (Phase 3 §17.5).
  · NOT dead: start_support_fleet / grant_planet_support_authorization /
    revoke_planet_support_authorization are client-callable with 0 database and 0 runtime callers
    (ready APIs), reported as such.

DOCUMENTATION GAP
  1. README_COMBAT_ENGINE §3 ("Why ACS cannot be bolted onto the current model") and §4 ("Minimum
     multi-defender model") were written 2026-09-19 BEFORE the participant layer, the Phase 1 repairs and the
     certification: §4's proposed combat_battle_participants now exists (plus the later ENEMY extension) and
     §3's "current model" no longer matches LIVE. Both sections are labelled as historical superseded context
     in-place; §11/§12/§14/§17/§18 are authoritative.
  2. PROJECT_CONTEXT records ACS_HOLD "Fase A implemented" while LIVE has zero support rows, zero HOLDING
     rows and no UI; the "never exercised in production" nuance is now recorded in §18.7.
  3. The Fleet Engine README's statements that combat integration is "BLOCKED BY COMBAT ENGINE" remain
     accurate for DEFEND, but the blocker is now narrower than "no participant model": it is the single-fleet
     battle header plus the legacy uniqueness keys (DG-10/DG-11). Recorded here; the Fleet README is protected
     and was NOT modified.

SAFE / NO ISSUE
  · participant-table cardinality: several ATTACKER/FLEET rows per battle are already schema-legal.
  · shots, damage ledger, rapidfire chains, damage application: already participant-aware.
  · repair and debris attribution: fleet-agnostic by design.
  · worker isolation, replay guards, battle-scoped locks: multi-fleet neutral.
  · the certified chain needs no change to keep working.
```

### 18.13 PHASE 4A — proposed minimum architectural step (NOT implemented)

```text
PHASE 4A — PARTICIPANT / BATTLE IDENTITY FOUNDATION

Prerequisite
  The certified base engine (§17) stays as-is: no gameplay, no dispatch, no UI. This phase only removes the
  single-fleet assumptions so that a later multi-fleet feature cannot silently corrupt combat state.

Goal
  One battle able to own N fleet participants with unambiguous unit identity, while the current
  single-attacker flow keeps behaving EXACTLY as certified.

Must change (schema)
  1. combat_individual_units     : uniqueness →
       (battle_id, round_number, participant_id, unit_type, unit_id, unit_number)
  2. combat_round_snapshot_units : the same participant-aware key, with the snapshot INSERT's ON CONFLICT
                                   following it (removes the silent-drop behaviour)
  3. combat_battles              : decide the multi-fleet header shape WITHOUT breaking the replay key —
                                   either keep fleet_id as the "primary attacker" and relax NOT NULL, or move the
                                   one-battle-per-fleet guarantee to a participant-level unique index. This is
                                   the only schema decision that needs product sign-off.

Must change (logic, minimal)
  4. resolve_pending_target_damage + the target loop in process_combat_round_v2 : carry participant_id in the
     target identity (defensive correctness; no formula change).
  5. initialize_individual_combat_units : iterate the battle's ATTACKER participants instead of the one fleet
     derived from combat_battles.fleet_id (behaviour identical with a single participant).

Must NOT change
  · any statistic, formula, threshold, explosion rule, round cap, rapidfire probability, loot/repair/debris
    percentage.
  · loot/repair/debris attribution (loot stays single-fleet until its design decision; repair/debris are
    already fleet-agnostic).
  · resolve_attack_arrival's single-fleet settlement path (N-fleet settlement is a later phase).
  · the report contract, the worker, Fleet Engine, Defense, Research, Identity.
  · the certified fixtures, which must keep passing unchanged.

Migration boundary
  One forward-only migration for the two participant-aware uniqueness keys (both tables hold zero live-battle
  rows today; the 1,342 pre-existing orphans live in a battle-less history that the NOT VALID FKs already
  isolate), plus the (4)/(5) algorithm change as a separate migration if the header decision in (3) is
  deferred.

Affected functions
  create_combat_round_snapshot · create_combat_next_round · process_combat_round_v2 ·
  resolve_pending_target_damage · initialize_individual_combat_units

Affected constraints
  combat_individual_units unique key · combat_round_snapshot_units unique key ·
  (decision) combat_battles one-per-fleet unique index + fleet_id NOT NULL

Regression requirements
  · attack 12/12, expedition 10/10, report 7/7, worker 8/8, debris 5/5 must all still pass.
  · plus one new assertion: a battle with TWO ATTACKER/FLEET participants keeps two distinct unit sets with
    identical ship types and identical unit numbers (the collision case), proving no silent drop.

Why this is safe
  It changes only identity/keys and the internal target lookup: no new mission, no new gameplay, no new state,
  no formula. With a single attacking fleet the keys are equivalent (participant_id is constant per side), so
  certified behaviour is byte-identical.

Explicitly NOT part of Phase 4A: ACS grouping, DEFEND dispatch, DEFENDER/FLEET participation, loot/survivor
attribution decisions, holding-fleet visibility, support UI.
```

**Phase 4A is defined here and NOT implemented by this mission.**

---

## 19. PHASE 4A — PARTICIPANT / BATTLE IDENTITY FOUNDATION (2026-09-21)

> Implemented. This section records the problem, the decisions, the migrations, the changed functions and
> constraints, the new collision fixture, the regression evidence and the LIVE verification.
> Scope was exactly DG-10, DG-11, DG-12 and DG-13: **no ACS, no DEFEND, no holding combat, no multi-fleet
> settlement, no loot/survivor attribution decision, no formula, balance, UI or gameplay change.**

### 19.1 Problem this phase removes

The certified engine collapsed "one battle" with "one attacking fleet": `combat_battles` carried a single
`fleet_id` (uniquely indexed) while `combat_battle_participants` was already N-fleet capable, and both the
unit/snapshot uniqueness keys and the target/loss identities omitted `participant_id`. Two participating
fleets fielding the same ship type therefore shared `unit_number = 1`, which made their units *the same row*
— and `combat_round_snapshot_units` did not even error: its `ON CONFLICT … DO NOTHING` silently dropped the
second fleet's identical unit.

### 19.2 Decisions

| Item | Decision |
|---|---|
| **DG-10** battle identity | `combat_battles.fleet_id` is **kept** as the *initiating (primary) attacking fleet* and as the replay/idempotency key for that fleet (`UNIQUE (fleet_id)` unchanged, `NOT NULL` unchanged). Its meaning is now recorded in the database itself with a column comment. Additional attacking fleets live exclusively in `combat_battle_participants` (`ATTACKER`/`FLEET` rows); the header deliberately does not aggregate them. No header schema change was needed, so the certified replay path is untouched. |
| **DG-11** unit/snapshot uniqueness | both keys become `(battle_id, round_number, participant_id, side, unit_type, unit_id, unit_number)`; the legacy keys are dropped and the only `ON CONFLICT` consumer (`create_combat_round_snapshot`) moves to the new key, so a second fleet's identical unit can no longer be silently skipped. |
| **DG-12** target identity | `resolve_pending_target_damage` gains `p_target_participant_id` (and returns it); its snapshot lookup and damage-ledger cursor are keyed by it; `process_combat_round_v2` iterates `DISTINCT target_participant_id` as well. The old participant-less signature was retired. |
| **DG-13** loss identity | both loss readers (`calculate_combat_ship_losses`, `calculate_combat_defense_losses`) now group, join and order by `participant_id` and return it, so a loss row names the fleet that suffered it. The **public** report contract was deliberately left unchanged (per Phase 4A §8): the internal identity is now available and a per-fleet report payload is a later, separate decision. |
| §9 unit initialisation | `initialize_individual_combat_units` iterates the battle's `ATTACKER`/`FLEET` participants (one insert per fleet, each fleet's owner technologies) instead of deriving one fleet from `combat_battles.fleet_id`. With a single participant the produced rows are identical to the certified behaviour. |
| ACL hardening (side effect, fixed) | a new signature (`resolve_pending_target_damage`) and any `DROP` + `CREATE` reset EXECUTE privileges to `PUBLIC`. The Phase 1/2 hardening is re-applied to all three functions inside the same migration, and asserted by post-conditions. |

### 19.3 Migrations (forward-only, applied to LIVE)

| Version | Name | Contents |
|---|---|---|
| `20260922035055` | `participant_aware_unit_uniqueness` | the two participant-aware unique keys, the updated `create_combat_round_snapshot` (`ON CONFLICT` on the new key), the drop of the two legacy keys, the `combat_battles.fleet_id` semantics comment |
| `20260922035147` | `participant_aware_target_identity` | the participant-aware `resolve_pending_target_damage`, the `process_combat_round_v2` target loop, the retirement of the old signature |
| `20260922035253` | `participant_aware_loss_identity_and_unit_init` | participant-aware loss readers, participant-aware unit initialisation, EXECUTE re-hardening |

No historical migration was edited, no timestamp reused, no orphan row touched (661 + 681 still present and
still isolated by the `NOT VALID` FKs). DG-07 remains **NON-BLOCKING** and untouched.

### 19.4 Functions changed

```text
create_combat_round_snapshot      ON CONFLICT key → participant-aware (silent-drop removed)
resolve_pending_target_damage     new signature (+p_target_participant_id), participant-scoped lookup/cursor
process_combat_round_v2           target iteration DISTINCT now includes target_participant_id
initialize_individual_combat_units  iterates ATTACKER/FLEET participants per fleet
calculate_combat_ship_losses      participant_id in grouping, join, ordering, output
calculate_combat_defense_losses   participant_id in grouping, join, ordering, output
```

Nothing else was touched: the round formulas, thresholds, RNG semantics, rapid fire, explosion rule, loot,
repair, debris, settlement (`resolve_attack_arrival`), the report contract, the worker and the Fleet Engine
are unchanged.

### 19.5 Constraints and indexes

```text
added    combat_individual_units_participant_unique
         UNIQUE (battle_id, round_number, participant_id, side, unit_type, unit_id, unit_number)
added    combat_round_snapshot_units_participant_unique
         UNIQUE (battle_id, round_number, participant_id, side, unit_type, unit_id, unit_number)
dropped  combat_individual_units_battle_id_round_number_side_unit_ty_key
dropped  combat_round_snapshot_units_unique
unchanged combat_battles (pk, fleet_id FK CASCADE, ux_combat_battles_one_per_fleet, indexes)
unchanged participants (shape/side/type/player CHECKs, both unique keys, FKs)
unchanged shots / damage / rounds / repairs / debris keys
comment   combat_battles.fleet_id documented as the initiating fleet + per-fleet replay key
```

Because `participant_id` is nullable, the new unique indexes keep PostgreSQL's default NULL-distinct
semantics, so the 1,342 historical orphan rows (NULL participant ids) neither blocked index creation nor were
modified; every **new** row is written with a non-NULL participant (re-verified in §19.9).

### 19.6 Single-fleet compatibility (why the certified behaviour cannot drift)

- With one attacking fleet there is exactly one `ATTACKER/FLEET` participant, so the participant-aware unit
  key is equivalent to the legacy key (`participant_id` constant per side).
- `resolve_pending_target_damage` is now called with that participant, and every snapshot/ledger row of the
  battle belongs to it, so the lookup resolves exactly the same row as before.
- The loss readers group by the same sub-key they already used (`side`, `unit_id`) plus a constant column;
  their totals are unchanged, and all three callers (`calculate_combat_*_debris`,
  `repair_defenses_after_combat`, `get_player_battle_reports`) select named columns and aggregate.
- The initialiser produces the same rows with the same statistics — the only difference is that the attacker
  identity comes from the participant (identical player in the certified case) rather than from
  `combat_battles.fleet_id`.
- No formula, threshold, RNG call count, loop bound or ordering rule inside the round engine changed.

### 19.7 Expedition compatibility

Expedition battles keep `DEFENDER/ENEMY` (`player_id NULL`) and their own unit inserts (unchanged);
`ENEMY` was not converted into a fleet and no synthetic fleet identity was introduced. The expedition
fixture passes unchanged, including participant attribution and the participant-aware damage ledger.

### 19.8 Tests

New: `supabase/tests/combat_participant_identity_collision.sql` (13 assertions, rollback-safe, LIVE-resolved
identifiers, nothing permanent created):

| # | Assertion | Result |
|---|---|---|
| T1 | two attacker fleets + one planet are three participants | PASS |
| T2 | units attributed per fleet (20 + 5), none without participant | PASS |
| T3 | `participant A cruiser #1` and `participant B cruiser #1` are two distinct unit rows | PASS |
| T4 | the round-1 snapshot keeps all 37 units (25 attacker across three participants) — no silent loss | PASS |
| T5 | every shot and every damage row resolves to a real unit of the recorded participant | PASS |
| T6 | ship losses stay attributable per participant (2 rows for `cruiser`) | PASS |
| T7 | defence losses stay planet-scoped (single defender participant) | PASS |
| T8 | no authoritative unit without `participant_id` | PASS |
| T9 | a two-attacker battle still resolves with exactly one result flag | PASS |
| T10 | participant A resolves **its own** `cruiser #1` (1 shot) | PASS |
| T11 | participant B resolves **its own** `cruiser #1` (1 shot) | PASS |
| T12 | damage never crosses participants (A = 5, B = 5 shield damage) | PASS |
| T13 | a participant that owns no such unit is rejected instead of guessed | PASS |

Regression (certified suites, run on LIVE after the migrations and re-verified after the new fixture):

| Suite | Result |
|---|---|
| `combat_participant_propagation.sql` | **12/12 PASS** |
| `combat_expedition_combat.sql` | **10/10 PASS** |
| `combat_report_contract.sql` | **7/7 PASS** |
| `combat_worker_isolation.sql` | **8/8 PASS** |
| `combat_debris_idempotency.sql` | **5/5 PASS** |
| **total** | **42/42 PASS** |

Static: `npx tsc -b` exit 0 · `npm run build` exit 0 · `git diff --check` clean · no conflict markers.

### 19.9 LIVE verification

```text
constraints  both participant-aware keys present; the two legacy keys gone
function     create_combat_round_snapshot uses the participant-aware ON CONFLICT key
function     resolve_pending_target_damage has exactly one (participant-aware) signature
function     process_combat_round_v2 iterates DISTINCT target_participant_id
function     initialize_individual_combat_units iterates ATTACKER/FLEET participants
function     both loss readers return participant_id
ACLs         resolve_pending_target_damage and both loss readers: anon=false, authenticated=false,
             service_role=true (re-hardened); the collision fixture exercises them from the engine context
rows         after every fixture: 0 battles, 0 participants, 0 units, 0 rounds, 0 shots, 0 debris
             generations, 0 repairs, 0 fleets, 0 fleet ships, 0 expeditions, 0 planet_defenses,
             planet_ships quantity 1, debris_fields 3 with an identical metal total, 1 HUMAN player,
             orphans 661 / 681 unchanged, 0 units with NULL participant_id
```

**Residue: NONE.** No test player, planet, fleet, battle, debris or resource was created or left behind, and
nothing outside the combat identity layer was modified.

### 19.10 Explicitly NOT implemented by Phase 4A

```text
ACS grouping · ACS/support dispatch · DEFEND dispatch or DEFENDER/FLEET participants · holding-fleet combat
visibility · multi-fleet survivor settlement · multi-fleet loot attribution · fleet capacity aggregation ·
ACS/DEFEND UI · battle-report redesign (the public payload is unchanged) · any balance or formula change ·
DG-07 cleanup or FK validation · legacy-object cleanup
```

### 19.11 Next engineering boundary

```text
The identity foundation is in place (Phase 4A CLOSED). The next multi-fleet work is a separate decision:

  1. attack-side multi-fleet (ACS): grouping/dispatch model, per-fleet settlement
     (resolve_attack_arrival must write back N fleets and transition N statuses) and the loot/survivor
     attribution product decisions — none of which exist yet.
  2. DEFEND: defending-fleet storage + dispatch model, then per-fleet defender participation
     (DEFENDER/FLEET) on top of this foundation.
  3. per-fleet reporting: add participant_id to the report payloads (losses/rounds) if a battle screen needs
     it — the internal identity now supports it.
  4. DG-07 cleanup/validation decision, battle-report screen and alien-tech balance: unchanged, separate.

The certified base engine (single attacker fleet vs one planet + expedition branch) remains CERTIFIED and was
not modified in behaviour by this phase.
```

### 18.14 Verification and closeout of this audit

```text
LIVE VERIFIED (catalog + deployed definitions, read-only)
  battle/participant constraints, indexes and CHECK definitions · participant-inserting functions ·
  functions reading combat_battles.fleet_id · per-function participant_id/side-literal counts ·
  mission_type and status CHECK values · planet_support_authorizations shape and policies ·
  support RPC signatures and ACLs · absence of any defender-fleet/ACS/grouping table ·
  live row counts (0 battles, 0 HOLDING rows, 0 support rows, 0 authorizations) ·
  loss/loot/repair/debris attribution predicates · report-contract level fields

STATIC VERIFIED (repository)
  src/ contains no ACS_HOLD/HOLDING/DEFEND/support reference and the mission selector exposes no support
  mission · database.types.ts carries no support-mission contract · ACS migrations are
  20260919100000 + 20260919101000 · fleet_acs_hold_lifecycle.sql exists but its LIVE run is still pending

STATIC GATES RE-RUN
  npx tsc -b exit 0 · npm run build exit 0 · git diff --check exit 0

INFERRED (from verified facts, stated as such)
  a DEFEND fleet would stall in ARRIVED (dispatcher refuses DEFEND, so unreachable) ·
  multi-fleet settlements would collide on the legacy keys before producing wrong numbers

NOT VERIFIED / OUT OF SCOPE
  Fleet Engine ACS_HOLD lifecycle execution in LIVE (Fleet Engine closeout item) ·
  any multi-fleet behaviour (not implemented) · concurrency of the debris lock (Phase 2 limitation)

NO MUTATIONS OF ANY KIND were performed for this audit: no INSERT/UPDATE/DELETE/DDL, no temporary
fixture, no test run that changes state. Every statement executed was a catalog or definition read.
```

**Phase 4 closes with: the certified Combat Engine untouched, ACS/DEFEND/multi-fleet still NOT IMPLEMENTED,
their single-fleet blockers enumerated, and Phase 4A defined as the minimum next architectural step.**

## 20. PHASE 4B — ACS / DEFEND ARCHITECTURE AUDIT + DEFENDER/FLEET REPRESENTATION (2026-09-22)

> Cross-domain audit + minimal structural implementation. No gameplay was invented. The certified chain of
> §17 was not redesigned, and no second combat engine, resolver or formula was introduced.
>
> Evidence levels: **LIVE VERIFIED** (deployed catalog/definitions), **STATIC VERIFIED** (repository),
> **INFERRED**, **PRODUCT DECISION** (deliberately unresolved).

### 20.1 Sync gate at mission start

```text
branch                    main
HEAD                      c45aa49986f7c0cbd08030c0a7e6ba9b9be04619
origin/main               50faddfee713cb1a744e957cc93ae519069fb17b
ahead / behind            18 / 0   (origin/main is an ancestor of HEAD, merge-base = origin/main)
staged                    EMPTY
tracked modifications     README_FLEET_ENGINE.md (184/7, the documented protected local change)
tracked deletions         the 3 defence/analysis/RLS migrations under their OLD 20260920* names
untracked (pre-existing)  the same 3 migrations under their NEW 2026092104* names + the four 0-byte root artefacts
stashes                   stash@{0}, stash@{1} both intact and untouched
Phase 4A commits          present: 5be80aa (participant identity foundation) + c45aa49 (context record)
```

`README_FLEET_ENGINE.md` byte hash `a9d8f3789568779ec095be8330bdcc511c199080` and the three protected
migrations `2e6d366d…` / `324e8b7b…` / `46a32d66…` are **unchanged at mission end**. The Fleet README was
not modified, staged or restored; the stashes were not touched.

### 20.2 Inventory — what actually exists (LIVE VERIFIED)

Nothing was inferred from a name. Every object below was read from its LIVE definition and its callers.

| Object | Class | Live evidence |
|---|---|---|
| `combat_battles` | CANONICAL | `fleet_id NOT NULL` FK → `fleet_movements(id)`; `ux_combat_battles_one_per_fleet(fleet_id)` UNIQUE; single `attacker_player_id`; side-level aggregate counters; `loot_*` + `loot_applied_at` |
| `combat_battle_participants` | CANONICAL | `side ∈ {ATTACKER,DEFENDER}`, `participant_type ∈ {FLEET,PLANET,ENEMY}`; `side_type_check` **already permits `DEFENDER`/`FLEET`**; `shape_check` forces `fleet_id`+`origin_planet_id` for FLEET and `planet_id` for PLANET; `UNIQUE(battle_id,fleet_id)`; `UNIQUE(battle_id,planet_id)`; RLS ON + `deny_direct_api_access` |
| participant producers | CANONICAL (3 only) | `resolve_combat`, `resolve_expedition_pirates`, `resolve_expedition_aliens` are the **only** functions that INSERT into `combat_battle_participants`; none creates a `DEFENDER/FLEET` row |
| `combat_individual_units` / `combat_round_snapshot_units` | CANONICAL | participant-aware uniqueness keys (Phase 4A) |
| `planet_support_authorizations` | CANONICAL (temporary policy) | destination-owner consent; `UNIQUE(destination_planet_id,guest_player_id)`; RLS ON + `deny_direct_api_access`; only reachable through the grant/revoke RPCs |
| `start_support_fleet(p_player_id,p_origin_planet_id,p_destination_planet_id,p_ships,p_support_mission,p_holding_until,p_idempotency_key)` | READY (no caller yet) | `SECURITY DEFINER`, `auth.uid()`-checked, `ACS_HOLD` accepted, `DEFEND` → `COMBAT_SUPPORT_NOT_READY`, `HOLDING` → `HOLDING_IS_INTERNAL_STATE`, per-request idempotency key |
| `grant_planet_support_authorization` / `revoke_planet_support_authorization` | READY | client-callable with `auth.uid()` → `players.user_id` → `players.id` ownership chain; **0 database callers, 0 runtime callers** |
| `universes.holding_fleet_speed` | CANONICAL | `NOT NULL DEFAULT 1`; reached only via `calculate_mission_fleet_speed_multiplier(u,'ACS_HOLD')`; never re-implemented |
| `fleet_movements` HOLDING lifecycle | CANONICAL | `mission_type` admits the 10 names; support missions require `holding_until > arrives_at`; `status` admits `HOLDING`; partial unique index on `(player_id,idempotency_key)` |
| `combat_group` / `fleet_group` / `attack_group` / `support_group` | **DOES NOT EXIST** | no table, column, index or function anywhere in LIVE or in the repository |
| ACS *combat participation* · DEFEND dispatch · multi-fleet settlement · support-mission UI | NOT IMPLEMENTED | see 20.3/20.5 |
| `combat_hull_from_integrity`, `get_combat_unit_snapshot`, `initialize_combat_unit_state` | DEAD | exactly 1 definition each, **0 referencing functions**, not client-callable |
| ≤0, ≥1, >N client-callable combat internals | — | every `combat_*`/support internal helper is `anon=false, authenticated=false, service_role=true` |

**Classification correction to §18.7:** the Fleet Engine's `ACS_HOLD` Fase A (dispatch + hold lifecycle) is
real and LIVE (`20260919100000`, `20260919101000`), but it produces **no combat participation**: the worker's
`ACS_HOLD` branch moves `OUTBOUND → ARRIVED → HOLDING` and `resolve_combat` never reads `fleet_movements` for
defenders. `LIVE` holds **0** support rows, **0** HOLDING rows and **0** authorizations, so the transport
exists and the gameplay does not.

### 20.3 The dependency map — every question answered (LIVE VERIFIED unless marked)

**Identity**

| Question | Answer |
|---|---|
| What is a combat group? | **It does not exist.** A battle *is* the only membership container: `combat_battle_participants`. There is no pre-battle grouping object, and none is structurally required to represent N participants. |
| What creates the group? | — (no group). What creates a **battle**: `resolve_combat(p_fleet_id)`. |
| What creates a participant? | Exactly 3 functions; for the attack path `resolve_combat` inserts `ATTACKER/FLEET` (the initiating fleet) + `DEFENDER/PLANET` (the target planet's owner). |
| What creates a battle? | `resolve_combat(p_fleet_id)` only — reached from `resolve_attack_arrival` in the `ATTACK` branch of `process_fleet_movements`. |
| What fleet belongs to which participant? | `combat_battle_participants.fleet_id` for `participant_type='FLEET'`; `planet_id` for `'PLANET'`; `ENEMY` carries neither. |
| How does a fleet join? / leave? | **No join path and no leave path exist.** A participant set is written once, at battle creation, and never mutated afterwards. |
| How is a fleet prevented from joining after combat started? | There is nothing to prevent because nothing can join: participants are only written by `resolve_combat` before the first round, and the table is RLS-denied to `anon`/`authenticated`. A late ATTACK fleet does not join an existing battle — it creates its **own** battle. |
| What makes a fleet `ATTACKER/FLEET`? | Being the fleet passed to `resolve_combat` (`combat_battles.fleet_id` / `mission_type='ATTACK'`) or the single fleet of an expedition combat. |
| What makes a fleet `DEFENDER/FLEET`? | **Nothing.** The representation is legal (CHECK constraints), but no producer exists. `start_support_fleet` refuses `DEFEND`; the four dispatchers' allow-lists exclude it; `fleet_movements` has no client INSERT policy; the worker leaves a stray `DEFEND` row in `ARRIVED` with a WARNING. |
| How is `ACS_HOLD` represented? | As a `fleet_movements` row with `mission_type='ACS_HOLD'`, `status ∈ {OUTBOUND,ARRIVED,HOLDING,RETURNING,COMPLETED}`, a persisted `holding_until` and a per-request `idempotency_key`. It has **no** combat representation. |
| How is `HOLDING` represented? | As a **movement status**, never a dispatch mission (`HOLDING_IS_INTERNAL_STATE`). |
| How does a defending fleet enter combat? | **It cannot.** `initialize_individual_combat_units` reads defenders from `planet_ships`/`planet_defenses` only. |
| How are fleets ordered? | There is **no** ordering requirement: shot generation iterates the snapshot with `ORDER BY random()` and target selection is `ORDER BY random() LIMIT 1`; unit identity is `(participant_id, unit_type, unit_id, unit_number)`, which is order-independent. Attacker/defender fleet ordering is therefore **not** a semantic input (see PD-06/PD-07). |
| How are participants associated with players? | `combat_battle_participants.player_id` (NOT NULL for `FLEET`/`PLANET`, optional for `ENEMY`). |
| How is ownership validated? | Only at the **dispatch** boundary: `start_*` RPCs resolve `auth.uid() → players.user_id → players.id → owned planet`. `resolve_combat` derives participants from persisted movement/planet rows; it never trusts a client. |
| How are target planets associated? | `combat_battles.defender_planet_id` (the single battle-level target) + the `DEFENDER/PLANET` participant's `planet_id`. |
| How is battle identity generated? | `gen_random_uuid()` PK, with `combat_battles.fleet_id` as the replay anchor. |
| How is replay/idempotency preserved? | `resolve_combat` looks up an existing battle by `fleet_id` **before** creating one, under `FOR UPDATE` on the fleet row; `ux_combat_battles_one_per_fleet` is the hard backstop; `resolve_attack_arrival` early-returns for `RETURNING`/`COMPLETED`. |

**Attribution**

| Question | Answer |
|---|---|
| How are individual units attributed? | `combat_individual_units.participant_id` on every row (round 1 from `initialize_individual_combat_units`, later rounds copied by `create_combat_next_round`). |
| How are losses attributed? | `calculate_combat_ship_losses` and `calculate_combat_defense_losses` group by `participant_id` and return it (Phase 4A / DG-13). |
| How are survivors attributed? | Internally: per participant (`count(*) … alive` filtered on `participant_id`). Settlement: **only the initiating fleet and the planet** — see PD-08. |
| How is loot attributed? | `apply_attack_loot` reads the cargo capacity of `combat_battles.fleet_id` **only** and credits that one fleet. Idempotent via `loot_applied_at`. |
| How is repair attributed? | `repair_defenses_after_combat` is **planet-scoped**: it consumes `calculate_combat_defense_losses`, which filters `unit_type='DEFENSE'`, and writes `planet_defenses`/`combat_defense_repairs` at 70 %. Fleet ships can never enter it (proved by test D6). |
| How is debris attributed? | **Battle-scoped**: one advisory lock `combat_debris:<battle_id>`, one row in `combat_debris_generations` (`UNIQUE(battle_id)`), totals from `calculate_combat_total_debris` = Σ ship losses + Σ defence losses over **all** participants. Participant count is irrelevant (proved by test D13). |
| How does settlement know which fleet gets what? | By `side` + `fleet_id`: `ATTACKER/FLEET` with `fleet_id = p_fleet_id`, `DEFENDER/PLANET` with the destination planet. There is no generic per-participant settlement loop. |
| What does the battle report expose? | `get_player_battle_reports`: visibility is already participant-based (`EXISTS participant.player_id = me`), `participants` is a jsonb array of `{side,participant_type,player_id,fleet_id,planet_id}`, `caller_role` is ATTACKER if any attacker participant is the caller. `losses` is `{side,unit_type,unit_id,destroyed_quantity}` — **no participant key** (DG-13 survives at payload level). The payload was not changed. |

**Failure, concurrency and edge cases**

| Question | Answer |
|---|---|
| One fleet fails during dispatch/arrival? | Phase 2 CB-04 isolation is intact: each fleet is processed inside its own `BEGIN … EXCEPTION WHEN others → RAISE WARNING 'FLEET_RESOLUTION_FAILED …'`. A malformed participant cannot poison the batch. |
| One participant is invalid? | `initialize_individual_combat_units` raises `Battle % missing combat participants` if the battle has no usable attacker participant; `resolve_attack_arrival` raises `Battle % missing settlement participants` if either expected participant is absent. New in 4B: settlement raises rather than ignoring an unexpected `DEFENDER/FLEET`. |
| A fleet arrives late? | It builds a **second, independent battle** against the same planet. Sequential battles are serialized by the worker's global advisory lock. Whether late arrivals should join one battle is PD-04. |
| Two fleets arrive simultaneously? | `process_fleet_movements` iterates `ORDER BY arrives_at, id` with `FOR UPDATE SKIP LOCKED`; each is resolved independently → **two battles**, never one shared battle. This is the exact ACS gap. |
| An ACS group is cancelled? | No recall/cancel path exists for any mission (Fleet README §22.6). PD-11. |
| The target is destroyed? | `resolve_combat` requires the destination planet to have a player; nothing reads `planets.is_destroyed` in the attack path. Unchanged by 4B, recorded as an observation. |
| The battle is already resolved? | `resolve_attack_arrival` early-returns the battle id; `run_expedition_combat` is called only when `finished_at IS NULL`; `apply_attack_loot`, `repair_defenses_after_combat` and `create_combat_debris` are each individually idempotent. |
| Replay? | Same replay anchor (`combat_battles.fleet_id`), `ux_combat_battles_one_per_fleet`, per-fleet `idempotency_key`, `combat_debris_generations_battle_unique`. All regression-proved. |

### 20.4 What was implemented (migration `20260922043604_defender_fleet_participant_representation`)

Two functions changed. **No schema change was needed** — `combat_battle_participants` could already represent
`DEFENDER/FLEET`, so no table, column, index or constraint was added, relaxed or dropped.

```text
1. initialize_individual_combat_units(p_battle_id)
   + ONE new INSERT statement: every DEFENDER/FLEET participant materialises its own
     fleet_movement_ships as 'SHIP' units, attributed to ITS participant_id and statted with
     ITS OWN owner context (part.player_id) — the exact mirror of the Phase 4A ATTACKER branch.
   · every pre-existing statement is preserved verbatim
   · the FOUND check after the ATTACKER insert is deliberately NOT repeated: zero defending
     fleets is the certified case, so an added statement that inserts nothing is a no-op

2. resolve_attack_arrival(p_fleet_id)
   + ONE fail-closed guard, placed after the existing participant-contract check:
     if the battle owns any DEFENDER/FLEET participant -> RAISE
     'MULTI_DEFENDER_SETTLEMENT_NOT_DEFINED: ...single-fleet settlement cannot attribute their
     survivors'. Without it, a future defending-fleet producer would destroy that fleet's ships
     in combat and still return the fleet with its original composition (free ships).
   · every pre-existing statement is preserved verbatim
```

Why this is safe, and why it is not gameplay:

```text
· No producer of DEFENDER/FLEET participants exists (proved: only 3 participant-inserting
  functions, none of them creating that shape), so statement (1) inserts zero rows today and
  statement (2) can never fire. Both are inert on every live path.
· Technology attribution is not invented: it reuses the certified helper trio
  get_combat_ship_attack / get_combat_ship_shield / get_combat_ship_hull(part.player_id, ship_id)
  already used by the certified ATTACKER/FLEET branch.
· No formula, percentage, threshold, RNG semantic, round cap, rapidfire value or result rule changed.
· No product value was chosen: no fleet count, no timing window, no ordering, no priority, no
  survivor rule and no loot rule.
· The certified single-attacker and expedition paths stay behaviourally identical (tests D10/D12
  plus the full 43/43 regression below).
```

Provenance: the repository file is content-identical to the applied migration (whitespace-normalised
`md5` = `7dc703467ec25ff722cb85468d493ee1` on both sides, 16202 characters). The migration has **no**
dependency on the `LOCAL_ONLY / NOT_DEPLOYED / BLOCKED` migration `20260919180000` (see the provenance gate).

### 20.5 Explicitly NOT implemented (deliberate)

```text
· ACS grouping / invitation / join / leave / deadline — no group object created (PD-01...PD-05)
· ACS or DEFEND dispatch — start_support_fleet still refuses DEFEND; no dispatcher accepts it
· defending-fleet participation in a live battle — no producer was created on purpose
· multi-fleet / multi-defender settlement — resolve_attack_arrival still settles one fleet + planet
· per-fleet survivor, loot and debris-attribution semantics — untouched
· battle-report per-fleet projection — the public payload is byte-identical
· ACS/DEFEND UI, client types, mission-selector entries — nothing added
· deletion or "cleanup" of any legacy object (deferred; see 20.11)
· any balance, formula or alien-technology change
```

### 20.6 Concurrency and idempotency audit

| Scenario | Mechanism found (LIVE) | Verdict |
|---|---|---|
| Two fleets joining an ACS simultaneously | **no join path exists** | n/a — nothing to race |
| Two fleets arriving simultaneously | `process_fleet_movements` takes `pg_advisory_xact_lock(hashtextextended('fleet-processing-global',0))` then iterates `ORDER BY arrives_at, id` with `FOR UPDATE SKIP LOCKED`; each row is claimed by `UPDATE … WHERE id=? AND status='OUTBOUND'` + `IF NOT FOUND THEN CONTINUE` | SAFE, but produces **two battles** (the ACS gap is semantic, not concurrent) |
| Two fleets resolving against the same target | no shared lock between battles; the global advisory lock serializes them, and each battle reads `planet_ships` at its own resolution time | SAFE by serialization; sequence semantics are PD-04 |
| The same fleet joining twice | `combat_battle_participants_fleet_unique (battle_id, fleet_id)` | SAFE (test D14) |
| The same fleet arriving twice | `ux_combat_battles_one_per_fleet(fleet_id)` + `resolve_combat`'s pre-lookup + fleet `FOR UPDATE` | SAFE |
| The same battle resolving twice | `resolve_attack_arrival` early-return for non-`ARRIVED`; `run_expedition_combat` gated on `finished_at IS NULL` | SAFE (tests 12, C2/C3) |
| The same participant inserted twice | the two participant unique keys | SAFE |
| The same target unit selected twice | `combat_shots_battle_id_round_number_shot_number_key` + `combat_round_damage_unique(battle_id,round_number,source_shot_number)` + `resolve_pending_target_damage … FOR UPDATE` on the snapshot row | SAFE (test D9) |
| Settlement retried | `loot_applied_at`, the `combat_defense_repairs` existence probe, `combat_debris_generations_battle_unique` + the battle-scoped advisory lock | SAFE |
| `ON CONFLICT DO NOTHING` in combat identity paths | exactly one remains: `create_combat_round_snapshot` on the **Phase 4A participant-aware** key. Justified: it is a re-entrant snapshot builder whose key is now fully identifying, so a skipped row can only be a row already present with the same identity — the pre-4A silent cross-fleet drop is gone. `create_combat_debris` uses `ON CONFLICT (battle_id) DO NOTHING` **plus** an explicit conflict branch that raises a WARNING instead of losing data. | JUSTIFIED |

### 20.7 Security / ACL / RLS audit

```text
initialize_individual_combat_units  CREATE OR REPLACE (signature unchanged) -> ACL preserved
resolve_attack_arrival              CREATE OR REPLACE (signature unchanged) -> ACL preserved
```

Both were additionally re-declared explicitly, because Phase 4A proved that a *new* signature silently resets
EXECUTE to PUBLIC:

```text
revoke all on function ... from public, anon, authenticated;
grant execute on function ... to service_role;
```

Verified LIVE afterwards (exact string, both functions):

```text
pg_proc.proacl = {postgres=X/postgres,service_role=X/postgres}
anon EXECUTE = false · authenticated EXECUTE = false · service_role EXECUTE = true
exactly ONE definition per function name (no orphan overload left behind)
```

No other ACL or RLS object was touched: the client surface was neither widened nor narrowed. RLS is unchanged
(`deny_direct_api_access` on `combat_battles`, `combat_battle_participants`, `combat_individual_units`,
`combat_round_snapshot_units`, `debris_fields`, `planet_support_authorizations`), and the support RPCs remain
`anon=false`.

Ownership model for a future ACS/DEFEND surface (the established chain, reused unchanged):

```text
auth.uid() -> players.user_id -> players.id  ->  owned planet / owned fleet
```

No `is_guest`, no username, no frontend identity and no client-supplied ownership is used anywhere in the
support or combat path.

### 20.8 UI / frontend audit (STATIC VERIFIED)

```text
src/**.ts|tsx references to ACS_HOLD · HOLDING · DEFEND(mission) · start_support_fleet ·
planet_support · holding_until · idempotency_key ......................... 0   (NOT STARTED)
generated database types: mission_type is a plain string, no support contract, no HOLDING state NOT STARTED
FleetView / GalaxyView / Overview / Messages / combat report: no ACS, DEFEND, holding-status or
   participant-list surface; the mission selector exposes only the seven implemented missions NOT STARTED
BACKEND DEPENDENCY for any of the above: ACS grouping/dispatch semantics (PD-01...PD-07) NOT DEFINED
```

No placeholder UI was created, because the ACS/DEFEND backend contract is not determined yet.

### 20.9 Battle-report contract (LIVE VERIFIED, payload UNCHANGED)

`get_player_battle_reports(p_limit)` already scales to N participants **without modification**:

```text
visibility          EXISTS (participant.player_id = me)   -> an ACS participant would see the battle
participants        jsonb array {side,participant_type,player_id,fleet_id,planet_id}
caller_role         ATTACKER if the caller owns any attacker participant, else DEFENDER
defender_player_id  read from the DEFENDER/PLANET participant
```

Still missing for a per-fleet battle screen: `losses` and `rounds` carry no `participant_id` (DG-13 at payload
level). A future optional projection is proposed in PD-15. The current payload was left byte-identical and the
report regression is 7/7.

### 20.10 Expedition compatibility (LIVE VERIFIED, 11/11)

The expedition branch is untouched: `resolve_expedition_pirates`/`_aliens` create `ATTACKER/FLEET` +
`DEFENDER/ENEMY`, `run_expedition_combat` derives the result from side aggregates, and the worker's
`EXPEDITION` branch is byte-identical. `DEFENDER/ENEMY` is **not** reinterpreted as `DEFENDER/FLEET`
(`initialize_individual_combat_units` matches `participant_type='FLEET'` explicitly, and the fail-closed guard
in `resolve_attack_arrival` is unreachable for expeditions because that function rejects non-`ATTACK` missions).
No expedition balance, alien-tech or ACS semantics were introduced.

**Documentation correction (not a regression).** §17.3/§19.8 recorded `combat_expedition_combat.sql` as
**10/10**. The fixture has emitted **11** assertions (P1–P7 + A1–A4) since commit `d64c338` and emits 11 PASS
today. The five certified suites therefore contain **43** assertions, not 42; the "42/42" figure was an
undercount.

### 20.11 Legacy / dead infrastructure inventory (fresh, LIVE VERIFIED)

```text
LIVE            resolve_combat · initialize_individual_combat_units · process_combat_round_v2 ·
                resolve_pending_target_damage · generate_combat_round_v2 · expand_all_rapidfire_v2 ·
                calculate_combat_round_pending_damage · apply_combat_round_damage · finish_combat_round_v1 ·
                create_combat_next_round · create_combat_round_snapshot · run_expedition_combat ·
                resolve_attack_arrival · apply_attack_loot · repair_defenses_after_combat ·
                create_combat_debris · sync_combat_battle_final_counts · both loss readers ·
                calculate_combat_ship_debris · calculate_combat_defense_debris ·
                calculate_combat_total_debris
READY (0 database callers, client-callable, no gameplay produces their input)
                start_support_fleet · grant_planet_support_authorization ·
                revoke_planet_support_authorization
DEAD (1 definition, 0 referencing functions, not client-callable)
                combat_hull_from_integrity · get_combat_unit_snapshot · initialize_combat_unit_state
DEAD TABLE      combat_unit_state (0 rows, no writer)
DANGEROUS       none found by this audit
UNKNOWN         none — every combat object was resolved to a caller set
```

No dead object was deleted (deletion was not required by the new implementation). `combat_unit_state`, the
three orphan functions and the inert legacy residue stay deferred and documented.

### 20.12 Tests and LIVE evidence

New rollback-safe fixture: `supabase/tests/combat_defender_fleet_participant.sql` — **16/16 PASS**.

| # | Assertion | Result |
|---|---|---|
| D1 | the battle owns 1 attacker + 1 planet + 2 defending fleets (4 participants) | PASS |
| D2 | units per participant: planet 14, D1 3, D2 4, none without `participant_id` | PASS |
| D3 | three distinct `cruiser #1` rows survive across three defender participants | PASS |
| D4 | each defending fleet keeps its OWN owner context (D1 hull 351 vs D2 hull 270) | PASS |
| D5 | defending-fleet units are never `DEFENCE` | PASS |
| D6 | the repair loss reader cannot see fleet ships (0 rows) | PASS |
| D7 | ship losses stay per-participant (5 rows / 4 participants) | PASS |
| D8 | the round-1 snapshot keeps all 26 units, none without participant | PASS |
| D9a | defending fleet A resolves **its own** `cruiser #1` (1 shot) | PASS |
| D9b | defending fleet B resolves **its own** `cruiser #1` (1 shot) | PASS |
| D9c | a participant that owns no such unit is rejected, never guessed | PASS |
| D10 | with ZERO defending fleets the certified unit set is unchanged (19 units) | PASS |
| D11 | settlement refuses a battle owning defending fleets (`MULTI_DEFENDER_SETTLEMENT_NOT_DEFINED`) | PASS |
| D12 | the certified single-fleet attack still settles (`RETURNING`) | PASS |
| D13 | one battle-level debris generation merging 2 participants | PASS |
| D14 | a fleet cannot join the same battle twice | PASS |

Certified regressions re-run on LIVE after the migration **and** after the new fixture:

| Suite | Result |
|---|---|
| `combat_participant_propagation.sql` (attack) | **12/12 PASS** |
| `combat_expedition_combat.sql` | **11/11 PASS** (see the §20.10 correction) |
| `combat_report_contract.sql` | **7/7 PASS** |
| `combat_worker_isolation.sql` | **8/8 PASS** |
| `combat_debris_idempotency.sql` | **5/5 PASS** |
| **certified total** | **43/43 PASS** |
| `combat_participant_identity_collision.sql` (Phase 4A) | **13/13 PASS** |
| `combat_defender_fleet_participant.sql` (Phase 4B, new) | **16/16 PASS** |

Static gates: `npx tsc -b` exit 0 · `npm run build` exit 0 (the reported exit 1 was a PowerShell stderr
artefact around the chunk-size warning; the real process exit was 0) · `git diff --check` clean · no conflict
markers in either new file.

LIVE residue proof (identical before and after every fixture run, and at mission end):

```text
battles 0 · participants 0 · individual units 0 · rounds 0 · shots 0 · debris generations 0 ·
defence repairs 0 · fleets 0 · fleet ships 0 · support rows 0 · support authorizations 0 ·
support/HOLDING rows 0 · planet_defenses 0 · players 407 · players with a user_id 1 ·
debris_fields 3 with an unchanged metal total 142240.29428409734012460000 · planet_ships quantity 1 ·
pre-existing orphans unchanged: snapshot_units 661, damage rows 681
```

Residue: **NONE.** No test player, planet, fleet, battle, unit, shot, debris field, repair or authorization
survives; the identity re-point used by the fixture (the `fleet_movements` ownership guard needs the inserted
player to own the JWT) is restored inside the rolled-back block — `players.user_id` is back to exactly one
holder.

### 20.13 PRODUCT DECISION REGISTER (all still OPEN — nothing was chosen)

Every item below is a genuine gameplay/product decision that the current architecture does **not** determine.
None of them was silently resolved; no value was invented anywhere in this phase.

| ID | Decision required | Why it cannot be inferred | Status |
|---|---|---|---|
| PG-01 | ACS group ownership (who creates/owns/cancels a group) | no group object exists; only a per-planet per-player consent table exists | OPEN |
| PG-02 | ACS join deadline (how long a fleet may join before launch) | no timing field, no dispatch window anywhere | OPEN |
| PG-03 | ACS member withdrawal before arrival | no recall/cancel path exists for any mission | OPEN |
| PG-04 | Late arrival (join the running battle vs a new battle) | today it *is* a new battle; whether that is intended is a rule | OPEN |
| PG-05 | Maximum ACS fleet count | no constant exists, nothing enforces a cap | OPEN |
| PG-06 | Attacker fleet ordering | **downgraded to NOT REQUIRED**: shot generation is `ORDER BY random()` and unit identity is order-independent, so ordering has no semantic effect (UI ordering is a presentation choice) | NOT REQUIRED |
| PG-07 | Defender fleet ordering | same evidence as PG-06 | NOT REQUIRED |
| PG-08 | **Survivor attribution** — does each fleet keep its own surviving ships, or does combat produce one pooled attacker survivor result? | `resolve_attack_arrival` writes survivors back to exactly one `fleet_id`; no pool concept exists and no per-participant settlement loop exists | **OPEN — BLOCKING** |
| PG-09 | Loot capacity attribution (initiating fleet / sum of survivors / pooled capacity) | `apply_attack_loot` reads `combat_battles.fleet_id` only | **OPEN — BLOCKING** |
| PG-10 | Loot ownership (one recipient vs distributed) | same as PG-09; the cargo is credited to one movement row today | OPEN |
| PG-11 | Retreat / cancellation semantics | no recall path exists at all | OPEN |
| PG-12 | DEFEND authorization semantics (reuse `planet_support_authorizations`, or a different consent) | the consent *mechanism* exists; whether DEFEND uses it is a rule | OPEN |
| PG-13 | DEFEND withdrawal | no endpoint exists (the revoke RPC revokes consent, it does not recall a fleet) | OPEN |
| PG-14 | DEFEND arrival timing (does a defending fleet have to arrive *before* an attack to count?) | no arrival-vs-attack rule exists | OPEN |
| PG-15 | Battle-report per-fleet projection (add `participant_id` to `losses`/`rounds`) | the internal model supports it; the customer-facing shape is a product choice | OPEN |
| PG-16 | Settlement atomicity for N fleets of one battle (one transaction vs per-fleet) | settlement is one transaction per fleet today (the worker's per-fleet isolation model) | OPEN |
| PG-17 | Defending-fleet lifecycle after combat (stay `HOLDING` until `holding_until`, or return immediately) | no rule exists; the fleet's `holding_until` is the only timing authority | **OPEN — BLOCKING** |
| PG-18 | Whether `combat_battles.defender_ships_before/after` / `defender_combat_units_*` should include defending-fleet ships | `sync_combat_battle_final_counts` and `run_expedition_combat` aggregate by **side**, which would silently fold defending fleets into the planet's counters | OPEN |

Blocking set for any defending-fleet gameplay: **PG-08, PG-09, PG-17, PG-18** (plus PG-01…PG-05 for ACS
dispatch). Until they are decided, `resolve_attack_arrival` refuses to settle a battle that owns
`DEFENDER/FLEET` participants, and no producer for such participants exists.

Decisions **already determined elsewhere** and therefore not re-opened here:

```text
· maximum holding duration and holding fuel — OPEN in the Fleet Engine (README_FLEET_ENGINE §22.7), not a combat decision
· battle winner semantics — side-aggregate, `aa>0 AND dd=0 -> ATTACKER_WIN` (certified, unchanged)
· defence repair = planet-scoped at 70 % — certified, unchanged
· debris = battle-scoped at `universes.fleet_debris_percentage` — certified, unchanged
· loot plunder caps = 50 % per resource with the existing capacity order — certified, unchanged
```

### 20.14 Next engineering boundary

```text
The identity layer can now REPRESENT a defending fleet; it still cannot SETTLE one, and nothing can create one.

NEXT MISSION (gameplay — requires the blocking product decisions first)
  1. resolve PG-08 / PG-09 / PG-17 / PG-18
  2. then: per-participant settlement in resolve_attack_arrival (write back N fleets, transition N statuses),
     loot attribution, and the defending-fleet return rule
  3. then: a producer (ACS_HOLD participation and/or DEFEND dispatch) plus its authorization rules

SEPARATE, NON-BLOCKING
  4. ACS group object — only if PG-01…PG-05 choose a grouping model; none is structurally required today
  5. per-fleet report projection (PG-15), battle-report screen
  6. legacy/DEAD combat-object disposition (combat_unit_state + 3 orphan functions)
  7. the alien-technology balance item and DG-07 leftover cleanup (unchanged from §17.5)

The certified base engine (single attacking fleet vs one planet + the expedition branch) stays CERTIFIED and
was not modified in behaviour by this phase.
```

## 21. COMBAT PRODUCT GATES — TECHNICAL ANALYSIS (read-only, 2026-09-22)

> **Analysis only. Nothing in this section is implemented.** These four gates require a product decision; the
> purpose here is to make the next mission specific instead of exploratory. Evidence level: **LIVE VERIFIED**
> (deployed definitions re-read on 2026-09-22; the Phase 4B invariants were re-checked and are unchanged).
>
> What changed since §20: the ACS_HOLD **transport** is now reachable end-to-end. The support authorization
> blocker was repaired by `20260922052432_fix_support_authorization_conflict`, `fleet_acs_hold_lifecycle.sql`
> passes **50/50** and a new authorization-chain fixture passes **13/13**. That changes nothing about these
> four gates: a support fleet can now be *dispatched and held*, but it still cannot *participate in combat*,
> because no producer creates a `DEFENDER/FLEET` participant (verified: 0 producers) and settlement refuses
> such a battle on purpose.

### 21.1 PG-08 — survivor attribution

```text
CURRENT LGI BEHAVIOUR
  · combat keeps per-participant survivor state: combat_individual_units.alive is per
    (battle, round, participant_id, unit...) and create_combat_next_round copies it forward.
  · settlement is SINGLE-FLEET: resolve_attack_arrival resolves ONE attacker participant
    (side='ATTACKER' AND fleet_id = p_fleet_id), deletes that fleet's fleet_movement_ships and
    re-inserts the surviving composition of THAT participant, then moves THAT fleet to RETURNING.
  · there is no pooled-attacker concept anywhere in the schema or the engine.

WHAT MULTI-FLEET BREAKS
  · an ACS battle owns N ATTACKER/FLEET participants, but only one of them (the initiating fleet,
    combat_battles.fleet_id) has a settlement path. The other N-1 fleets would never be rewritten
    and never transition out of their movement state.
  · the per-participant survivor data already exists, so nothing needs to be *computed*; what is
    missing is the *write-back loop* and the per-fleet status transition.

AVAILABLE DESIGN OPTIONS
  A. per-fleet survivors: each ATTACKER/FLEET participant's surviving units are written back to ITS
     OWN fleet_movement_ships, and each fleet returns on its own duration.
  B. pooled attacker survivors: the battle produces ONE attacker pool carried by a single movement.
  C. hybrid: per-fleet survivors, pooled capacity (see 21.2).

CONSEQUENCES
  A. matches the engine's existing shape (participant-aware alive state), keeps every fleet
     independently attributable, needs no new table and no new identity; cost = a loop over
     participants replacing two single-participant statements.
  B. contradicts the participant-aware foundation built in Phase 4A/4B, destroys per-fleet
     attribution (the exact property those phases established), and requires inventing a carrier
     for a pool that no LGI concept describes.
  C. adds a second attribution model on top of an already-complete one.

RECOMMENDED LGI-COMPATIBLE OPTION (not implemented)
  A — per-fleet survivors. It is the only option that preserves the certified participant identity,
  requires no new identity object, and matches the existing per-participant alive state. It is NOT
  sufficient on its own: PG-17 defines what a defending fleet does, PG-09/10 define loot.

WHAT CODE WOULD CHANGE (if A is chosen)
  resolve_attack_arrival: replace the single-participant survivor write-back and the single status
  transition with a loop over every participant of the battle that owns a fleet:
      for each participant in combat_battle_participants where fleet_id is not null:
          rewrite that fleet's fleet_movement_ships from ITS OWN participant's surviving units
          move that fleet out of its current state with its own persisted timing
  plus the Phase 4B fail-closed guard relaxed only for the participants the loop actually handles.
  Nothing in the round engine, snapshots, shots, damage, rapidfire, debris or repair changes.

WHAT TESTS WOULD PROVE IT
  · a two-attacker battle where A loses everything and B survives: A's fleet_movement_ships and
    status reflect A's own participant only, and likewise B (no cross-participant leakage);
  · the existing 12/12 single-attacker regression must stay green unchanged;
  · replay: a second settlement pass must not double-apply.
```

### 21.2 PG-09 / PG-10 — loot capacity source and loot recipient

```text
CURRENT LGI BEHAVIOUR
  apply_attack_loot(p_battle_id):
    · locks the battle row and returns early when loot_applied_at is set (idempotent);
    · when the attacker did NOT win it records loot_applied_at with 0/0/0 and returns;
    · capacity = SUM(fleet_movement_ships.quantity * ship_definitions.cargo_capacity) for
      combat_battles.fleet_id ONLY;
    · plunder = 50 % per resource, taken in the order metal -> crystal -> deuterium with the
      surplus cascading;
    · the cargo is credited to that ONE fleet_movements row (its metal/crystal/deuterium columns).

WHAT MULTI-FLEET BREAKS
  · capacity ignores every fleet except the initiating one — arbitrarily discriminating against
    whoever happened to arrive first;
  · there is exactly one credit target, so even a correct total has nowhere to go when N fleets
    participate.

AVAILABLE DESIGN OPTIONS (capacity and recipient are TWO separate decisions)
  capacity:  (1) initiating fleet only (current); (2) sum over ALL ATTACKER participants;
             (3) sum over SURVIVING attacker ships only; (4) a configured ACS capacity.
  recipient: (a) the initiating fleet carries everything; (b) each fleet loads up to its own
             remaining capacity under an allocation rule; (c) a player-level pool.

CONSEQUENCES
  (1) is not defensible once N fleets exist: it is an accident of arrival order.
  (2) is the most faithful to "the ACS brought this carrying capacity".
  (3) is arguably fairer (destroyed ships cannot carry) and follows from PG-08.
  (4) requires a new configurable product surface LGI does not have.
  (a) is simplest but lets one participant keep resources carried by another participant's ships —
      in ACS the participants can be DIFFERENT players.
  (b) is the only fair-across-players option, but it needs a deterministic allocation rule
      (proportional to capacity? arrival order? owner?).
  (c) introduces a player-level resource concept that does not exist in LGI.

RECOMMENDED LGI-COMPATIBLE OPTION (not implemented)
  capacity (3) — capacity from the SURVIVING attacker participants, because it follows directly
  from the survivor model chosen in PG-08 and needs no new concept;
  recipient (b) — per-fleet, once the allocation rule is decided. If the product wants the simplest
  behaviour first, (a) with an explicitly written rule is acceptable. (c) is rejected: LGI has no
  player-level resource pool.

WHAT CODE WOULD CHANGE (if (3) + (b))
  apply_attack_loot: the capacity query becomes a join over ALL ATTACKER participants' surviving
  vehicles; the credit statement becomes a per-fleet allocation loop. The 50 % caps, the
  metal -> crystal -> deuterium order, the cascade and the loot_applied_at idempotency must stay
  byte-identical.

WHAT TESTS WOULD PROVE IT
  · two attackers with different cargo ships: total capacity equals the sum of survivors and each
    fleet's credited cargo matches the allocation rule;
  · the 50 % caps and the resource order are unchanged versus the single-fleet case;
  · replay: loot_applied_at prevents a second application.
```

### 21.3 PG-17 — defending-fleet lifecycle after combat

```text
CURRENT LGI BEHAVIOUR
  · a HOLDING fleet returns when its own persisted holding_until is due: process_fleet_movements sets
    status='RETURNING', returns_at = holding_until + (arrives_at - started_at).
  · resolve_attack_arrival never touches a defending fleet (none exists) and deliberately REFUSES a
    battle that owns a DEFENDER/FLEET participant (MULTI_DEFENDER_SETTLEMENT_NOT_DEFINED).
  · repair is planet-scoped: a defending FLEET's ships are SHIP units and can never enter
    calculate_combat_defense_losses.

WHAT MULTI-FLEET BREAKS
  · once defending fleets participate, someone must decide what happens to a SURVIVING defending fleet
    and to a DESTROYED one: stay until holding_until and then return, or leave immediately after
    combat? Does a wrecked fleet's movement still complete (empty) or get cancelled?

AVAILABLE DESIGN OPTIONS
  A. keep the hold contract: survivors stay HOLDING until holding_until, then return normally; a
     wrecked fleet (no surviving ships) travels the same path with an empty composition.
  B. combat ends the hold: every defending fleet becomes RETURNING at settlement time.
  C. an explicit per-movement flag set by the dispatcher ("stay after combat").

CONSEQUENCES
  A. preserves the currently certified HOLDING contract exactly, needs no new column, and keeps
     holding_until as the single timing authority; the defence keeps working after the battle.
  B. contradicts the existing hold semantics (a fleet would leave before the window its owner chose)
     and needs an extra rule for holding_until.
  C. adds a new per-movement product surface.

RECOMMENDED LGI-COMPATIBLE OPTION (not implemented)
  A — the hold contract keeps governing, which makes the support authorization explicitly mean "you
  may stay at my planet for this window". A wrecked fleet returns on the same path with zero surviving
  ships; whether an empty COMPLETED movement is acceptable output must be confirmed by the product.

WHAT CODE WOULD PROVE IT
  · DEFENDER/FLEET settlement write-back (PG-08 model) while leaving status and holding_until untouched
    for survivors;
  · the Phase 4B fail-closed guard replaced by the loop and kept for anything unhandled.
```

### 21.4 PG-18 — battle-header defender counters

```text
CURRENT LGI BEHAVIOUR
  · sync_combat_battle_final_counts and run_expedition_combat compute, per battle:
      attacker_ships_after      = count(alive) where side='ATTACKER' and unit_type='SHIP'
      defender_ships_after      = count(alive) where side='DEFENDER' and unit_type='SHIP'
      defender_defenses_after   = count(alive) where side='DEFENDER' and unit_type='DEFENSE'
      defender_combat_units_after = count(alive) where side='DEFENDER'
    i.e. everything is aggregated BY SIDE.
  · combat_rounds does the same at round level and get_player_battle_reports exposes the counters.

WHAT MULTI-FLEET BREAKS
  · a defending fleet's ships are side='DEFENDER' + unit_type='SHIP', so they would silently be added
    to the PLANET's defender_ship counters. The header/report would claim the planet had more ships
    than it ever had, with no way to tell the two apart.

AVAILABLE DESIGN OPTIONS
  A. redefine the header counters as side-level totals that include defending fleets (a semantic
     change to existing columns and to the report payload).
  B. keep the planet-only meaning and exclude DEFENDER/FLEET participants from those counters (the
     participants payload already distinguishes them).
  C. add NEW battle-level columns for the fleet-defender totals, leaving the existing ones intact.

CONSEQUENCES
  A. changes the meaning of values already stored and already exposed by get_player_battle_reports, so
     historical battles and current readers would be reinterpreted.
  B. preserves the existing meaning and the public payload byte-for-byte; per-participant truth stays
     available.
  C. is the most explicit but adds schema and duplicates what the participant layer already holds.

RECOMMENDED LGI-COMPATIBLE OPTION (not implemented)
  B — the only option that keeps the certified report contract stable (the Phase 2/3/4A/4B invariant) and
  it follows from the participant-aware model: per-participant truth is authoritative, side-level
  headers stay planet-scoped aggregates.

WHAT CODE WOULD CHANGE
  sync_combat_battle_final_counts and the equivalent block inside run_expedition_combat: add a
  participant filter (participant_type='PLANET') to the two defender counters. No column change, no
  report change.

WHAT TESTS WOULD PROVE IT
  · a battle with a planet holding 10 ships AND a defending fleet holding 5: defender_ships_* stays 10
    while the participants payload shows both; the single-fleet and expedition cases stay unchanged.
```

### 21.5 OGameX contrast (§14 method applied)

OGameX was consulted as a **reference only**, and the project's own translation layer
(`docs/reference/OGAMEX_LGI_MAP.md` §C "Combat boundary" and §6 "What OGameX should NOT dictate") was used
as the authoritative statement of how it may be used. External evidence checked on 2026-09-22: OGameX is a
Laravel application whose combat is split into a PHP service layer plus a **separate Rust battle engine**
(a third-party combat simulator built on it advertises "the OGameX Rust battle engine"). Its README does not
document ACS/defend semantics.

| OGameX pattern | LGI current architecture | Difference | Why the difference exists | LGI decision |
|---|---|---|---|---|
| Battle computed in a PHP service + Rust engine, outside the DB transaction | Single plpgsql engine **inside** the worker transaction (`resolve_combat` → rounds → settlement) | different execution and persistence boundary | LGI made PostgreSQL the authoritative engine (PROJECT_CONTEXT §2); transactions and RLS are the integrity boundary | **DISCARD** the split. Do not introduce a second resolver or an out-of-transaction battle service |
| ACS as a grouping of fleets that share one battle | Battle-owned participants (`combat_battle_participants`); **no group object** | LGI models membership per battle, not as a pre-battle group | Phase 4A/4B deliberately built participant identity as the authority and found no structure requiring a group | **KEEP AS REFERENCE.** A group object is only introduced if PG-01…PG-05 choose one |
| Loot distributed across participating fleets | Loot capacity + credit are single-fleet today | LGI has no allocation rule | the allocation rule is a product decision, not an architectural omission | **ADAPT ONLY AFTER PG-09/PG-10 are decided.** No OGameX value is imported |
| Defender fleets participate in combat | `DEFENDER/FLEET` is representable; **0 producers**; settlement fails closed | LGI has no producer and no return rule | deliberately not implemented until PG-17/PG-08 exist | **DISCARD the timing.** Participation stays closed |
| Collection/Eloquent models own state | Tables + functions; frontend is presentation only | different ownership model | LGI forbids ORM-driven authority | **DISCARD** |

**Contradictions with CLOSED LGI decisions: NONE.** Nothing from OGameX was imported, adapted or copied, and
no OGameX value entered any formula. The comparison confirmed the gaps already registered as PG-08…PG-18 and
added no new LGI requirement.

### 21.6 Decision summary — what the next mission must settle first

| Gate | Decision required | Recommended (not implemented) | Blocking? |
|---|---|---|---|
| PG-08 | survivorship model: per-fleet vs pooled | per-fleet (matches participant identity) | **YES** |
| PG-09 | loot capacity source | surviving ATTACKER participants | **YES** |
| PG-10 | loot recipient / allocation rule | per-fleet with an explicit allocation rule | **YES** |
| PG-17 | defending-fleet lifecycle after combat | keep the `holding_until` contract | **YES** |
| PG-18 | battle-header defender counters | keep them planet-scoped (exclude fleet defenders) | no (can follow) |

Nothing above is implemented. The engine today represents a defending fleet, refuses to settle a battle it
cannot attribute, and produces no participant it cannot settle — which is exactly the fail-closed boundary
this analysis is meant to hand over.

## 22. PRODUCT DECISION PACKAGE — PG-08 / PG-09 / PG-10 / PG-17 / PG-18 (2026-09-22)

> **Read-only. No settlement, no migration, no producer, no UI.** §21 holds the option analysis; this section
> records the **decision status per gate**, the **settlement contract**, the **exact implementation boundary**
> and the **future test plan**. Where the available evidence (certified invariants, LIVE code, tests, OGameX
> contrast) does not settle a question, the gate is reported as an explicit human decision instead of being
> guessed.
>
> Evidence re-read LIVE on 2026-09-22; Combat Phase 3/4/4A/4B were **not** modified.

### 22.1 Decision status

| Gate | Question | Status |
|---|---|---|
| **PG-08** | survivor attribution | `DECIDED — READY FOR IMPLEMENTATION` (per-participant) |
| **PG-09** | loot-capacity source | `UNRESOLVED PRODUCT DECISION` |
| **PG-10** | loot recipient / allocation | `UNRESOLVED PRODUCT DECISION` |
| **PG-17** | defending-fleet lifecycle | `DECIDED — READY FOR IMPLEMENTATION` (hold contract preserved) |
| **PG-18** | battle-header defender counters | `DECIDED — READY FOR IMPLEMENTATION` (planet-scoped) |

### 22.2 Why PG-08 is decided and not a free choice

PG-08 is **not** an open product question, because the only alternative (a pooled attacker result) requires
moving ships **between players**:

```text
· combat_individual_units.alive is already per participant   (Phase 4A/4B, certified)
· the ONLY durable key tying a participant to a real fleet is
  combat_battle_participants.fleet_id                       (already documented: §6, §18)
· fleet_movement_ships has UNIQUE(fleet_id, ship_id) and CHECK(quantity > 0), so a fleet's
  composition IS its survivor set, and it is an owned asset of exactly one player
· pooling survivors onto one fleet would have to zero/delete the other participants' fleets,
  i.e. transfer another player's ships to a different player. Nothing in LGI authorises that:
  the ownership chain is auth.uid() -> players.user_id -> players.id -> owned entity
```

The sub-case "what does a fully destroyed participant become" is inherited from the **certified**
single-fleet path: `resolve_attack_arrival` writes back the survivor set unconditionally (delete + insert),
so a total loss already yields a movement with **no** `fleet_movement_ships` rows that still transitions to
`RETURNING`. `CHECK(quantity > 0)` makes absence-of-rows the only representable form of "zero survivors".

### 22.3 Why PG-17 and PG-18 are decided

```text
PG-17 (defending-fleet lifecycle)
  · holding_until is an ABSOLUTE UTC window and the single timing authority for a support fleet
    (active decision, PROJECT_CONTEXT §5; worker: HOLDING -> RETURNING when due).
  · combat therefore must NOT become a second authority over that window. Settlement writes the
    participant's survivors back to ITS OWN fleet_movement_ships and leaves status and
    holding_until untouched; the surviving fleet keeps defending until its window ends.
  · a fully destroyed defending fleet returns empty on the same certified path.
  · nothing here defines a PRODUCER (who may hold, for how long): that stays a separate future
    contract and is explicitly out of scope.

PG-18 (battle-header defender counters)
  · defender_ships_before = planet_ships only (computed in resolve_combat)
  · defender_ships_after  = count(alive) where side='DEFENDER' AND unit_type='SHIP'
                            (sync_combat_battle_final_counts)
  · with a DEFENDER/FLEET participant these two stop describing the same population, so the
    header becomes SELF-INCONSISTENT (before excludes fleets, after includes them).
  · the counters are part of the certified report contract (get_player_battle_reports exposes
    defender_ships_before/after and defender_defenses_before).
  => the only option preserving BOTH before/after coherence AND the certified report meaning is to
     keep them scoped to the DEFENDER/PLANET participant. Per-participant truth for defending
     fleets stays available in the participants payload.
  · a COMBINED defending-force counter would be a deliberate report-contract revision (additive or
     semantic) and is therefore not part of this decision.
```

### 22.4 Settlement contract (conceptual — no schema, no code)

```text
TRIGGER / IDEMPOTENCY   [architectural finding of this mission]
  Today one ATTACK fleet owns one battle (combat_battles.fleet_id) and resolve_attack_arrival(p_fleet_id)
  is BOTH the trigger and the replay anchor. With N participating fleets that anchor is insufficient:
  resolve_combat looks a battle up by fleet_id, so a second fleet's arrival would not find this battle and
  would create a SECOND one.
  => settlement idempotency must become BATTLE-LEVEL (independent of which fleet triggers it), while
     combat_battles.fleet_id remains the documented "initiating fleet / replay key" (DG-10) for the
     existing single-fleet path. Idempotency must not depend on a fleet being the initiator.

PER-PARTICIPANT SETTLEMENT (one pass, one transaction, inside the worker)
  for each participant of the battle:
    FLEET participant (ATTACKER or DEFENDER)
      · survivors -> rewrite ITS OWN fleet_movement_ships from its OWN participant's alive units
                     (delete + insert; zero survivors = no rows, because CHECK quantity > 0)
      · losses    -> already derivable per participant (calculate_combat_ship_losses)
      · lifecycle -> ATTACK fleet:      ARRIVED -> RETURNING with its own persisted duration
                     defending fleet:  status and holding_until UNTOUCHED (PG-17)
    PLANET participant
      · planet_ships / planet_defenses rewritten from its OWN participant's alive units (as today)
      · defence repair stays planet-scoped and unchanged
  battle level (once, unchanged)
      · result flags, final counts (PG-18 scoped), ONE debris generation

ORDERING CONSTRAINTS (measured in LIVE; must be preserved)
  1. run_expedition_combat (rounds + result) runs BEFORE the survivor write-back          [as today]
  2. the survivor write-back runs BEFORE loot capacity, because capacity is read from
     fleet_movement_ships                                                                [as today]
  3. the loot credit is guarded by `fleet_movements.status='ARRIVED'`, so in a multi-fleet loop
     each fleet's credit must happen BEFORE that fleet is transitioned out of ARRIVED    [NEW]
  4. loot_applied_at is per BATTLE and is stamped even on the zero-capacity early return, so a
     multi-fleet capacity computation must not stamp the battle before every participant has
     been considered                                                                     [NEW]
  5. sync_combat_battle_final_counts reads combat_individual_units (not fleet_movement_ships),
     so it is independent of the write-back order                                        [as today]

FAIL-CLOSED BOUNDARY
  The Phase 4B guard must NOT simply disappear. It must be narrowed to exactly the shapes the
  loop handles and must keep raising for anything else (e.g. a FLEET participant whose fleet row
  is missing, or a participant shape the settlement does not cover). Silent settlement of an
  unhandled participant is the one outcome that must remain impossible.

AUTHORISATION / SECURITY (unchanged)
  settlement runs inside the worker (service_role); it is never client-callable. The ownership chain
  auth.uid() -> players.user_id -> players.id continues to govern every dispatch, and no new client
  surface is introduced by settlement.
```

### 22.5 What is already unambiguous

```text
· the participant is the settlement unit; combat_battle_participants.id is its durable key
· survivors are per participant and are written back to that participant's OWN fleet
· a participant with zero survivors yields an empty fleet (absence of fleet_movement_ships rows)
· the defending fleet's hold is not modified by combat
· the battle header defender counters stay planet-scoped
· debris stays ONE generation per battle; repair stays planet-scoped; loot caps stay 50 %
· settlement remains inside the worker transaction; participants stay unordered (no ordering rule)
```

### 22.6 HUMAN DECISION REQUIRED — PG-09

```text
HUMAN DECISION REQUIRED

PG-09 — LOOT-CAPACITY SOURCE

Question:
  When several ATTACKER participants exist, from which composition is the cargo capacity that
  constrains the loot taken from the planet?

Why technical evidence is insufficient:
  Both candidate sources are ALREADY persisted, so neither is excluded by the architecture:
    · surviving composition  = fleet_movement_ships after the per-participant write-back
                               (what the certified single-fleet path reads today)
    · original composition   = combat_individual_units at round_number = 1, which is
                               participant-aware and therefore covers every participant
                               (no new schema and no new snapshot is required for either)
  There is no certified invariant that privileges one over the other: §6 only fixes WHICH FLEET the
  loot attaches to, never how much a destroyed ship may carry. This is a balance/gameplay rule.

Available options:
  (1) initiating fleet only                          [current behaviour, an artifact of the replay key]
  (2) all ATTACKER participants, ORIGINAL capacity   [a destroyed ship still carries]
  (3) all ATTACKER participants, SURVIVING capacity  [only living ships carry]
  (4) a configured ACS capacity                      [new product surface; LGI has none]

LGI consequences of each option:
  (1) privileging whichever fleet happened to be the initiator is not a rule, it is an accident of
      combat_battles.fleet_id; it would also make every other participant's cargo ships irrelevant.
  (2) consistent with the pre-combat battle-header counters (attacker_ships_before), reads round 1
      units instead of fleet composition, i.e. a SECOND authority for the same concept inside
      loot.
  (3) keeps the single authority for "what a fleet currently consists of" (fleet_movement_ships),
      extends the certified read to every ATTACKER participant, and needs no new data source.
  (4) introduces configuration that does not exist and cannot be inferred.

Recommended implementation boundary after decision:
  if (3): apply_attack_loot's capacity query becomes the same aggregate over every ATTACKER
          participant's fleet_movement_ships; the 50 % caps, the metal -> crystal -> deuterium
          order, the cascade and loot_applied_at stay byte-identical.
  if (2): the same aggregate but sourced from combat_individual_units round 1 per participant;
          this introduces a second capacity authority and should be an explicit product statement.
  if (1): no change to the capacity query is needed at all — only PG-10 and the idempotency fix.
  (4) is rejected unless a configuration surface is deliberately specified.
```

### 22.7 HUMAN DECISION REQUIRED — PG-10

```text
HUMAN DECISION REQUIRED

PG-10 — LOOT RECIPIENT / ALLOCATION

Question:
  (A) entitlement — which participants have a right to the loot?
  (B) allocation — by which deterministic rule is the plundered cargo physically distributed,
      including rounding and remainder?

These are two questions and must be answered separately.

Why technical evidence is insufficient:
  LGI has NO player-level resource pool: resources live on planets, and loot is physically carried
  in a fleet's cargo and credited to that fleet's ORIGIN planet by the certified return leg
  (planet_resources of fleet_movements.origin_planet_id). So "who receives the loot" is really
  "which fleets carry it home". That is a gameplay rule, not a derivable fact.

Available options:
  entitlement   (i) the initiating fleet only
                (ii) every ATTACKER participant that survived with at least one ship
                (iii) every ATTACKER participant regardless of survival
  allocation    (a) the initiating fleet carries everything
                (b) proportional to each participant's (surviving) cargo capacity
                (c) equal shares per participant
                (d) by owner, aggregated per player
  remainder     must be defined for (b) and (c): proportional floor + deterministic distribution,
                or a fixed priority order.

LGI consequences of each option:
  (a) preserves the CURRENT certified credit statement unchanged (lowest regression risk) and is
      expressible today, but in ACS the participants can be different players, so one player would
      keep cargo that other players' ships helped carry.
  (b) is the only allocation that is fair across players and scales with what each fleet actually
      contributed; it needs a remainder rule and a per-fleet credit loop.
  (c) is simpler than (b) but ignores fleet size.
  (d) requires aggregating across fleets of one player, which LGI cannot express as a single cargo
      holder (there is no player pool), so it would need a per-fleet split anyway.
  (iii) would let a wrecked fleet (zero rows, thus zero capacity) be entitled to loot it cannot carry.

Recommended implementation boundary after decision:
  the credit statement becomes a per-participant loop over the entitled fleets, executed BEFORE each
  fleet leaves status='ARRIVED' (see 22.4 ordering constraint 3), with the battle-level
  loot_applied_at stamp applied once at the end. With (a) no loop is needed and only PG-09 plus the
  idempotency fix apply. No new table is required for any option.
```

### 22.8 Implementation boundary (no code written by this mission)

```text
IMPLEMENTATION BOUNDARY

1. [PG-08] resolve_attack_arrival — survivor attribution
   replace the single ATTACKER participant lookup + write-back with a loop over every participant
   of the battle whose participant_type='FLEET' (the phase-4B initialiser already materialises
   ATTACKER/FLEET and DEFENDER/FLEET with their own participant_id and owner technology context,
   so the survivor data is already correct per participant).
   no schema change.

2. [PG-08] resolve_attack_arrival — narrow (do NOT remove) the Phase 4B fail-closed guard
   the guard becomes an assertion over participant SHAPES the loop cannot settle, e.g. any
   participant_type other than FLEET/PLANET, so an unhandled participant can still never be
   settled silently.

3. [PG-08] battle-level settlement resolution (the real idempotency fix) — no new column
   resolve_combat currently resolves a battle only by combat_battles.fleet_id for the INITIATING
   fleet. Add a participant-based lookup first
       select battle_id from combat_battle_participants
        where fleet_id = p_fleet_id and side = 'ATTACKER' order by created_at limit 1
   falling back to the existing fleet_id lookup (DG-10) so the certified single-fleet replay
   anchor is preserved. Combined with 1 (which moves every participating fleet out of ARRIVED),
   a second fleet's arrival then early-returns instead of creating a second battle.

4. [PG-17] defending participants
   survivors are written back by 1; status and holding_until are left UNTOUCHED, so the certified
   worker transition HOLDING -> RETURNING on holding_until remains the only authority.
   no schema change.

5. [PG-17] producer contract — OUT OF SCOPE
   who may hold, for how long, and what creates a DEFENDER/FLEET participant stays a separate
   mission. The settlement in 1 and 4 must work for participants that a future producer creates,
   and must not itself create any.

6. [PG-18] sync_combat_battle_final_counts + the equivalent block in run_expedition_combat
   add the participant filter (participant_type='PLANET') to defender_ships_* and
   defender_defenses_* so the counters keep describing the planet and stay coherent with
   defender_ships_before (which resolve_combat computes from planet_ships).
   no column change, no report change.

7. [PG-09] apply_attack_loot — capacity source                       BLOCKED until PG-09 is decided
   the capacity aggregate moves from combat_battles.fleet_id to the decided population.
   the 50 % caps, the metal -> crystal -> deuterium order, the cascade and the
   loot_applied_at idempotency must stay byte-identical.

8. [PG-10] apply_attack_loot — recipient / allocation               BLOCKED until PG-10 is decided
   the single credit statement becomes a per-entitled-participant loop, ordered BEFORE each fleet
   leaves status='ARRIVED' (22.4 constraint 3). with option (a) the credit statement is unchanged.

9. [PG-09/10] loot_applied_at ordering
   the zero-capacity early return currently stamps the battle as loot-applied; in a multi-fleet
   world the stamp must be applied exactly ONCE, after every participant has been considered, and
   must never suppress another participant's credit.

10. tests — see 22.9. every implemented invariant gets a rollback-safe fixture; the certified
    suites must stay green unchanged (43/43 combat + 13/13 collision + 16/16 defender participant
    + 25/25 shipyard + 50/50 + 13/13 support + 23/23 fleet + 12/12 research + buildings).

NO migration is required for 1, 2, 3, 4 or 6: they are function-body changes (CREATE OR REPLACE),
and the ACL/definer shape of the affected functions must be re-verified afterwards because a
changed signature resets EXECUTE to PUBLIC (the Phase 4A lesson). 7 and 8 wait for their decisions.
```

### 22.9 Future test plan

```text
SINGLE PARTICIPANT (must stay byte-compatible with the certified behaviour)
  · survivors, losses, loot and the report are unchanged from today
  · the existing attack 12/12 suite must pass untouched

MULTI PARTICIPANT / SAME OWNER
  · two ATTACKER/FLEET participants of one player: no attribution collapse, each fleet's
    fleet_movement_ships reflects its OWN participant
  · a battle where participant A loses everything and B survives

MULTI PARTICIPANT / DIFFERENT OWNERS
  · owner identity preserved per participant; no cross-player mutation
  · loot allocation deterministic and reproducible (once PG-10 is decided)

MULTIPLE DEFENDERS
  · defender_ships_before/after and defender_defenses_* remain planet-scoped (PG-18)
  · a DEFENDER/FLEET participant's ships appear ONLY in the participants payload
  · the defending fleet keeps HOLDING after the battle and returns on its own holding_until (PG-17)

ZERO SURVIVORS
  · a participant with no survivors produces NO fleet_movement_ships rows (CHECK quantity > 0)
    and no phantom fleet

PARTIAL LOSSES
  · capacity is derived from the state the decision names (PG-09), never from a stale snapshot

REPEATED / DUPLICATE SETTLEMENT
  · re-running settlement for the same battle changes nothing (loot_applied_at, one debris
    generation, idempotent repair)
  · a SECOND participating fleet's arrival resolves to the SAME battle and settles nothing again
    (boundary item 3)

LEGACY COMPATIBILITY
  · Phase 3/4/4A/4B suites stay green; the public report payload stays byte-identical (except the
    intentional PG-18 scoping, which preserves its meaning)

NO fixture may depend on permanent LIVE data. No test may be weakened to obtain green.
```

### 22.10 OGameX compatibility check

Consulted on 2026-09-22 **as contrast only**, on specific questions. Files read: `app/GameMissions/
BattleEngine/BattleEngine.php`, `app/GameMissions/BattleEngine/Services/LootService.php`,
`app/GameMissions/BattleEngine/Models/*` (listing), `app/GameMissions/AcsDefendMission.php`.
The project's own translation layer (`docs/reference/OGAMEX_LGI_MAP.md` §C and §6) remains the authority on
how OGameX may be used.

```text
OGAMEX COMPATIBILITY CHECK

Observation 1 (architecture)
  OGameX computes the battle in PHP objects backed by a separate Rust engine
  (BattleEngine / PhpBattleEngine / RustBattleEngine) and then mutates models.
  LGI computes it in plpgsql inside the worker transaction, keyed by participant rows.
  -> DISCARD. Not adaptable: LGI's integrity boundary is the transaction, not a service layer.

PG-08: OGameX produces PER-FLEET results (AttackerFleetResult, DefenderFleetResult) and its
  AcsDefendMission explicitly states that a defending mission's unit counts "may have been updated by
  battle processing if the fleet was attacked during hold time, so getFleetUnits() returns the correct
  post-battle survivors".
  LGI already has the equivalent authority (participant-keyed combat_individual_units.alive).
  Difference: OGameX stores it in objects, LGI in participant rows.
  Contradiction with a CLOSED LGI decision: NO.
  LGI decision: KEEP AS REFERENCE (corroborates per-participant survivors). NOTHING IMPORTED.

PG-09: OGameX takes capacity from getTotalCargoCapacity() of the COMBINED attacker fleet, i.e. the fleets
  as handed to the engine = pre-combat composition.
  LGI today takes it from the initiating fleet's post-combat fleet_movement_ships.
  Difference: composition-origin (pre vs post combat) and fleet scope (all vs one).
  Contradiction with a CLOSED LGI decision: NO — LGI has no certified rule for capacity origin.
  LGI decision: REFERENCE ONLY. It evidences that "original composition" is a real design (LGI option 2)
  rather than a speculative one; it does NOT decide the gate.

PG-10: OGameX credits the loot to ONE player ($this->attackerPlayer, i.e. attackers[0]) and its
  distributeLoot() splits across RESOURCE TYPES, never across participating fleets.
  LGI has no player-level resource pool: loot rides a fleet's cargo to that fleet's ORIGIN planet.
  Difference: player-level credit is not expressible in LGI.
  Contradiction with a CLOSED LGI decision: NO.
  LGI decision: PARTIALLY CORROBORATING for option (a) "the initiating fleet carries everything" — it is
  an externally used design, and it also preserves LGI's current certified credit statement. It remains a
  fairness rule, so the gate stays a human decision. NOTHING IMPORTED.

PG-17: OGameX FleetMissionType "ACS Defend" uses FleetSpeedType::holding (the same class LGI selected for
  ACS_HOLD/HOLDING/DEFEND), keeps the fleet for the whole hold, and only then starts the return mission
  with the post-battle survivors.
  LGI: HOLDING -> RETURNING strictly on holding_until; settlement does not touch the window.
  Difference: none of substance in the lifecycle contract.
  Contradiction with a CLOSED LGI decision: NO.
  LGI decision: KEEP AS REFERENCE (corroborates the PG-17 decision). NOTHING IMPORTED.

PG-18: OGameX has no persisted side-aggregate "battle header" counters of this shape; its results are
  per-fleet and per-round structures exposed for the battle report.
  Contradiction with a CLOSED LGI decision: NO.
  LGI decision: NO GUIDANCE AVAILABLE — LGI's counter semantics are internal and are settled by
  compatibility with its own certified report contract. NOTHING IMPORTED.

Also observed and DISCARDED (no LGI equivalent, no need introduced):
  TacticalRetreatService / TacticalRetreatDecision (LGI has no recall path),
  DefenseRepairService (LGI already has planet-scoped repair),
  WreckFieldService / moon creation (LGI has neither).

Contradictions found: NO
Imported semantics: NONE
```

### 22.11 Invariants this boundary must not break

```text
· participant identity, target identity and loss identity (Phase 4A) — unchanged
· DEFENDER/FLEET materialisation and the bounded definer shapes (Phase 4B) — unchanged
· the round engine: snapshots, shots, damage ledger, rapidfire, explosion, round cap — untouched
· debris: ONE generation per battle; repair: planet-scoped; loot caps: 50 %
· the certified report contract: the public payload keeps its meaning
· the worker's per-fleet failure isolation and replay guards — untouched
· expedition compatibility: DEFENDER/ENEMY is never reinterpreted as DEFENDER/FLEET
· ACL/definer/search_path hardening is re-verified after every CREATE OR REPLACE
```

**Nothing in §22 is implemented.** The implementation mission may start on PG-08 / PG-17 / PG-18 and must
wait for the PG-09 / PG-10 decisions before touching loot.

## 23. ACS SETTLEMENT CONTRACT RESEARCH (read-only, 2026-09-22)

> **Read-only mission.** No function created or replaced, no migration, no INSERT/UPDATE/DELETE, no GRANT,
> no UI. Purpose: determine which settlement contracts LGI still needs, what each one must own, and which
> part of that is evidenced by OGameX versus which part remains an LGI product decision.
>
> Evidence levels: **LGI LIVE VERIFIED** (deployed catalog/definitions re-read 2026-09-22),
> **OGameX VERIFIED** (source read), **INFERRED**, **NOT VERIFIED** (explicitly stated).

### 23.1 LGI money-path contract inventory (LIVE)

| Function | SECURITY DEFINER | client EXECUTE | reads `combat_battle_participants` | reads `fleet_movement_ships` | filters `participant_type='PLANET'` |
|---|---|---|---|---|---|
| `resolve_combat` | yes | no | **yes** | yes | no |
| `resolve_attack_arrival` | no | no | **yes** | yes | yes |
| `apply_attack_loot` | no | no | **no** | yes | no |
| `sync_combat_battle_final_counts` | no | no | **no** | **no** | no |
| `run_expedition_combat` | yes | no | no | no | no |
| `initialize_individual_combat_units` | no | no | yes | yes | yes |
| `create_combat_debris` | no | no | no | no | no |
| `repair_defenses_after_combat` | yes | no | no | no | no |
| `process_fleet_movements` | yes | no | no | yes | no |
| `get_player_battle_reports` | yes | **yes** | yes | no | no |

Three structural facts follow directly from that table and they define the whole contract gap:

```text
1. apply_attack_loot does NOT reference combat_battle_participants at all ⇒ loot is structurally
   single-fleet: it can only ever see combat_battles.fleet_id.          (PG-09 / PG-10 gap)
2. sync_combat_battle_final_counts reads neither participants nor fleet composition ⇒ it is a pure
   SIDE aggregate over combat_individual_units; it cannot tell a planet ship from a fleet ship.
                                                                       (PG-18 gap)
3. There is NO standalone "settle one participant" contract: all settlement is inlined inside
   resolve_attack_arrival for exactly one attacker participant + the planet participant.
                                                                       (PG-08 gap)
```

Available per-participant material (LIVE): `combat_battle_participants` carries `id`, `battle_id`, `side`,
`participant_type`, `fleet_id`, `planet_id`, `player_id`, `origin_planet_id`, `mission_type`;
`combat_individual_units` is participant-aware per round; `fleet_movements` carries the cargo
(`metal/crystal/deuterium`), `status`, `returns_at`, `holding_until`; `fleet_movement_ships` is
`UNIQUE(fleet_id, ship_id)` + `CHECK(quantity > 0)`.

Idempotency gates present in LIVE (all verified, none participant-level):

```text
apply_attack_loot                 loot_applied_at gate                       (BATTLE level)
create_combat_debris              combat_debris_generations UNIQUE(battle_id)
repair_defenses_after_combat      combat_defense_repairs existence probe
resolve_attack_arrival            early return unless status = ARRIVED       (FLEET level)
resolve_combat                    replay lookup by combat_battles.fleet_id   (INITIATOR only)
resolve_attack_arrival            run_expedition_combat only when finished_at IS NULL
ux_combat_battles_one_per_fleet   UNIQUE(combat_battles.fleet_id)            (INITIATOR only)
```

### 23.2 OGameX responsibility map (reference, OGameX VERIFIED)

Traced from the fleet mission down to the return, on the current OGameX `main` sources:

```text
FleetMission (AttackMission / AcsDefendMission)
   ↓  AttackerFleet::fromFleetMission()      DefenderFleet::fromFleetMission() / ::fromPlanet()
   │     units  = FleetMissionService::getFleetUnits($mission)
   │     cargo  = FleetMissionService::getResources($mission)
   │     ownerId = $mission->user_id
   │     fleetMissionId = $mission->id        (0 = planet owner's stationary forces)
   │     isInitiator = true only for the fleet that created the union
   ↓  AttackerFleet::toBattleUnits()          "Each fleet uses its OWN player's tech levels"
   ↓  BattleUnit{ ..., fleetMissionId, ownerId }   ← EVERY unit carries fleet + owner identity
   ↓  battle rounds
   ↓  AttackerFleetResult{ fleetMissionId, playerId, unitsStart, unitsResult, unitsLost,
   │                       resourceLoss, lootShare, survivingCargo, completelyDestroyed }
   │  DefenderFleetResult{ fleetMissionId, ownerId, unitsStart, unitsResult, unitsLost,
   │                       completelyDestroyed }
   ↓  BattleResult{ side aggregates + attackerFleetResults[] + defenderFleetResults[]
   │               ("empty array for backward compatibility with single-* battles"),
   │               loot, lootPercentage, debris, wreckField, repairedDefenses (70 %),
   │               rounds, attacker/defender tech levels, attackerPlanetId }
   ↓  LootService(UnitCollection $attackerFleet = COMBINED, PlayerService $attackerPlayer = attackers[0])
   │     calculateLootCapacityConstrained() -> 50 % of the planet, constrained by capacity
   │     distributeLoot($loot, $capacity)   -> splits across RESOURCE TYPES (not across fleets)
   ↓  mission record updated with surviving units + resources
   ↓  AcsDefendMission::processArrival()  -> startReturn($mission, getResources($mission),
   │                                        getFleetUnits($mission))   (only after the hold expires)
   ↓  processReturn() -> destination planet addUnits + addResources; $mission->processed = 1
```

Explicit OGameX statements used as evidence:

```text
AttackerFleetResult::$lootShare         "This fleet's share of the loot."
AttackerFleetResult::$survivingCargo    "Cargo resources that survived (proportional to surviving
                                         cargo capacity)."
AttackerFleet::getSurvivingCargoCapacity(UnitCollection $survivingUnits)
BattleResult::$attackerFleetResults     "Per-fleet results for each attacking fleet in ACS battles."
BattleResult::$defenderFleetResults     "Per-fleet results for each defending fleet (planet owner + ACS
                                         defend fleets)."
DefenderFleet::fromPlanet()             planet ships + defences, EXCLUDING missiles
FleetMission "ACS Defend"               FleetSpeedType::holding · requires buddy/alliance
AcsDefendMission::processArrival()      "Unit counts on the mission record may have been updated by battle
                                         processing if the fleet was attacked during hold time, so
                                         getFleetUnits() returns the correct post-battle survivors."
AcsDefendMission::processReturn()       returns units + resources to the destination planet;
                                         $mission->processed = 1
```

**Evidence limit (NOT VERIFIED):** the exact arithmetic that turns the total loot into each fleet's
`lootShare` (rounding and remainder) lives inside `BattleEngine.php` (35 KB), whose middle section was not
readable in full from this environment. Only the model contract is asserted here. Per the OGameX rule it
would not be imported anyway; it is recorded as not-fully-read rather than guessed.

### 23.3 LGI ↔ OGameX contract map

```text
EXISTS FULL  = contract exists and is generic
EXISTS FLEET = exists but hard-wired to one fleet (the initiator)
PARTIAL      = exists only for part of the required scope
MISSING      = does not exist
```

| Contract / function | LGI | OGameX equivalent | Responsibility | Inputs | Outputs | Decision |
|---|---|---|---|---|---|---|
| **battle-level settlement orchestrator** | PARTIAL (`resolve_attack_arrival`, keyed to one fleet id) | the triggering mission's `processArrival` + result application | settle the WHOLE battle **exactly once**, whichever fleet triggers it | `battle_id` | settled battle; no-op on replay | **MISSING CONTRACT — define** (PG-08) |
| **participant fleet settlement** | MISSING (inlined, single participant) | `AttackerFleetResult` / `DefenderFleetResult` + mission update | write ONE participant fleet's survivors/losses and advance or leave its state | `battle_id` + `participant_id` | `fleet_movement_ships` rewritten; status transition | **MISSING CONTRACT — define** (PG-08 / PG-17) |
| **loot capacity** | EXISTS FLEET (`apply_attack_loot`) | `LootService` (combined fleet) + `AttackerFleet::getSurvivingCargoCapacity()` | total cargo capacity the battle may fill | battle + ATTACKER participants' composition | one capacity number | **PG-09 product decision** |
| **loot allocation** | MISSING | `AttackerFleetResult::$lootShare` (per fleet) | split the plunder deterministically across entitled fleets | capacity + entitlement + planet resources | per-fleet cargo credit | **PG-10 product decision** |
| **defender fleet settlement** | MISSING (no producer; guard refuses) | `DefenderFleetResult` + `AcsDefendMission` | write a defending fleet's survivors and **preserve its hold** | `battle_id` + a DEFENDER/FLEET participant | `fleet_movement_ships` rewritten; `holding_until` untouched | **DECIDED** (PG-08 + PG-17) |
| **ACS return transition** | EXISTS FLEET (`status` ARRIVED → RETURNING) | `startReturn()` per mission + `processed` flag | move each participating fleet out of its arrival state once | one `fleet_id` | `RETURNING` + `returns_at` | **DECIDED** (PG-08 + PG-17) |
| **battle report projection** | EXISTS FULL (`get_player_battle_reports`) | `BattleResult` → battle report | expose the certified per-battle payload | `battle_id` + caller identity | report row | **DECIDED** (PG-18: meaning preserved) |

**No contract in the MISSING/PARTIAL rows is written here** — only its responsibility, inputs and outputs.
A contract is defined before it is implemented; that is the point of this gate.

### 23.4 Classification of every OGameX finding

```text
CORROBORATED — OGameX independently does what LGI already does
  · every combat unit carries fleet + owner identity (BattleUnit.fleetMissionId/ownerId
    ↔ LGI combat_individual_units.participant_id)
  · per-fleet survivor/loss results exist (AttackerFleetResult / DefenderFleetResult ↔ LGI
    per-participant alive state + participant-aware loss readers)
  · each fleet fights with ITS OWN owner's tech levels ("Always use OWN player's tech levels"
    ↔ LGI get_combat_*_stat(part.player_id, ship_id))
  · the defender side = stationery planet forces OR separately identified defending fleets
    (DefenderFleet::fromPlanet with fleetMissionId 0 vs ::fromFleetMission ↔ LGI DEFENDER/PLANET
    vs DEFENDER/FLEET)
  · defences repaired at 70 % (BattleResult.repairedDefenses ↔ LGI repair_defenses_after_combat)
  · a defending fleet keeps its hold and returns AFTER the hold window with its post-battle
    survivors (AcsDefendMission ↔ the PG-17 decision)
  · holding missions use a holding speed class (FleetSpeedType::holding ↔ holding_fleet_speed)

ARCHITECTURAL REFERENCE — informs the contract shape without deciding anything
  · side aggregates and per-fleet result arrays COEXIST, with the per-fleet arrays EMPTY for
    single-fleet battles "for backward compatibility" → validates LGI keeping combat_battles
    aggregates while adding per-participant settlement, and keeping single-fleet behaviour intact
  · loot capacity from the COMBINED attacker fleet (pre-battle composition) → evidences PG-09
    option (2) as a real design; it does not decide it
  · per-fleet loot attribution exists as a concept (AttackerFleetResult::lootShare) → evidences
    PG-10 per-fleet allocation as a real design; it does not decide it
  · cargo survival proportional to surviving cargo capacity (survivingCargo) → reference for how a
    fleet's own carried cargo could behave after losses; LGI currently has NO cargo-loss rule
  · idempotency by a per-mission `processed` flag → reference for per-fleet idempotency; it is a
    MISSION-level guard, conceptually the same unit as LGI's per-fleet status transition

LGI-CONTRADICTORY — must NOT be imported
  · loot credited to a single player (LootService is constructed with one PlayerService): LGI has no
    player-level resource pool; resources live on planets and loot rides a fleet's cargo to that
    fleet's origin planet
  · the battle computed outside the database (PHP service + separate Rust engine, `rust/` present in
    the repository root): LGI's integrity boundary is the worker transaction
  · tactical retreat, Hamill Manoeuvre, moons, wreck fields, missile exclusion: features LGI has
    deliberately not adopted; importing any of them would create a new product surface
  · character-class loot percentages (base 50 %, e.g. 75 % for a class against inactive players):
    LGI's cap is a fixed 50 % with no character classes

NOT APPLICABLE
  · Eloquent models, Laravel jobs/routing, PHP lifecycle assumptions, OGameX table names

PRODUCT DECISION — still LGI's own
  · whether destroyed ships may carry loot at all (PG-09)
  · entitlement plus the deterministic allocation rule, including rounding and remainder (PG-10)

Contradictions with CLOSED LGI decisions: NONE
Imported semantics: NONE
```

### 23.5 PG-08 — survivor attribution

```text
OGameX evidence:            per-fleet result objects keyed by fleetMissionId + ownerId
                            (AttackerFleetResult / DefenderFleetResult); BattleUnit carries
                            fleetMissionId + ownerId per UNIT; AcsDefendMission returns the mission's
                            own post-battle survivors after the hold.
LGI architectural evidence: combat_individual_units.alive is per participant (Phase 4A/4B, certified);
                            combat_battle_participants.fleet_id is the only durable fleet key;
                            fleet_movement_ships is UNIQUE(fleet_id, ship_id) + CHECK(quantity > 0)
                            and belongs to exactly one player.
LGI product decision:       NONE REQUIRED. A pooled attacker result would have to zero or delete other
                            participants' fleets, i.e. transfer ships between players, which the
                            ownership chain auth.uid() -> players.user_id -> players.id forbids.
Recommended boundary:       define ONE participant-settlement contract (responsibility: write the
                            participant's own survivors/losses and advance or leave its state) and
                            keep combat_battles as a side aggregate. No schema change, no new table.
Verdict:                    PG-08 = per-participant. Same conclusion as §22.1, now independently
                            corroborated by OGameX.
```

### 23.6 PG-09 — loot capacity: option matrix

Every option is described on the fields the research gate requires.

```text
OPTION 1 — initiating fleet only  (current behaviour)
  source data             fleet_movement_ships of combat_battles.fleet_id
  authority               combat_battles.fleet_id (the replay key)
  ownership               one player
  destroyed fleet         n/a (only one fleet is ever considered)
  partial loss            capacity follows that one fleet's survivors
  zero survivors          capacity 0 -> early return that still stamps loot_applied_at
  idempotency             loot_applied_at (battle level) — already present
  interaction w/ fms      direct (it IS the query source)
  interaction w/ ciu      none
  OGameX equivalent       none — OGameX uses the combined fleet, never the initiator alone
  LGI consequence         privileges whichever fleet happened to create the battle: an artifact of
                          the replay key, not a rule; every other participant's cargo is irrelevant
  verdict                 defensible ONLY if the product states "only the initiating fleet loots"

OPTION 2 — all ATTACKER participants, ORIGINAL composition
  source data             combat_individual_units WHERE round_number = 1 (participant-aware)
  authority               the battle's initial state
  ownership               per participant
  destroyed fleet         still contributes capacity (a destroyed ship "carries")
  partial loss            capacity ignores losses
  zero survivors          may be > 0 with no surviving ship -> conflicts with PG-10 (ii)
  idempotency             read-only over immutable round-1 rows (naturally idempotent)
  interaction w/ fms      indirect (must be joined to participants to know which fleets count)
  interaction w/ ciu      direct
  OGameX equivalent       YES — capacity from the COMBINED attacker fleet as handed to the engine,
                          i.e. the pre-battle composition
  LGI consequence         creates a SECOND authority for "what a fleet consists of" inside loot
                          (round-1 units) while settlement writes back fleet_movement_ships

OPTION 3 — all ATTACKER participants, SURVIVING composition
  source data             fleet_movement_ships joined to the battle's ATTACKER/FLEET participants,
                          read AFTER the participant write-back
  authority               fleet_movement_ships (the single existing composition authority)
  ownership               per participant
  destroyed fleet         contributes 0 (CHECK(quantity > 0) means no rows at all)
  partial loss            capacity follows survivors exactly
  zero survivors          contributes 0, while the aggregate can still be > 0 from other participants
  idempotency             relies on the write-back being idempotent (it is: recomputed from units)
  interaction w/ fms      direct
  interaction w/ ciu      indirect (through the write-back)
  OGameX equivalent       PARTIAL — OGameX has AttackerFleet::getSurvivingCargoCapacity() per fleet but
                          its LootService constraint uses the combined (pre-battle) fleet
  LGI consequence         no new data source, one authority, and the natural extension of the
                          certified single-fleet read

OPTION 4 — configured capacity
  source data             a new configuration surface
  authority / ownership / destroyed fleet / partial loss / zero survivors   undefined
  idempotency / interactions                                              n/a
  OGameX equivalent       none
  LGI consequence         introduces configuration LGI does not have and cannot infer
```

```text
OGameX evidence:            LootService is constructed with a COMBINED attacker fleet and constrains the
                            total loot by its getTotalCargoCapacity(); a per-fleet
                            AttackerFleet::getSurvivingCargoCapacity() also exists.
LGI architectural evidence: apply_attack_loot reads ONLY combat_battles.fleet_id; the participant layer is
                            participant-aware but loot never consults it; the certified single-fleet
                            read is fleet_movement_ships AFTER the write-back.
LGI product decision:       REQUIRED. Whether a destroyed ship may carry loot (and whether the initiator
                            is privileged) is a balance rule; the architecture excludes neither (2)
                            nor (3).
Recommended boundary:       (3) if the product wants one authority and the smallest change; (2) only as
                            an explicit product statement, because it adds a second composition
                            authority; (1) only if "only the initiator loots" is stated as a rule;
                            (4) rejected unless a configuration surface is deliberately specified.
```

### 23.7 PG-10 — loot recipient / allocation

Entitlement and allocation are two separate questions; the table crosses them on the fields the gate
requires.

```text
ENTITLEMENT
  (i)   initiating fleet only
        ownership: one player. carrier: one fleet_movements row. planet credit: that fleet's
        origin_planet_id. destroyed participant: n/a. same-owner multiple fleets: only the initiator
        carries. different-owner fleets: they receive nothing. rounding/remainder: single carrier, so
        the existing code path is unchanged. LGI consequence: lowest regression risk and it matches the
        certified credit statement, but in ACS it lets one player keep cargo other players' ships helped
        to carry. OGameX: it credits ONE player (attackers[0]), which LGI cannot express as a pool but
        CAN express as "the initiator's fleet carries it".
  (ii)  every ATTACKER participant that survived with at least one ship
        ownership: per participant. carrier: each fleet's own cargo (metal/crystal/deuterium columns).
        planet credit: each fleet's own origin_planet_id. destroyed participant: gets nothing
        (consistent with zero capacity). same-owner multiple fleets: each carries its own share.
        different-owner fleets: each player receives what its own fleet carries home.
        rounding/remainder: MUST be defined. LGI consequence: fair across players, needs a per-fleet
        credit loop plus a remainder rule. OGameX: AttackerFleetResult::$lootShare is exactly a per-fleet
        share, so the concept is corroborated.
  (iii) every ATTACKER participant regardless of survival
        ownership: per participant. carrier: a destroyed fleet has zero capacity
        (CHECK(quantity > 0) leaves no rows), so it is entitled but cannot carry; the share would be
        lost or need redistribution. LGI consequence: contradicts (iii)'s own premise and complicates
        the remainder rule. OGameX: no equivalent (its per-fleet results have no zero-capacity carrier).
  (iv)  same-owner aggregation (per player)
        requires a cargo holder per PLAYER. LGI has no player-level resource pool: resources live on
        planets, so the loot would still have to be split across that player's fleets. LGI consequence:
        not directly expressible; it collapses back into (ii)/(iii).

ALLOCATION (assuming (ii))
  (a) the initiating fleet carries everything
        deterministic, no rounding. Reuses the certified credit statement unchanged.
  (b) proportional to each entitled participant's (surviving) cargo capacity
        deterministic if the remainder rule is defined; scales with what each fleet contributed.
  (c) equal shares per entitled participant
        deterministic with a remainder rule; ignores fleet size.
  (d) per player, then split within the player
        two-stage; still needs a fleet-level split.
```

```text
OGameX evidence:            per-fleet loot attribution exists (AttackerFleetResult::$lootShare, "This
                            fleet's share of the loot"); LootService::distributeLoot() however splits
                            across RESOURCE TYPES, not across fleets, and the loot is credited to ONE
                            player. The exact share arithmetic was not fully readable (see 23.2).
LGI architectural evidence: loot is physically carried in fleet_movements.metal/crystal/deuterium and is
                            credited by the certified return leg to planet_resources of that fleet's
                            origin_planet_id; the credit is guarded by status='ARRIVED'; loot_applied_at
                            is a single BATTLE-level stamp. There is no player pool.
LGI product decision:       REQUIRED — entitlement AND the allocation rule AND the remainder rule.
Recommended boundary:       entitlement (ii) with allocation (b) if the product wants cross-player
                            fairness; entitlement (i) with allocation (a) if it wants the smallest change
                            and is willing to state that rule explicitly. Either way the per-fleet credit
                            must happen BEFORE each fleet leaves status='ARRIVED', and the battle-level
                            stamp must be applied exactly once at the end.
```

### 23.8 PG-17 — defender holding

```text
OGameX evidence:            AcsDefendMission keeps the fleet for the whole hold (FleetSpeedType::holding),
                            states that battle processing may have updated the mission record's unit
                            counts while the fleet was holding, and only then calls
                            startReturn($mission, getResources($mission), getFleetUnits($mission)) — i.e.
                            the surviving composition. Combat never redefines the hold window.
LGI architectural evidence: holding_until is an ABSOLUTE UTC window and the single timing authority
                            (active decision, PROJECT_CONTEXT §5); process_fleet_movements performs
                            HOLDING -> RETURNING strictly on it; nothing else may own that window.
LGI product decision:       NONE REQUIRED. Letting combat modify holding_until would create a second
                            authority over a window that already has one.
Recommended boundary:       defender fleet settlement writes the participant's survivors back to its own
                            fleet_movement_ships and leaves status and holding_until untouched; a fully
                            destroyed defending fleet travels the same certified path with no rows.
Verdict:                    HOLDING -> (combat: survivors updated) -> holding_until preserved ->
                            RETURNING only when holding_until expires. CONFIRMED, NOT IMPLEMENTED.
```

### 23.9 PG-18 — report counters

```text
OGameX evidence:            NO equivalent. BattleResult exposes per-fleet result arrays and per-round
                            structures for the report; there is no persisted "defender_ships_before /
                            defender_ships_after" pair in this shape, so OGameX offers no guidance.
LGI architectural evidence: defender_ships_before is computed in resolve_combat from planet_ships ONLY;
                            defender_ships_after is a side aggregate produced by
                            sync_combat_battle_final_counts (which reads neither participants nor fleet
                            composition, see 23.1); both are exposed by the certified report contract.
                            Adding a DEFENDER/FLEET participant makes before and after describe
                            DIFFERENT populations.
LGI product decision:       NONE for the coherence fix: scoping both counters to the DEFENDER/PLANET
                            participant keeps them coherent AND preserves the published meaning. A
                            COMBINED defending-force counter would be a deliberate report-contract
                            revision and is not part of this decision.
Recommended boundary:       participant_type='PLANET' filter on the two defender counters.
Verdict:                    planet-scoped. CONFIRMED, NOT IMPLEMENTED.
```

### 23.10 Idempotency model comparison (verified against code, not assumed)

```text
OGameX
  unit of idempotency        the MISSION: a `processed` flag is set when the arrival mission creates its
                             return leg (AcsDefendMission::processArrival -> $mission->processed = 1)
  duplicate arrival          the flag + the mission state prevent a second application
  duplicate loot/debris      lives inside the single BattleResult application for that battle
  consequence for LGI        a mission-level guard is conceptually the same unit as LGI's per-fleet status
                             transition, so per-fleet idempotency already has a home in LGI

LGI (LIVE, verified)
  fleet level                resolve_attack_arrival requires status = ARRIVED and early-returns otherwise
  battle level               apply_attack_loot.loot_applied_at; combat_debris_generations UNIQUE(battle_id)
                             + a battle-scoped advisory lock; combat_defense_repairs existence probe;
                             run_expedition_combat only when finished_at IS NULL
  initiator only             resolve_combat resolves a battle by combat_battles.fleet_id, enforced
                             additionally by ux_combat_battles_one_per_fleet(fleet_id)

VERIFIED GAP (this is why the earlier "battle-level idempotency" claim is not merely documentation)
  resolve_combat's only replay lookup is `combat_battles.fleet_id = p_fleet_id`. A participating fleet
  that did NOT create the battle cannot be resolved through it, so calling resolve_attack_arrival for
  that fleet would CREATE A SECOND BATTLE instead of settling the existing one.
  => battle-level resolution IS required. Minimal shape that preserves DG-10:
       look up the battle by participant (combat_battle_participants.fleet_id = p_fleet_id,
       side = 'ATTACKER') and FALL BACK to combat_battles.fleet_id.
  => no new column is needed, and the certified single-fleet replay anchor is preserved.

  The per-fleet guard then closes the loop at no extra cost: once settlement has moved every
  participating fleet out of ARRIVED, any later arrival for the same battle early-returns.
```

### 23.11 Research outcome

```text
For every ACS piece that does not yet exist in LGI, this gate now states:
  · its RESPONSIBILITY,
  · its INPUTS and OUTPUTS,
  · what OGameX evidences about it (classified), and
  · which part is LGI's own product decision.

STOP CONDITION REACHED
  PG-09 (loot-capacity source) and PG-10 (entitlement + allocation + remainder) remain product decisions.
  Nothing is implemented: no function created or replaced, no migration, no LIVE mutation, no UI, no
  participant producer, no settlement, and no OGameX rule imported.

Still awaiting human ratification (from §22.1, unchanged):
  PG-08 per-participant · PG-17 hold preserved · PG-18 planet-scoped.
```

**No settlement code exists in LGI and none was written by this mission.** The three ready gates may be
implemented after ratification; the loot path stays blocked until PG-09 and PG-10 are decided.








