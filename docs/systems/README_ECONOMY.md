# ECONOMY — LA GRAN IMPLOSIÓN

> Durable knowledge for resources, production, costs, storage and temporal settlement.
> Operational status lives in [`../PROJECT_CONTEXT_PROMPT.md`](../PROJECT_CONTEXT_PROMPT.md);
> the functional map lives in [`README_FUNCTIONAL_AUDIT.md`](README_FUNCTIONAL_AUDIT.md).

## Layer classification (keep this distinction explicit)

```text
AUTHORITATIVE  the engine path that actually produces/persists game state
PROJECTION     read-only helpers that estimate a future state; never the source of truth
LEGACY         older entry points kept for internal compatibility; do not use for new work
BROKEN         deployed but raising at runtime, with no consumers
```

## Authoritative surface

| Function | Role | Notes |
|---|---|---|
| `calculate_planet_production(planet)` | production per hour (metal/crystal/deuterium/energy) | universe rates × item bonuses × lifeform bonuses × **energy factor** (`LEAST(1, energy_production/consumption)`) |
| `calculate_planet_storage(planet)` | storage capacities | uses `universes.storage_multiplier` |
| `update_planet_resources_until(planet, until)` | public temporal wrapper | settles resources **and** completes due building/research events |
| `update_planet_resources_until_raw(planet, until)` | settlement without event walking | used by `complete_building` to avoid recursive processing; raises `INVALID_RESOURCE_TIMESTAMP` when `until < last_calculated_at` |
| `process_planet_tick(planet)` | authoritative tick | locks planet, settles resources, completes due queue events |
| `sync_current_planet_resources(player, planet, until)` | client-facing settlement | SECURITY DEFINER; used by the frontend when opening Buildings |
| `calculate_universe_rates(universe)` | economy/production/building/research/fleet/expedition/lifeform rates | `base × evolution` (no hidden sqrt/cuberoot dampening) |
| `calculate_universe_evolution_rate(universe)` | E multiplier | consumed by rates, building time (√E) and fleet time (∛E) |
| `get_planet_economic_rates(planet)` | wrapper of `calculate_universe_rates` | — |
| `calculate_planet_production_snapshot` / `calculate_virtual_production` | deterministic variants | projection-style: no energy factor, no lifeform/item bonuses |

## Costs and times (authoritative per domain)

```text
buildings : calculate_building_cost(id, level) = base × cost_factor^(level-1)
            calculate_building_time(id, level, universe) = base_time × time_factor^(level-1) ÷ (building_speed × √E)
            calculate_building_energy_consumption(id, level)
research  : calculate_research_cost / calculate_research_time
ships     : calculate_ship_cost / calculate_ship_build_time
defense   : calculate_defense_cost / calculate_defense_build_time
fleet     : calculate_fleet_fuel_for_distance(distance, ship, qty) + travel time
            distance model: inter-galaxy 20000/unit · inter-system 2700+95/unit · inter-position 1000+5/unit · same 5
```

## Multipliers

```text
The `universes` table holds the per-universe parameters:
  economy_speed · production_speed · building_speed · research_speed · fleet_speed · expedition_speed ·
  lifeform_speed · resource_multiplier · storage_multiplier · fleet_debris_percentage ·
  defense_debris_percentage · ai_planet_density_target/tolerance · system_expansion_base_seconds/
  curve_exponent · special_galaxy_* · galaxy_roll_probability/interval_seconds
The evolution multiplier is applied AFTER the classic modifiers (calculate_universe_rates).
```

## Projection helpers (no consumers — do not wire them into the UI)

```text
project_building_production(planet, building)
  mixes the authoritative current value (calculate_planet_production) with a bare formula for the target
  value (no item/lifeform bonuses, no energy factor, bare energy for solar_plant) → can overstate a level-up.

calculate_building_production_delta(planet, building)   ← BROKEN / NO CONSUMERS
  selects `r.economy_rate` / `r.production_rate`, but calculate_universe_rates() returns `economy` /
  `production`. Live call returns: ERROR: column r.economy_rate does not exist.
  Neither the engine nor the frontend calls it. Repair or deprecate explicitly in a future cleanup
  migration; never use it as a production oracle.
```

## Legacy surface

```text
update_planet_resources(planet)   → COMMENT: "Legacy resource updater retained for internal compatibility;
                                     authoritative callers must use process_planet_tick/update_planet_resources_until."
process_planet_tick_local(planet) → local shortcut; the evolution document records that the heartbeat must
                                     route through the complete planet tick path.
project_planet_resources / evaluate_action_at_time / inspect_* → read-only projections.
```

## Temporal semantics

```text
planet_resources.last_calculated_at is the settlement watermark.
Settlement is interval-based: production accrues as (per_hour × elapsed/3600) capped by storage capacity;
energy is a balance value, not a produced resource.
The evolution multiplier is applied over the evolution-weighted seconds between two timestamps
(calculate_universe_evolution_production_seconds), so a rate change during downtime is honoured.
```

## Access restriction affecting the client

```text
public.universes has a public RLS SELECT policy for anon/authenticated but NO table GRANT SELECT, so
calculate_universe_rates() / calculate_planet_production() / calculate_building_time() are NOT callable
from the browser (verified live: "permission denied for table universes"). Build/research/ship/defense
actions are unaffected because their RPCs are SECURITY DEFINER. Consequence: the UI shows "TIEMPO BASE"
instead of the final build time. This belongs to the final security/RLS phase.
```

## Related documents

- [`README_FUNCTIONAL_AUDIT.md`](README_FUNCTIONAL_AUDIT.md) — domain map, gaps and test coverage
- [`README_UNIVERSE_EVOLUTION.md`](README_UNIVERSE_EVOLUTION.md) — E(t), scaling exponents and expansion
- [`README_GAME_ENGINE_AUDIT.md`](README_GAME_ENGINE_AUDIT.md) — construction audit and its guarantees
- [`../UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md`](../UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md) — canonical scaling and fleet-time audit

