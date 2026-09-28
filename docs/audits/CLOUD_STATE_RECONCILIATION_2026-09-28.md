# CLOUD STATE RECONCILIATION — 2026-09-28

## Scope

Direct audit of GitHub `main` and Supabase LIVE. This document is the durable cloud-state record; `docs/PROJECT_CONTEXT_PROMPT.md` remains the compact operational index.

## GitHub

- Repository: `Developer-0134565/LaGranImplosi-n`
- Branch audited: `main`
- HEAD at audit: `8942b90ed506ff9317abf2418d3b9b22c8065b08`
- Latest CI for this HEAD: successful.
- Migration files present in `supabase/migrations`: 379.

## Supabase LIVE

- Project: La Gran Implosión
- Project id: `evtfsbntvuqmahiskekd`
- Status: `ACTIVE_HEALTHY`
- Latest applied migration: `20260927140000`
- Applied migration rows: 377.
- Public tables: 74.
- Public functions: 338.
- Cron jobs: 6.
- Public RLS tables: 69.

## Migration provenance

The 379 repository filenames and 377 LIVE ledger rows do NOT form a one-to-one filename/version match.

Repository-only version prefixes observed:

```
20260919060000
20260919070000
20260919080000
20260919090000
20260919180000
20260920010000
20260920120400
20260920120800
20260926240000
```

LIVE-only version prefixes observed:

```
20260919055336
20260919061454
20260919062509
20260919070020
20260921133525
20260926130600
20260926133901
```

This is provenance drift, not proof that all repository-only SQL is absent from the live schema. Direct object checks confirmed that several repository-only migrations' effects are already present LIVE, including:

- `combat_battle_participants` and participant-aware combat functions;
- fleet outbound/returning indexes;
- ACS/support dispatch infrastructure;
- `can_start_building` as SECURITY DEFINER.

Do NOT edit `supabase_migrations.schema_migrations` manually, create same-version placeholders, or invent mappings. A migration is only considered reconciled when its payload/provenance has been demonstrated.

## Important security finding: guest hardening is NOT currently LIVE

The audit found seven public functions whose stored definitions still contain `is_guest` outside the two explicitly retained functions:

- `enforce_player_write_access()`
- `start_fleet(uuid,uuid,uuid,text,bigint,text)`
- `start_fleet_mixed(uuid,uuid,uuid,jsonb,text)`
- `start_colonize_fleet(uuid,uuid,integer,integer,integer)`
- `start_lifeform_building(uuid,text)`
- `start_lifeform_research(uuid,text)`
- `sync_current_planet_resources(uuid,uuid,timestamp with time zone)`

The checked-in migrations `20260920120400_remove_guest_rls_surface.sql` and `20260920120800_remove_guest_ownership_bypasses.sql` exist in GitHub, but their version prefixes are not present in the LIVE migration ledger.

Therefore the previous PROJECT_CONTEXT statements describing guest hardening as fully LIVE are stale and must not be used as operational truth.

The intended migrations were reviewed from GitHub. They are forward-only and self-verifying, but the current ChatGPT Supabase execution surface rejected their DDL application as a safety-gated destructive operation. No partial SQL was executed and no migration ledger was modified.

## Guest hardening reconciliation — CLOSED LIVE 2026-09-28

The earlier audit correctly identified that the historical guest-hardening migrations were not present in the LIVE ledger. The remediation was applied against the actual LIVE function shapes.

### LIVE changes applied

1. `20260920120400_remove_guest_rls_surface` was applied LIVE as migration version `20260928021418`; it removed the guest-only read-policy surface and rebuilt the affected owner-scoped policies.
2. `remove_guest_ownership_bypasses_live_reconciliation` was applied LIVE as migration version `20260928021509`; it removed `is_guest` authorization branches from `enforce_player_write_access()`, `start_fleet()`, `start_fleet_mixed()`, `start_colonize_fleet()`, `start_lifeform_building()`, `start_lifeform_research()`, and `sync_current_planet_resources()`, while preserving authenticated ownership checks and the explicit AI actor path.

### Verification

The final catalog gate returned **0 public functions** referencing `is_guest`, excluding only `register_guest_player` and `reconcile_universe_ai_population`.

The historical `20260920120800_remove_guest_ownership_bypasses.sql` was not replayed because its regex precondition did not match the actual LIVE `start_colonize_fleet()` shape. It has been superseded in GitHub by `20260928021509_remove_guest_ownership_bypasses_live_reconciliation.sql`.

The repository now contains migration files matching the actual LIVE migration versions created by the Supabase Management API.

## Current classification

- GitHub main: HEALTHY / current.
- Supabase service: HEALTHY.
- Migration provenance: RECONCILED for guest hardening; broader historical drift remains documented.
- Guest ownership/RLS hardening: CLOSED LIVE — 2026-09-28.
- Espionage buildings/research gating: CLOSED by the existing LIVE evidence.
- P3 ACL cleanup through `20260927140000`: CLOSED by existing LIVE evidence.
- Browser fleet certification: still environment-blocked, not simulated.
- Lifeforms: deferred / out of scope.

## Operating rule

Before another implementation mission, perform the SYNC GATE and consult this document for cloud-state discrepancies. Do not reopen domains marked CLOSED unless new LIVE evidence demonstrates a regression.

## Post-remediation security advisor snapshot

Supabase security advisors at 2026-09-28 02:16 UTC no longer report guest-policy/function residue as the issue addressed above. Remaining findings are broader pre-existing security debt: 3 RLS-enabled tables without policies, 5 mutable-search-path functions, 3 anon-callable SECURITY DEFINER functions, 61 authenticated-callable SECURITY DEFINER functions, anonymous-access policies on cron/dashboard/storage-related objects, and leaked-password protection disabled. These are separate follow-up items and were not silently folded into guest hardening.
