# UNIVERSE EVOLUTION — LA GRAN IMPLOSIÓN

## Purpose

Detailed durable knowledge for universe evolution, internal time, catch-up processing, galaxy/system expansion and AI population. `PROJECT_CONTEXT.md` keeps only the operational summary.

## Separation of systems

```text
UNIVERSE EVOLUTION
E(t)
→ rate/scaling changes

GALAXY/SYSTEM EXPANSION
→ creates systems/galaxies according to expansion rules
```

These systems must not be collapsed into one generic evolution formula.

## Universe scaling

Canonical transformation:

```text
calculate_universe_scaling(E)
```

Current category exponents:

```text
resource_economy_scale    = E^1
resource_production_scale = E^1
building_speed_scale      = E^0.5
research_speed_scale      = E^0.5
fleet_movement_scale      = E^(1/3)
lifeform_speed_scale      = E^0.5
```

The scaling function transforms `E` into category-specific factors. It does not contain technology, planet, lifeform, item, event, alliance or mission-specific modifiers.

## Modifier pipeline

```text
classic/base rate
    → universe evolution scaling
    → technology / planet / lifeform modifiers
    → item / event / alliance modifiers
    → mission-specific modifiers
    → final effective rate
```

Each future modifier must declare whether it is multiplicative, additive percentage, cap or override.

## Internal clock

Universe evolution must continue correctly across downtime. The server/client must not rely on a continuously running browser timer as the authoritative clock.

Use persisted timestamps/event state to detect elapsed real time and catch up pending work when processing resumes.

The universe heartbeat must route through the complete planet tick path when that path is responsible for building/research completion. Do not reintroduce an older local-only shortcut without a new audit.

## Normal galaxy expansion

Current agreed rule:

```text
new-system interval = 8 × G^0.75 hours
```

Systems are generated sequentially. Production scope currently includes 100 normal galaxies.

## Special galaxies

Every 12 real hours:

```text
1% global roll
```

On success:

- create one special galaxy after G100;
- start with 10 systems;
- use a separate system-expansion formula;
- do not reuse the normal-galaxy formula automatically.

## AI population

Target AI occupancy is approximately 5–10% of available universe slots, within a defined tolerance.

Whenever universe space expands, population logic should evaluate whether additional AI planets are required.

Do not create a second population state if existing universe population state can represent the process.

## Open implementation concerns

- Define the exact catch-up batching/limits for long downtime.
- Define idempotency rules for repeated processing attempts.
- Define event ordering when multiple universe events are overdue.
- Define monitoring/health information for the internal clock.
- Define AI placement constraints and collision handling.

These remain implementation/audit topics and should not be silently invented in the operational context.
