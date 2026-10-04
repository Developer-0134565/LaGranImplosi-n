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

## 2026-09-28 AI target protection closure


## 2026-09-29 — gap-closure sweep, advisor re-baseline, and the next hardening item

### Advisor posture is UNCHANGED by the 2026-09-29 closure sweep

Re-measured after `20260929000000` (colony/moon producer) and `20260929010000` (four wrong-answer
client helpers). Counts are **identical** to the 2026-09-28 02:16 UTC snapshot above — 3 RLS tables
without policies, 5 mutable-search-path functions, 3 anon-callable SECURITY DEFINER functions, 61
authenticated-callable SECURITY DEFINER functions, anonymous-access policies on cron/dashboard/storage,
leaked-password protection disabled. **Zero advisor delta** from the two new migrations, and the four
revocations moved an `authenticated` surface *down*, not up.

### NEXT HARDENING ITEM — `function_search_path_mutable` (5 functions) — NOT APPLIED, owner decision

The advisor's `function_search_path_mutable` WARN is **fully diagnosed but deliberately left open**.
All five have `proconfig = null` (no `SET search_path` at all) and **every one of the five bodies is a
pure single-`select` expression** using only built-ins (`coalesce`, `least`, `greatest`, `floor`,
`format`) and its own parameters — **no table reads and no calls to other project objects**:

| function | SECURITY DEFINER | ACL | client-reachable |
|---|---|---|---|
| `calculate_moon_creation_chance` | no | `authenticated,postgres,service_role` | **yes** |
| `format_coordinates` | no | `postgres,service_role` | no |
| `calculate_counter_espionage_chance` | no | `postgres,service_role` | no |
| `calculate_moon_field_capacity` | no | `postgres,service_role` | no |
| `wreck_field_recover_percent` | no | `postgres,service_role` | no |

Consequence: `set search_path = public, pg_temp` is **provably behaviour-preserving** on all five, and
it is the pattern every other contract in this project already uses. The owner reviewed this on
2026-09-29 and chose **NOT to change production in this pass**; it is recorded here as the next
hardening item rather than applied. When it is taken, the acceptance evidence should be: each body
byte-identical, each function returning identical values, `SECURITY INVOKER` preserved, and the advisor
WARN count dropping 5 → 0.

### 2026-09-29 project verifier results — 3 FAILs, ALL pre-existing / false positives

Both verifiers were run for the first time with working credentials. None of the three FAILs is a
product defect, and **none is a regression from the 2026-09-29 closure sweep**.

* `verify-identity.mjs` → **1 FAIL, false positive in the checker.** The assertion is
  `!identitySrc.includes('register_guest_player')`, but the only occurrence in `src/lib/identity.ts`
  is line 12, inside the comment that documents its removal
  (*"El modo invitado (sesión anónima + register_guest_player) fue retirado"*). The product is correct
  and agrees with the LIVE finding above that no public function references `is_guest`. A naive
  substring check now fails on the very comment that proves the guest path is gone, and would invite a
  future mission to "fix" already-correct code. Fix, when wanted, is to match calls rather than any
  mention, or to strip comments before the check.
* `verify-buildings.mjs` → **2 FAIL, pre-existing.** The script authenticates with the
  `VITE_SUPABASE_PUBLISHABLE_KEY`, so PostgREST executes it as `anon`, but it calls
  `calculate_building_cost`, which has been `authenticated`-only since before 2026-09-29 (the ACL dump
  taken at mission start, prior to any migration, already showed `anon: false`). The second FAIL is
  only the missing `planetId` argument. Neither of the four functions revoked by
  `20260929010000` is used by either verifier.

### Credential hygiene note (2026-09-29)

Two credentials were supplied interactively. Both were used **read-only**, and neither reached the
repository or the client bundle.

| credential | kind | scope | containment |
|---|---|---|---|
| `sb_secret_…` | service / DB key, RLS-bypassing | this one database | byte-identical to the key already in `.env.local`; `.env.local` is covered by `.gitignore` line 33 (`.env*`); **0 tracked files** contain an `sb_secret_` token; `src/` reads no non-`VITE_` env var and holds no literal secret |
| `sbp_…` | Supabase **personal access token** | **account-level management API** — arbitrary SQL, secret read/rotate, and every project on the account | **0 tracked files**; not present in `.env.local`; never given a `VITE_` prefix (Vite inlines `VITE_` vars into the shipped bundle, so a PAT under one would be catastrophic) |

The publishable key supplied alongside them is byte-identical to the existing
`VITE_SUPABASE_PUBLISHABLE_KEY` and is by design safe to bundle.

The PAT was used for exactly one read-only purpose: making the migration ledger directly readable,
which closed the blocker described in [`MIGRATION_DRIFT_RECONCILIATION.md`](../MIGRATION_DRIFT_RECONCILIATION.md).
It was **not** used to mint a user session or impersonate a player, because that would convert a
privileged fixture into false player certification. `supabase db push`, `supabase migration repair`,
key rotation and env-var updates were **not** run: the first two are forbidden by the drift mission's own
terms, and the latter two would be unreviewed production mutations.

**Both credentials are now in the session transcript and should both be rotated.** The PAT first: it is
the broader of the two. Note that the Supabase CLI (v2.117.0) rejects this PAT with *"Invalid access
token format"* because the token's length does not match the CLI's expected pattern, while the
management API itself accepts it — so `supabase gen types` / `supabase projects list` remain unusable
from here even with a valid token, and the ledger had to be read over plain SQL instead.

Browser certification remains environment-blocked (no driver plus a human DEV credential) and was not
simulated.


The existing beginner-protection contract was measured LIVE before changing it: the ATTACK insert trigger already called get_player_attack_protection(), but that function intentionally returned NOT_HUMAN_TARGET for AI players. The approved project rule is to reuse the existing human 24-hour beginner protection for AI targets. Migration 20260928032301_extend_beginner_protection_to_ai_targets now applies the same 24-hour created_at window to both human and AI targets. Post-change LIVE verification: 33 AI players are currently protected, 592 are outside the 24-hour window, and the human protection path remains unchanged. All 625 AI profiles remain DORMANT; no activation was performed.
