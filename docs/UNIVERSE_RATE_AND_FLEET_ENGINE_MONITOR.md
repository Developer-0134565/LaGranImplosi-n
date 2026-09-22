# Universe Rate & Fleet Engine Monitor

> **Living document.** Update this file whenever the rate/evolution/fleet architecture changes materially.

## Purpose

This document is the canonical monitor for the universe-evolution rate engine and fleet travel model. It exists to prevent distributed formulas, ambiguous names, accidental double scaling, and session-to-session context loss.

## Canonical concepts

```text
E(t) = current universe evolution state

calculate_universe_scaling(E)
        |
        +-- resource_economy_scale    = E^1
        +-- resource_production_scale = E^1
        +-- building_speed_scale      = E^0.5
        +-- research_speed_scale      = E^0.5
        +-- fleet_movement_scale      = E^(1/3)
        +-- lifeform_speed_scale      = E^0.5
```

`calculate_universe_scaling(E)` contains only the transformation from evolution `E` to category-specific scaling factors. It does **not** contain classic rates, technologies, planet bonuses, lifeforms, items, events, alliances, or mission-specific modifiers.

### Example: E = 100

```text
resource_economy_scale    = 100
resource_production_scale = 100
building_speed_scale      = 10
research_speed_scale      = 10
fleet_movement_scale      = 4.6415888336
lifeform_speed_scale      = 10
```

## Evolution vs expansion

These are different systems and must never be collapsed into one generic `evolution` formula:

```text
UNIVERSE EVOLUTION
    E(t)
    -> rate/scaling changes over time

GALAXY/SYSTEM EXPANSION
    -> creates new systems/galaxies according to expansion timing rules
```

Galaxy expansion has its own formulas and state machine. A change to expansion timing must not silently change production, construction, research, or fleet scaling.

## Modifier pipeline

The conceptual pipeline is:

```text
classic/base rate
        -> universe evolution scaling
        -> technology / planet / lifeform modifiers
        -> item / event / alliance modifiers
        -> mission-specific modifiers
        -> final effective rate
```

The ordering is part of the architecture even where multiplication is mathematically commutative. Future modifiers must declare whether they are multiplicative, additive percentage, cap, or override before being inserted into the pipeline.

## Resource semantics

`economy` and `production` were considered too ambiguous. The canonical names are now:

- `resource_economy_scale`
- `resource_production_scale`

Both currently use `E^1`.

They remain separate because the current engine has two classic resource-rate stages. If both are applied to resource output, the evolution contribution is deliberately:

```text
E × E = E²
```

This is a gameplay/architecture decision, not a hidden exponent inside `calculate_universe_scaling`.

Do not rename or merge these stages merely because `E²` looks unusual. First audit their real consumers and determine whether they represent genuinely separate rate stages.

Solar energy is not multiplied by resource production scaling.

## Construction / research / lifeforms

```text
building_speed_scale = E^0.5
research_speed_scale  = E^0.5
lifeform_speed_scale  = E^0.5
```

These are speed multipliers. Higher scaling means shorter completion time when converted into the relevant effective speed/rate.

Consumers must not independently call `sqrt(E)` or recreate the exponent. They consume the centralized scaling result.

## Fleet movement

Fleet and expedition movement share one evolution scaling:

```text
fleet_movement_scale = E^(1/3)
```

There is **no separate expedition evolution exponent**. Expeditions can have expedition-specific modifiers, but their evolution component is the same movement scaling as normal fleet missions.

Conceptually:

```text
normal fleet speed
    = classic ship speed
    × fleet_movement_scale
    × later modifiers

expedition speed
    = classic ship speed
    × fleet_movement_scale
    × later modifiers
    × expedition-specific modifiers (if any)
```

## Non-linear travel time

The OGame/OGameX formula is used as a reference for structure, not as an authority for our gameplay balance.

Reference form:

```text
FlightTime =
    round(
        (
            (35000 / speed_percent)
            * sqrt(distance * 10 / slowest_ship_speed)
            + 10
        )
        / effective_fleet_rate
    )
```

Our public convention is `speed_percent = 100` for 100% speed. The implementation must document any internal normalization separately.

The important property is non-linearity: distance and ship speed interact through a square root rather than a simple `distance / speed` calculation.

## Coordinate distance model

Current reference geometry:

```text
same coordinate:              5
same system:                  1000 + 5 * |Δposition|
different system:             2700 + 95 * |Δsystem|
different galaxy:             20000 * |Δgalaxy|
```

Examples from `1:1:1`:

```text
1:1:1 -> 1:1:2 = 1005
1:1:1 -> 1:2:1 = 2795
1:1:1 -> 2:1:1 = 20000
```

These values are a reference baseline for our movement model. They are not permission to import every OGame mechanic.

## Base-speed investigation

Before changing fleet balance, establish the actual base travel-time behavior at:

```text
E = 1
fleet_movement_scale = 1
```

The test matrix must include:

```text
1:1:1 -> 1:1:2   same system / position change
1:1:1 -> 1:2:1   system change
1:1:1 -> 2:1:1   galaxy change
```

Use representative real ship speeds from our own ship definitions and verify the exact persisted arrival time path, not only a UI preview.

## Database implementation status

The centralized scaling/travel migration has been applied in Supabase.

Known implemented components:

- `calculate_universe_scaling(E)`
- timestamp-aware scaling lookup
- centralized universe-rate calculation
- canonical fleet travel-time helper
- building/research/shipyard/lifeform speed scaling
- shared fleet/expedition movement scaling

**Important:** the implementation is not considered fully closed until every fleet dispatch entrypoint uses the canonical travel-time helper for the persisted mission arrival time.

## Fleet integration update — 2026-09-18

The current live fleet audit centralized player-aware propulsion, cargo and fuel calculations and integrated mixed-fleet speed selection into the dispatch path. The ship prerequisite graph was checked against research/building definitions and no dangling references were found. A real divergence in `start_colonize_fleet()` was found and corrected: it now uses player-aware speed, canonical travel-time, evolution scaling and player-aware fuel calculation. A transactional live colonization test passed after fixing two implementation defects in the new path.

This does **not** close dispatch convergence. `start_fleet`, `start_fleet_mixed`, `start_colonize_fleet`, expedition and recycle must still be traced end-to-end to prove that every persisted `arrives_at`/`returns_at` uses the canonical movement formula.

## Current open audit

### A. Fleet dispatch convergence — CLOSED (LIVE MEASURED 2026-09-22)

Result: **no dispatch function keeps a second copy of the travel-time formula, and no canonical modifier is
applied twice.** Measured against the LIVE `pg_proc` definitions, not against documentation.

Reference-by-function matrix (LIVE, `pg_proc.prosrc` match):

```text
calculate_fleet_travel_time              -> start_fleet · start_fleet_mixed ·
                                            start_colonize_fleet · start_support_fleet      (exactly 4)
calculate_player_fleet_fuel_for_distance -> the same 4 dispatchers only                       (exactly 4)
calculate_player_ship_speed              -> the same 4 dispatchers
                                            + calculate_player_fleet_fuel_for_distance
calculate_mission_fleet_speed_multiplier -> the same 4 dispatchers
                                            + calculate_expedition_delay_seconds
calculate_player_ship_fuel_consumption   -> calculate_player_fleet_fuel_for_distance only     (exactly 1)
fuel_reduction                           -> calculate_player_fleet_fuel_for_distance only     (exactly 1 helper)
calculate_fleet_distance                 -> start_fleet · start_fleet_mixed · start_support_fleet
```

`start_colonize_fleet` legitimately does not call `calculate_fleet_distance`: the destination coordinate has
no planet yet, so it resolves the distance itself (see §Coordinate distance model). It still uses the
canonical travel-time and fuel helpers.

Single-application proof (occurrences per dispatcher, LIVE):

```text
every dispatcher: ship_speed 1x · mission_class 1x · evolution 1x · travel_time 1x · fuel 1x · power(E,1/3) 1x
start_fleet / start_fleet_mixed call get_active_lifeform_research_effect TWICE on purpose:
  1) key 'fleet_speed_percent'        -> always (same key as the item effect)
  2) key 'expedition_speed_percent'   -> ONLY when mission = EXPEDITION
two DIFFERENT modifier keys, not one modifier applied twice.
```

Canonical application (verbatim from LIVE `start_fleet`):

```sql
v_fleet_speed := calculate_mission_fleet_speed_multiplier(v_universe_id, v_mission_type);
v_evolution   := calculate_universe_evolution_rate(v_universe_id);
v_bonus       := 1 + (item fleet_speed_percent + lifeform fleet_speed_percent)/100;
IF v_mission_type = 'EXPEDITION' THEN
  v_bonus := v_bonus + lifeform expedition_speed_percent/100;
END IF;
v_fleet_rate  := v_fleet_speed * power(v_evolution, 1.0/3.0) * v_bonus;
v_travel_time := greatest(calculate_fleet_travel_time(v_distance, v_ship_speed, v_fleet_rate, 100), 1);
v_fuel        := calculate_player_fleet_fuel_for_distance(...);
```

Mission → speed class (LIVE `calculate_mission_fleet_speed_multiplier`, SECURITY DEFINER, fixed search_path):

```text
PEACEFUL  TRANSPORT · DEPLOY · COLONIZE · EXPEDITION                -> universes.peaceful_fleet_speed
WAR       ATTACK · ESPIONAGE · RECYCLE · RECYCLE_ATTACK · HARVEST   -> universes.war_fleet_speed
HOLDING   ACS_HOLD · HOLDING · DEFEND                               -> universes.holding_fleet_speed
unknown mission                                                     -> universes.fleet_speed (legacy)
NULL or <= 0 -> RAISE 'Invalid fleet speed for mission %'
```

So the HOLDING class is **prepared and correctly classified** even though no ACS/DEFEND gameplay exists.
Classification suite `supabase/tests/fleet_speed_classes.sql` → **23/23 PASS** LIVE.

Residual findings recorded by this audit (none of them a bug in the pipeline):

1. All four dispatchers are `SECURITY DEFINER`, `anon` EXECUTE denied, `authenticated` allowed.
2. **Latent guest branch**: `start_fleet`, `start_fleet_mixed` and `start_colonize_fleet` still accept a
   player with `coalesce(is_guest,false) = true` when `auth.uid()` is NULL. LIVE has **0** guest players
   (408 players, 0 with `is_guest = true`), so the branch is currently **unreachable**; it is guest
   decommission residue, deliberately not touched here.
3. `start_support_fleet` has **no** guest branch — the newest dispatcher is already guest-free.
4. `calculate_fleet_travel_time` keeps a PUBLIC `EXECUTE` while being the canonical authority; it is a pure
   `IMMUTABLE` formula and non-`SECURITY DEFINER`, so it leaks nothing (already recorded in the Fleet
   README §23.3.8).

### B. Resource naming/semantics — OPEN

Audit every consumer of:

- `resource_economy_scale`
- `resource_production_scale`

Confirm whether both represent distinct classic stages. Do not merge them until this audit is complete.

### C. Modifier ordering — OPEN

For every effective rate, identify the exact order and semantics of:

```text
classic
universe scaling
technology
planet
lifeform
item
event
alliance
mission-specific
```

### D. Expansion separation — CLOSED as a design rule

Universe evolution and galaxy/system expansion are separate systems. Never introduce a single formula intended to govern both.

## Audit guardrails

1. Do not put roots/cube roots back into individual consumers.
2. Do not put technology, item, planet, alliance, or event bonuses into `calculate_universe_scaling`.
3. Do not create a separate expedition evolution exponent.
4. Do not apply resource production scaling to solar energy.
5. Do not confuse galaxy/system expansion timing with resource/movement evolution.
6. Keep evolution calculations timestamp-aware where historical event resolution requires it.
7. Any future rate modifier must declare its mathematical type before insertion into the final-rate pipeline.
8. Fleet dispatch entrypoints must use the canonical travel-time helper.
9. Never copy an OGameX formula into the engine without first mapping its inputs to our own schema and gameplay rules.
10. Update this monitor whenever a canonical formula, name, modifier order, or integration point changes.

## Change log

### 2026-09-17 — Central scaling/fleet model

- Centralized category scaling around `calculate_universe_scaling(E)`.
- Standardized resource, construction, research, fleet movement and lifeform scaling semantics.
- Unified fleet and expedition evolution scaling under `fleet_movement_scale`.
- Documented non-linear travel-time reference and coordinate distances.
- Explicitly separated universe evolution from galaxy/system expansion.
- Recorded dispatch convergence as the next audit target.

### 2026-09-22 — Dispatch convergence CLOSED (LIVE measured)

- Closed audit item **A**: the four dispatchers (`start_fleet`, `start_fleet_mixed`,
  `start_colonize_fleet`, `start_support_fleet`) all use `calculate_fleet_travel_time` and
  `calculate_player_fleet_fuel_for_distance`; those two helpers are referenced by **exactly** those four
  functions, so no second copy of either formula exists.
- Closed the double-modifier hunt: every canonical step occurs exactly once per dispatcher. The two
  `get_active_lifeform_research_effect` calls in `start_fleet`/`start_fleet_mixed` are two different keys
  (`fleet_speed_percent` always, `expedition_speed_percent` only for EXPEDITION).
- Confirmed `fuel_reduction` exists in exactly one helper
  (`calculate_player_fleet_fuel_for_distance`) — no generic hyperspace reduction was reintroduced.
- Recorded the mission → speed-class mapping from LIVE, including the HOLDING class
  (`holding_fleet_speed`) being prepared and correctly classified while the ACS/DEFEND gameplay stays
  unimplemented.
- Recorded the latent guest branch in three dispatchers (unreachable: 0 guest players in LIVE).
- Fleet mission modifier pipeline is therefore **CANONICAL** with no bypass, no missing infrastructure and
  no UNKNOWN route.

### 2026-09-22 — ACS_HOLD transport unblocked (support authorization)

- `grant_planet_support_authorization` raised `42702 :: column reference "destination_planet_id" is
  ambiguous`: its own OUT-parameter names collided with the `on conflict (destination_planet_id,
  guest_player_id)` target list, so **no support authorization could ever be created** and
  `start_support_fleet` always failed with `SUPPORT_AUTHORIZATION_REQUIRED`. The ACS_HOLD dispatch was
  therefore unreachable end-to-end even though the dispatcher and the hold lifecycle existed.
- Repaired forward-only by `20260922052432_fix_support_authorization_conflict`, which names the unique
  constraint (`on conflict on constraint planet_support_authorizations_destination_guest_key`). An A/B
  rollback-safe reproduction proved the column-list form ambiguous and the constraint form correct —
  including the upsert path.
- Signature, `SECURITY DEFINER`, `search_path`, ACL and every authorization check are unchanged; the
  activation speed class still comes from `holding_fleet_speed` through the canonical pipeline, so this
  change touches no formula.
- LIVE result: `fleet_acs_hold_lifecycle.sql` **50/50** (previously unrunnable) and
  `fleet_support_authorization_chain.sql` **13/13**. The support **transport** is reachable; ACS combat
  participation remains unimplemented.
