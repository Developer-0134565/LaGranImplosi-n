# IDENTITY & ACCESS — LA GRAN IMPLOSIÓN

Living document for the identity chain (session → player → planet → resources) and the ownership
model that protects player data.

Status (2026-09-18): ownership hardening **CLOSED / verified** — migration `20260918030000` applied to
Supabase LIVE in a single transaction and confirmed with `pg_get_functiondef` (no guest bypass in the six
RPCs, `SECURITY DEFINER` and `search_path` preserved, ownership check intact, migration recorded in
`supabase_migrations.schema_migrations`). Frontend identity chain **CLOSED / verified**; buildings
lifecycle test **CLOSED / verified** (13/13 PASS after the hardening, no residue).

Status (2026-09-21) — **the DEV identity is now the email account; LIVE, verified read-only after the
fact.** The migration was applied in LIVE as ledger version
`20260921073405_complete_email_identity_migration` (recovered verbatim in this repository as
`supabase/migrations/20260921073405_complete_email_identity_migration.sql`). It created
`public.provision_player(text,text)`, dropped the `on_auth_user_created` trigger with
`private.handle_new_auth_user()`, and dropped `public.register_guest_player`. The three local files that
carried those same end states under their own versions (`20260920120000`, `20260920120100`,
`20260920120200`) are preserved as `*.sql.superseded` (byte-identical bodies, never deleted).

## LIVE identity state — 2026-09-21 (measured)

```text
auth.users                      1    (the DEV email only; 0 anonymous)
players                         371  (370 AI with user_id NULL, 1 HUMAN)
DEV auth user                   eab54987-af3a-4dba-bb7a-9530b64798b6   cruz1993gonzalez@outlook.com
DEV player                      aa1deb2d-3ed6-4350-922a-172d999b2af7   DevPlayer
                                player_type HUMAN · is_guest FALSE · user_id = the DEV email
DEV homeworld                   f35bd4b9-f78f-4be0-968e-09acf4ffaeed   G1-S1-P1 · fields_total 163
players owned by the DEV        1    (no second player, no duplicate ownership)
old anonymous owner             154df03b-c7db-46b2-9c49-2f33df5b5236   DELETED
former AI claim (AI-G1-S1-P2)   released to user_id NULL (row preserved, not deleted)
```

Gameplay data preserved (measured): planet 1 · planet_resources 1 · player_research 3 · building_queue 3 ·
research_queue 5 · shipyard_queue 1 · planet_buildings 2 · planet_ships 1. Resources are live-simulated.

**Authenticated test (rolled back, no residue).** With `role authenticated` and
`request.jwt.claims = {"sub":"eab54987-af3a-4dba-bb7a-9530b64798b6","role":"authenticated"}`:
`auth.uid()` resolved to the DEV email; `players where user_id = auth.uid()` → `DevPlayer`;
1 planet / 1 resource row / 3 research rows readable; `provision_player('ZZ-ShouldNotCreate','XX')`
returned the existing player and the player count stayed **371 → 371** (no second empire created).

### OPEN regression — the owner cannot read three of its own tables

Six tables carry **only** a `*_select_guest` policy (`pl.is_guest = true`): `planet_buildings`,
`planet_defenses`, `planet_ships`, `shipyard_queue`, `fleet_movements`, `fleet_movement_ships`. With the
DEV player now `is_guest = false`, the owner session reads:

| table | rows in DB | visible to owner |
|---|---|---|
| `planets` | 1 | 1 |
| `planet_resources` | 1 | 1 |
| `player_research` | 3 | 3 |
| `building_queue` | 3 | 3 |
| `research_queue` | 5 | 5 |
| `planet_buildings` | 2 | **0** |
| `planet_ships` | 1 | **0** |
| `shipyard_queue` | 1 | **0** |

`src/App.tsx` reads all three affected tables. `20260920120400_remove_guest_rls_surface.sql` drops the six
guest policies **without** creating owner-based replacements, so applying it as-is would leave them
deny-all. The fix belongs to the guest-RLS phase and must not be improvised directly in LIVE.

### OPEN — `players_select_access` still hardcodes the DEV UUID

The policy keeps `id = 'aa1deb2d-3ed6-4350-922a-172d999b2af7'` plus the `is_guest` branch. Verified with a
stranger session (`sub = 00000000-0000-4000-8000-000000000000`): the DevPlayer row **is** readable
(1 row), while its `planet_resources` are not (0 rows). Rebase on `players.user_id = auth.uid()` as a
follow-up.

## Canonical onboarding (email/password) — 2026-09-20

```text
CANONICAL
  email/password (src/LoginPage.tsx, Supabase Auth UI)
      -> auth.uid()                        (src/lib/identity.ts currentAuthUserId)
      -> players.user_id = auth.uid()      (resolvePlayer)
      -> if no player: EXPLICIT onboarding step (never automatic creation)
      -> public.provision_player(p_username, p_country_code)
      -> own HUMAN player + Homeworld + planet_resources(500/500/0/0) + player_research
```

Repository changes applied forward-only (no history rewritten):

| Object | Change |
|---|---|
| `public.provision_player(text, text)` | **NEW** — SECURITY DEFINER, `search_path = ''`, requires `auth.uid()` (`AUTHENTICATION_REQUIRED`), reuse-first/idempotent, **never claims or adopts an existing player**; creates player + Homeworld + resources + research in one transaction; does not write `is_guest` |
| `on_auth_user_created` + `private.handle_new_auth_user()` | **DROPPED** — the claim-the-oldest-unclaimed-player onboarding no longer exists |
| `public.register_guest_player(text,text,text)` | **DROPPED** — no frontend caller remains |
| guest authorization branches | removed from `start_fleet_mixed`, `start_colonize_fleet`, `start_lifeform_building`, `start_lifeform_research`, the dead `v_is_guest` residue of `sync_current_planet_resources`, and the NULL-auth fallback of `enforce_player_write_access` |
| guest RLS | 12 `*_select_guest` policies dropped; `players_select_access`, `planet_resources_select_access`, `building_queue_select_access`, `player_research_select_access`, `research_queue_select_access` recreated without the guest branch; `defense_queue_owner_read` rebased on ownership |
| frontend | `src/main.tsx` no longer bootstraps an anonymous session; `src/lib/identity.ts` no longer creates sessions/players; explicit onboarding panel `src/OnboardingPanel.tsx` (username → `provision_player`) |
| test fixtures | `supabase/tests/buildings_lifecycle.sql` / `research_lifecycle.sql` select a HUMAN player with `user_id` (no guest predicate, no DevPlayer fixture) |

Migrations (forward-only): `20260920120000_create_explicit_player_provisioning`,
`20260920120100_retire_auth_player_claim_trigger`, `20260920120200_retire_register_guest_player`,
`20260920120300_remove_guest_authorization_branches` (**SUPERSEDED** — see below),
`20260920120400_remove_guest_rls_surface`,
`20260920120500_harden_ui_defense_queue_ownership`,
`20260920120600_harden_building_analysis_function_acl`,
`20260920120700_enable_rls_on_internal_engine_tables`,
`20260920120800_remove_guest_ownership_bypasses`.

### Superseded patcher — 2026-09-20

`20260920120300_remove_guest_authorization_branches.sql` **cannot execute against LIVE** and is preserved as
`20260920120300_remove_guest_authorization_branches.sql.superseded` (provenance, never deleted).

Its patch 1 (`start_fleet_mixed`) and patch 2 (`start_colonize_fleet`) require the literal fragment
`v_auth_user IS NULL AND NOT EXISTS`, but the real LIVE shape is
`IF v_auth_user IS NOT NULL THEN … ELSIF NOT EXISTS(…)`. The precondition never matches, so the `DO` block
raises `PRECONDITION_FAILED` and the whole migration rolls back. Patches 3, 4 and 5 matched LIVE verbatim and
are carried over unchanged into `20260920120800_remove_guest_ownership_bypasses.sql`, which additionally
covers `start_fleet` (a guest fallback no prepared migration addressed).

Still **LIVE-pending** (not decidable from the repository alone, all verified read-only against LIVE on
2026-09-20 — see `docs/audits/LIVE_INTEGRITY_RECONCILIATION_2026-09-20.md`):

- `players.is_guest` column removal — kept until every LIVE consumer is verified; `reconcile_universe_ai_population`
  (`md5 5c821afdcd884670eb8a75eecb0d307d`) **still writes** the column, so the drop is blocked by a write
  dependency, not by a read;
- `public.initialize_player_research(uuid)` — **VERIFIED LIVE / REUSABLE** (this closes the former
  `LIVE-ONLY / VERIFY REQUIRED` item): `SECURITY INVOKER`, `search_path = 'public, pg_temp'`, ACL
  `{postgres, service_role}`, body is an idempotent `INSERT … WHERE NOT EXISTS` over `research_definitions`.
  It is callable from `provision_player` because that function is `SECURITY DEFINER` owned by `postgres`;
- `early_tester_registrations` and `player_achievements` — both **0 rows**; their only writer was the retired
  guest RPC, `early_tester_registrations` has 0 policies and 0 grants (inert) and `player_achievements` has one
  owner-read policy. Retention or retirement is a product decision (tables intentionally kept);
- `src/lib/database.types.ts` regeneration — only after LIVE reconciliation. Measured drift: 31 LIVE functions
  are undeclared and 6 declared functions (`calculate_fleet_fuel`, `calculate_fleet_time`,
  `calculate_fleet_fuel_mixed`, `calculate_fleet_fuel_for_distance`, `calculate_expedition_time`,
  `get_player_fleet_speed_multiplier`) no longer exist in LIVE — they are the legacy fleet cluster retired by
  `20260919042419`;
- guest history (`20260913012900`, `20260913014116`, `20260915210651`, the trigger migration, etc.) remains as
  **provenance only**.



## Historical — Guest residue inventory (2026-09-20, superseded by the canonical section above)

```text
PRODUCT DECISION : Guest is NOT a product feature; the intended entry is registration / login (email).
DOC STATE        : Guest onboarding is SUPERSEDED as product behaviour but is still WIRED in code.
LIVE             : UNKNOWN from the repository. This section records LOCAL evidence only.
```

Local residue inventory (read-only audit, 2026-09-20):

| Piece | Where | Classification |
|---|---|---|
| anonymous session bootstrap | `src/main.tsx` (`ensureSession()`; `LoginPage` only if it fails) | LEGACY GUEST — **ACTIVE** (blocks removal) |
| `signInAnonymously()` | `src/lib/identity.ts` `ensureSession()` | LEGACY GUEST — **ACTIVE** |
| `register_guest_player` fallback | `src/lib/identity.ts` `resolveIdentity()`; RPC `20260915210651` | LEGACY GUEST — **ACTIVE** |
| `visitorId()` / `guestUsername()` | `src/lib/identity.ts` | LEGACY GUEST — ACTIVE (used only by the guest path) |
| `players.is_guest` column | consumed by `enforce_player_write_access`, the guest RLS read policies, `register_guest_player`, `reconcile_universe_ai_population` | LEGACY BUT REQUIRED (schema-side; needs a forward LIVE migration) |
| guest fallback inside authorisation guards | `start_fleet_mixed`, `start_colonize_fleet`, `start_lifeform_building`, `start_lifeform_research` (NULL `auth.uid()` + `coalesce(is_guest,false)`) and `enforce_player_write_access` | **OPEN FINDING** — legacy authorisation branch still present in current bodies (report-only) |
| guest RLS read policies | `*_select_guest` (12) plus `*_select_access` variants that mention `is_guest` | LEGACY GUEST — ACTIVE (LIVE-side) |
| `auth.users` onboarding trigger | `private.handle_new_auth_user` (`20260913012344`; reassigns the oldest unclaimed player) | LEGACY ONBOARDING (confirmed in LIVE by a separate audit) |
| guest-coupled test fixtures | `supabase/tests/buildings_lifecycle.sql:36`, `supabase/tests/research_lifecycle.sql:85` | TEST-ONLY (fixture) — NEEDS REPLACEMENT |
| email/password login | `src/LoginPage.tsx` (Supabase Auth UI, `providers={[]}`) | CANONICAL CURRENT — preserve |
| modern ownership chain | `resolvePlayer()` → `players.user_id = auth.uid()` | CANONICAL CURRENT — preserve |

Removed locally on 2026-09-20 (no runtime/ownership/RLS/migration change): the unused `is_guest` field in
the frontend data contracts (`App.tsx`, `GalaxyView.tsx`, `identity.ts` selects/types) and the
guest-locking assertion in `scripts/verify-identity.mjs` (now an informational note).

LIVE cleanup (onboarding trigger, guest RLS policies, guest branches inside the guards) remains
**PENDING** and requires a separate forward migration plus live reconciliation.

Note: the historical row further below recording "Migration state via `pg_get_functiondef` … NOT applied"
is a 2026-09-18 snapshot; the guest branches it mentions are still present in the audited local chain.

## Canonical chain

```text
Browser session (Supabase Auth, anonymous for guests)
   ↓  supabase.auth.getSession() / auth.getUser()
auth.uid()
   ↓  players.user_id = auth.uid()
players.id
   ↓  planets.player_id = players.id
activePlanet.id            (deterministic: is_homeworld first, then galaxy/system/position)
   ↓  planet_resources.planet_id = activePlanet.id
resources
```

Any selection based on "first available planet", "first guest", "first global homeworld" or on a
client-provided player UUID is **invalid** and must not be reintroduced.

## Frontend

| File | Role |
|---|---|
| `src/lib/identity.ts` | `ensureSession()` (reuses the persisted session or creates an **anonymous** one), `currentAuthUserId()` (`auth.getUser()`), `resolvePlayer()` (`players.user_id = auth.uid()`), `resolveIdentity()` (registers the guest via `register_guest_player` when the session has no player yet), stable visitor id (≥32 chars, required by the RPC), generated guest username (`Invitado-<hex8>`) |
| `src/main.tsx` | Guarantees a session before rendering the app; only if the anonymous sign-in fails does it fall back to `LoginPage` (with the error shown) |
| `src/App.tsx` | Resolves the identity **before** loading data and then queries `planets` with `.eq('player_id', identity.id)`; `currentPlayer` comes from the resolved player, never from the planet relation |

Guest onboarding contract of `public.register_guest_player(p_username, p_country_code, p_ip_hash)`
(SECURITY DEFINER, granted to `authenticated`):

- requires an **anonymous** JWT (`auth.jwt() ->> 'is_anonymous'`), otherwise `ANONYMOUS_AUTH_REQUIRED`;
- username 3-24 chars, `[[:alnum:] _.-]`, `devplayer` reserved; `p_ip_hash` ≥ 32 chars;
- idempotent: if a player already exists for `auth.uid()` it returns that player and its homeworld;
- creates player (`is_guest = true`, `player_type = 'HUMAN'`), homeworld `Homeworld` in the first free
  slot of the active universe, `planet_resources` (500/500/0/0), initial research and the early-tester
  registration.

## Backend ownership (RPC layer)

All writes to `players`, `planets`, `planet_resources` and the queues go through `SECURITY DEFINER`
functions (those tables have **no** INSERT/UPDATE/DELETE policies), so ownership must be enforced
inside the RPCs.

Findings (audit 2026-09-18): several RPCs accepted an arbitrary `p_player_id` when `auth.uid()` was
NULL, as long as the target player had `is_guest = true`, which allowed operating on **another
guest's** planet.

Applied migration: `supabase/migrations/20260918030000_harden_player_ownership_in_owned_rpcs.sql`
(**applied 2026-09-18** in one transaction; recorded in `supabase_migrations.schema_migrations`).
Minimum change: the guest bypass branch is replaced by an explicit rejection; the existing
`players.user_id = auth.uid()` check is preserved. Functions updated:

```text
start_building · start_research · start_ship · start_defense · start_fleet · sync_current_planet_resources
```

Bodies were extracted from the live definition (`backup/supabase/schema.sql`) and patched
programmatically; the only difference in each function is the guard.

Still pending in a later security phase (not used by the current frontend):
`start_lifeform_building`, `start_lifeform_research`, `start_colonize_fleet`, `start_fleet_mixed`,
`use_expedition_item` and the write trigger `enforce_player_write_access`.

### Post-application verification (live, 2026-09-18)

```text
pg_get_functiondef   → bypass removed in the six functions; `if v_auth_user is null then raise exception
                       'Authentication required'` present; ownership check `pl.user_id = v_auth_user`
                       intact; `prosecdef = true`; `proconfig = search_path=public, pg_temp`
Legitimate owner     → ALLOWED  (start_building with auth.uid() = players.user_id; queue created)
Foreign owner        → REJECTED ('Player does not belong to authenticated user'; no state change)
auth.uid() NULL      → REJECTED ('Authentication required'; no state change)
Buildings lifecycle  → 13/13 PASS (transactional, no residue) after the hardening
Identity script      → PASS (13 PASS · 1 SKIP session-dependent · 0 FAIL)
```

## RLS model (audited)

| Table | Policies | Grants | Notes |
|---|---|---|---|
| `players` | SELECT only: own `user_id = auth.uid()`, `player_type = 'AI'`, DevPlayer, or guest-with-`user_id` | SELECT to `anon`/`authenticated` | Needed by the galaxy map (owner names) |
| `planets` | SELECT only: `is_destroyed = false` | SELECT to `anon`/`authenticated` | **Intentionally public**: the galaxy view must show foreign planets in a system; identity no longer depends on this list |
| `planet_resources` | SELECT only: own planets (`players.user_id = auth.uid()`) or DevPlayer | SELECT to `anon`/`authenticated` | Foreign resources are not readable (AI planets return `null`) |

No RLS change was made: the identity fix belongs to the frontend selection and the RPC ownership
checks, and tightening `planets` would break the galaxy map. Table-level insertion by clients is
impossible (no INSERT policies), which also makes the trigger guest branch unreachable from outside.

Unrelated observation (security phase): `public.universes` has a public RLS policy but no table
`GRANT SELECT`, so `calculate_universe_rates()` / `calculate_planet_production()` /
`calculate_building_time()` are not callable from clients.

## Tests

```bash
node scripts/verify-identity.mjs    # cadena de identidad + invariantes (solo lectura, no crea datos)
node scripts/verify-buildings.mjs   # regresión del dominio de edificios (solo lectura)
# supabase/tests/buildings_lifecycle.sql → transaccional (BEGIN … ROLLBACK), no deja residuo
```

`supabase/tests/buildings_lifecycle.sql` simulates the frontend anonymous session with
`set_config('request.jwt.claims', ...)` so it exercises the same ownership contract, and includes a
negative assertion: a session that does not own the player is rejected.

### How to execute SQL from the project (verified method)

The project has the Supabase MCP server configured in `.vscode/mcp.json` (`execute_sql` tool with the
project ref derived from `VITE_SUPABASE_URL`). Run the test by passing the whole file as a single
query; the explicit `BEGIN … ROLLBACK` is honoured and nothing is persisted.

### Verified results (2026-09-18, live project)

| Check | Result |
|---|---|
| `supabase/tests/buildings_lifecycle.sql` (13 assertions, incl. ownership) | **13/13 PASS**, no exception from the `BUILDINGS TEST FAILED` gate |
| Residue after the test | none: identical before/after snapshots of the test planet (levels, resources, queue rows, fields_used) |
| `scripts/verify-identity.mjs` | PASS (13 PASS · 1 SKIP session-dependent · 0 FAIL) |
| `scripts/verify-buildings.mjs` | PASS |
| `npx tsc -b` · `npm run build` | PASS |
| Migration state via `pg_get_functiondef` | **NOT applied** (guest bypass still present in the 5 `start_*`) |

Once the ownership migration is applied, the same test must be re-run: the claim simulation is what
lets it pass with the hardened RPCs.

## Live data (2026-09-18, RLS-visible subset)

- 1 human guest (`DevPlayer`, `is_guest = true`, `user_id` set) with 1 homeworld.
- 197 AI players; 235 planets (231 homeworlds) across 2 universes; no planet without `player_id`;
  no player with more than one homeworld.
- Identity-relevant anomalies: one AI row has `is_guest = true` with `user_id = NULL` (not an
  identity player; readable only through the AI clause) — data cleanup belongs to a later mission.
