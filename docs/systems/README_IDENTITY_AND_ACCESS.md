# IDENTITY & ACCESS — LA GRAN IMPLOSIÓN

Living document for the identity chain (session → player → planet → resources) and the ownership
model that protects player data.

Status (2026-09-18): ownership hardening **CLOSED / verified** — migration `20260918030000` applied to
Supabase LIVE in a single transaction and confirmed with `pg_get_functiondef` (no guest bypass in the six
RPCs, `SECURITY DEFINER` and `search_path` preserved, ownership check intact, migration recorded in
`supabase_migrations.schema_migrations`). Frontend identity chain **CLOSED / verified**; buildings
lifecycle test **CLOSED / verified** (13/13 PASS after the hardening, no residue).

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
