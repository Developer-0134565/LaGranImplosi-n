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
| `app/Services` | business/domain services | Supabase functions/RPC + backend domain logic | AUDIT |
| `app/Actions` | explicit operations | RPC/actions | AUDIT |
| `app/GameMissions` | mission processing and states | fleet mission system | OPEN / HIGH |
| `app/GameObjects` | game-domain objects | tables + domain functions/types | AUDIT |
| `app/Models` | persistent entities | PostgreSQL/Supabase tables and generated types | AUDIT |
| `app/Jobs` | deferred work | `pg_cron` + timestamp-driven workers | AUDIT |
| `app/Events` | domain events | timestamped event/state processing | OPEN |
| `app/GameConstants` | rules/constants | centralized L.G.I. definitions/configuration | AUDIT |
| `database/migrations` | schema evolution | Supabase migrations | REFERENCE |
| `database/seeds` | initial/test data | L.G.I. seeds/test fixtures | AUDIT |
| `database/factories` | generated test data | fixtures/test helpers | AUDIT |
| `resources/js` | frontend organization | React/TypeScript | REFERENCE |
| `resources/css` | styling organization | existing L.G.I. CSS system | REFERENCE |
| `routes` | application entry points | Cloudflare Worker + Supabase/API boundaries | REFERENCE |

This table is an index, not proof that every OGameX component has a direct L.G.I. equivalent.

## Current first-pass map

The detailed structural comparison is maintained separately so this README remains a compact index:

[`OGAMEX_LGI_MAP.md`](OGAMEX_LGI_MAP.md)

The first pass identifies **fleet mission lifecycle, temporal events, combat boundaries and deferred processing** as the highest-value areas for deeper comparison. It does not indicate that L.G.I. needs an OGameX-style rewrite.

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

`docs/PROJECT_CONTEXT_PROMPT.md` should contain only the operational summary of this reference system and point here for detail. This document may grow without making the operational context encyclopedic.
