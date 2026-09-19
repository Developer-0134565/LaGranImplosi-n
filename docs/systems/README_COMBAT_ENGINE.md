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
