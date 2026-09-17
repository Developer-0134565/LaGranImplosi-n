# OGameX REFERENCE — LA GRAN IMPLOSIÓN

## Role

OGameX is a **permanent reference library**, not a dependency and not a source of truth for L.G.I. rules.

Use it to study established approaches to game-domain architecture, state handling, missions, calculations, jobs/workers, events, persistence and tests.

## Mandatory method

```text
study → understand → compare → adapt → validate
```

Never copy Laravel/PHP/ORM architecture blindly into L.G.I.

## Reference map

| OGameX area | Concept to study | L.G.I. adaptation | Status |
|---|---|---|---|
| `app/Services` | business/domain services | Supabase functions/RPC + backend domain logic | OPEN |
| `app/Actions` | explicit operations | RPC/actions | OPEN |
| `app/GameMissions` | mission processing and states | fleet mission system | OPEN |
| `app/GameObjects` | game-domain objects | tables + domain functions/types | OPEN |
| `app/Models` | persistent entities | PostgreSQL/Supabase tables and generated types | OPEN |
| `app/Jobs` | deferred work | queues/workers/cron/evolution processing | OPEN |
| `app/Events` | domain events | event/state processing | OPEN |
| `app/GameConstants` | rules/constants | centralized L.G.I. definitions/configuration | OPEN |
| `database/migrations` | schema evolution | Supabase migrations | REFERENCE |
| `database/seeds` | initial/test data | L.G.I. seeds/test fixtures | REFERENCE |
| `database/factories` | generated test data | fixtures/test helpers | REFERENCE |
| `resources/js` | frontend organization | React/TypeScript | REFERENCE |
| `resources/css` | styling organization | existing L.G.I. CSS system | REFERENCE |
| `routes` | application entry points | Supabase/API/Edge entry points | REFERENCE |

This table is an index, not proof that every OGameX component has a direct L.G.I. equivalent.

## Per-subsystem analysis template

When studying a concrete OGameX subsystem, document:

```text
OGameX reference:
Problem solved:
Entities:
States:
Transitions:
Validation:
Events:
Jobs/workers:
Persistence boundary:
Relevant formulas:
L.G.I. equivalent:
Current gap:
Recommended reference area:
What NOT to copy:
Validation required:
Status:
```

## Audit rule

An OGameX difference is not automatically a bug in L.G.I. A finding becomes actionable only when it conflicts with an explicit L.G.I. requirement or reveals a domain concern that our design has not addressed.

## Relationship with PROJECT_CONTEXT

`PROJECT_CONTEXT.md` should contain only the operational summary of this reference system and point here for detail. This document may grow without making the operational context encyclopedic.
