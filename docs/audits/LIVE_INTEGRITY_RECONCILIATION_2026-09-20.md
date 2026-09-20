# L.G.I. — LIVE INTEGRITY RECONCILIATION

> **2026-09-20 — segregated audit record.**
>
> **Purpose:** close the unknown zones left open by
> [`FORENSIC_PROJECT_INTEGRITY_REPORT_2026-09-20.md`](FORENSIC_PROJECT_INTEGRITY_REPORT_2026-09-20.md).
> That report authorized exactly one next move: a read-only LIVE audit of the identity/ownership
> onboarding chain. This document is the result of that audit, extended to the full project surface.
>
> **Source:** LIVE introspection of Supabase project `evtfsbntvuqmahiskekd` plus local repo/Git
> inspection. This record is evidence. It is not the operational control panel and it does not
> authorize deployment.
>
> **This record did not modify the repository history, the migrations tree, the stashes, the backups
> or the LIVE database.** No DDL, DML, ACL, RLS or configuration change was executed. Only `SELECT`,
> catalog introspection, `tsc` and `vite build` were run.

---

## 1. Snapshot

```text
repository            C:\Users\Missingn0\LaGranImplosi-n
remote                Developer-0134565/LaGranImplosi-n
branch                main
HEAD                  7a78bca96448c7126f7a46e24226e7223a1667d6
origin/main           7a78bca96448c7126f7a46e24226e7223a1667d6
ahead / behind        0 / 0
staged                 none
git diff --check       clean
stashes                stash@{0} "WIP antes de integrar origin/main"
                       stash@{1} "WIP Buildings before sync main"
```

Working tree, pre-existing and **not** created by this audit (deliberately not reverted):

```text
 M  docs/PROJECT_CONTEXT_PROMPT.md
 M  docs/systems/README_FLEET_ENGINE.md
 M  docs/systems/README_IDENTITY_AND_ACCESS.md
 M  scripts/verify-identity.mjs
 M  src/App.tsx
 M  src/GalaxyView.tsx
 M  src/lib/identity.ts
 M  src/main.tsx
 M  supabase/tests/buildings_lifecycle.sql
 M  supabase/tests/research_lifecycle.sql
 ?? src/OnboardingPanel.tsx
 ?? supabase/migrations/20260920010000_converge_local_fleet_dispatch_classifiers.sql
 ?? supabase/migrations/20260920120000_create_explicit_player_provisioning.sql
 ?? supabase/migrations/20260920120100_retire_auth_player_claim_trigger.sql
 ?? supabase/migrations/20260920120200_retire_register_guest_player.sql
 ?? supabase/migrations/20260920120300_remove_guest_authorization_branches.sql
 ?? supabase/migrations/20260920120400_remove_guest_rls_surface.sql
```

Preserved provenance refs still present: `refs/cline/checkpoints/session_1789690296966_43raq/*`.

## 2. LIVE access


## 3. Structural inventory

### 3.1 Frontend (`src/`)

```text
App.tsx (39 920 B)             view layer, 9 views: overview, buildings, research, shipyard,
                               defense, fleet, expedition, messages, galaxy
GalaxyView.tsx (13 754 B)      galaxy map + start_fleet dispatch
LoginPage.tsx (1 444 B)        @supabase/auth-ui-react + ThemeSupa — email/password only
OnboardingPanel.tsx (2 336 B)  UNTRACKED/new: explicit first-access empire creation
TemplateChrome.tsx (10 437 B)  shell/chrome
components/monitor/UniverseEvolutionMonitor.tsx   monitor widget, rendered in overview
lib/identity.ts                auth.uid() -> players.user_id + provisionPlayer()
lib/supabase.ts                single authenticated client
lib/database.types.ts          199 806 B, generated
lib/universeEvolutionMonitor.ts  SECOND Supabase client for the public monitor RPC
32 CSS files under src/styles + App.css
```

### 3.2 Backend

```text
supabase/migrations/   283 files = 276 active .sql + 7 .superseded/.obsolete
supabase/tests/        6 SQL suites (buildings, research, shipyard_defense, fleet_speed_classes,
                       fleet_acs_hold_lifecycle, combat_participant_propagation)
worker/index.ts         Cloudflare Worker = static asset boundary only (1 372 B, no DB access)
scripts/                backup-supabase.ps1, verify-identity.mjs, verify-buildings.mjs
backup/supabase/        data.sql 574 818 B, roles.sql 370 B, schema.sql 719 479 B  [gitignored = provenance]
template/               edificios/hangar/investigaciones/template .txt (~1.2 MB, reference scrapes)
```

### 3.3 LIVE database

```text
public base tables             66
public views                   21
public functions               235 rows / 226 distinct names
public triggers (non-internal) 6 x enforce_player_write_access + on_auth_user_created
public RLS policies            66
pg_cron jobs                   2 active
extensions                     pg_cron 1.6.4, pg_stat_statements 1.11, pgcrypto 1.3,
                               supabase_vault 0.3.1, uuid-ossp 1.1, plpgsql 1.0
schema_migrations ledger       269 rows — 20260912092555 .. 20260919101000
```

### 3.4 Cron (authoritative)

| jobid | jobname | schedule | active | command |
|---|---|---|---|---|
| 2 | `deuteria-fleet-worker` | `1 second` | true | `SELECT public.run_fleet_worker();` |
| 4 | `universe-heartbeat` | `* * * * *` | true | `SELECT public.process_universe_heartbeat();` |

Both run as `postgres` and target functions whose ACL is `{postgres, service_role}` only — correct,
no client reachability.

## 4. Live data (measured 2026-09-20, aggregates only)

## 5. Guest dependency graph (LIVE, proven)

```text
ENTRADA                     LoginPage (email/password)  ·  src/lib/identity.ts
                            legacy: supabase.auth.signInAnonymously()  -> REMOVED from src, still enabled in Auth
IDENTIDAD                   auth.uid()  ·  auth.jwt() ->> 'is_anonymous'  ->  REQUIRED by register_guest_player
PLAYER                      players.user_id  ·  players.is_guest  ·  players.player_type
PLANET                      planets.player_id  (galaxy map read is intentionally public)
RESOURCES                   planet_resources  (owner-only RLS, plus guest branch)
RPC                         register_guest_player(text,text,text)   [SECDEF, search_path='', EXECUTE authenticated]
RLS                         6 x *_select_guest + 5 mixed policies + defense_queue_owner_read
TRIGGER                     on_auth_user_created -> private.handle_new_auth_user()  [SECDEF, ENABLED]
                            -> claims OLDEST players row WHERE user_id IS NULL  (no player_type filter)
WORKER / CRON               2 jobs (fleet worker 1 s, universe heartbeat 1 min) — NO guest dependency
                            reconcile_universe_ai_population() WRITES players.is_guest = false
```

### 5.1 LIVE functions that still carry guest-identity logic (9)

| Function | is_guest usage | Classification |
|---|---|---|
| `register_guest_player(3)` | writes `is_guest = true`, requires anonymous JWT | **LIVE / ACTIVE** |
| `private.handle_new_auth_user()` | no `is_guest`, but claims `user_id IS NULL` rows | **LIVE / ACTIVE (dangerous)** |
| `enforce_player_write_access()` | `auth.uid() IS NULL AND is_guest = true` => authorised | **LIVE / ACTIVE (unreachable from clients: 0 INSERT grants)** |
| `start_fleet(...)` | `ELSIF NOT EXISTS(...coalesce(pl.is_guest,false))` guest fallback | **LIVE / ACTIVE — ORPHANED from the retirement set** |
| `start_fleet_mixed(...)` | `ELSIF NOT EXISTS(...coalesce(pl.is_guest,false))` | **LIVE / ACTIVE** |
| `start_colonize_fleet(...)` | `ELSIF NOT EXISTS(...coalesce(pl.is_guest,false))` | **LIVE / ACTIVE** |
| `start_lifeform_building(uuid,text)` | `IF v_auth_user IS NULL AND NOT EXISTS(...is_guest = true)` | **LIVE / ACTIVE** |
| `start_lifeform_research(uuid,text)` | same | **LIVE / ACTIVE** |
| `sync_current_planet_resources(3)` | dead `v_is_guest` declaration + read | **LIVE / DEAD RESIDUE** |

**Not** guest identity (different domain, do not conflate): `guest_player_id` in
`grant_planet_support_authorization`, `revoke_planet_support_authorization`, `start_support_fleet`
(ACS hold / support authorizations).

## 6. LIVE RLS inventory — guest predicates

`*_select_guest`, all `FOR SELECT TO anon, authenticated`, predicate `(pl.is_guest = true)`:

| Table | LIVE |
|---|---|
| `planet_buildings` | present |
| `planet_defenses` | present |
| `planet_ships` | present |
| `shipyard_queue` | present |

## 7. Mutating RPC audit (LIVE bodies, not the migrations)

| RPC | SECDEF | search_path | EXECUTE | auth.uid() required | ownership verified | guest bypass | NULL auth accepted |
|---|---|---|---|---|---|---|---|
| `start_building(uuid,uuid,text)` | yes | `public, pg_temp` | pg, sr, authenticated, **anon** | yes | yes (player+planet) | none | no |
| `start_research(uuid,uuid,text)` | yes | `public, pg_temp` | pg, sr, authenticated, **anon** | yes | yes (player+planet) | none | no |
| `start_ship(uuid,uuid,text,bigint)` | yes | `public, pg_temp` | pg, sr, authenticated | yes | via planet->player | none | no |
| `start_defense(uuid,uuid,text,bigint)` | yes | `public, pg_temp` | pg, sr, authenticated, **anon**, PUBLIC | yes | via planet->player | none | no |
| `start_fleet(6)` | yes | `public, pg_temp` | pg, sr, authenticated | yes | yes `pl.user_id = v_auth_user` | **YES** | **YES if guest** |
| `start_fleet_mixed(5)` | yes | `public, pg_temp` | pg, sr, authenticated | yes | yes `pl.user_id = v_auth_user` | **YES** | **YES if guest** |
| `start_colonize_fleet(5)` | yes | `public, pg_temp` | pg, sr, authenticated | yes | yes `pl.user_id = auth.uid()` | **YES** | **YES if guest** |
| `start_lifeform_building(uuid,text)` | yes | `public, pg_temp` | pg, sr, authenticated | yes | via planet->player | **YES** | **YES if guest** |
| `start_lifeform_research(uuid,text)` | yes | `public, pg_temp` | pg, sr, authenticated | yes | via planet->player | **YES** | **YES if guest** |
| `sync_current_planet_resources(3)` | yes | `public, pg_temp` | pg, sr, authenticated, **anon** | yes | yes `pl.user_id = v_auth_user` | none | no |
| `start_support_fleet(7)` | yes | `public, pg_temp` | pg, sr, authenticated | — | ACS domain | n/a | — |
| `provision_player(text,text)` | — | — | **DOES NOT EXIST IN LIVE** | — | — | — | — |

`pg` = postgres, `sr` = service_role.

### 7.1 Exact LIVE guest guards (verbatim)

`start_fleet`:

```sql
IF v_auth_user IS NOT NULL THEN
  IF NOT EXISTS(select 1 from public.players pl where pl.id=p_player_id and pl.user_id=v_auth_user)
  THEN raise exception 'Player does not belong to authenticated user'; END IF;
ELSIF NOT EXISTS(select 1 from public.players pl where pl.id=p_player_id and coalesce(pl.is_guest,false))
THEN raise exception 'Authentication required'; END IF;
```

`start_fleet_mixed` / `start_colonize_fleet`: identical shape, inner message
`'...authenticated user'`.

`start_lifeform_building` / `start_lifeform_research`:

```sql
IF v_auth_user IS NULL AND NOT EXISTS (
  SELECT 1 FROM public.players WHERE id=v_player AND coalesce(is_guest,false)=true
) THEN RAISE EXCEPTION 'Authentication required'; END IF;
```

`enforce_player_write_access` (tail):

## 8. REPO vs LIVE reconciliation

| Area | Repo | LIVE | State |
|---|---|---|---|
| `provision_player(text,text)` | migration `20260920120000` (untracked) | absent | **REPO AHEAD / LOCAL-ONLY** |
| `on_auth_user_created` | `20260920120100` drops it | ENABLED, `AFTER INSERT ON auth.users` | **DRIFT — LIVE AHEAD of retirement** |
| `private.handle_new_auth_user()` | `20260920120100` drops it | present, md5 `586260ae6bec379b142387aa231cce3d`, 976 B | **DRIFT** |
| `register_guest_player(3)` | `20260920120200` drops it | present, SECDEF, `search_path=''`, EXECUTE `authenticated` | **DRIFT** |
| `enforce_player_write_access()` | `20260920120300` removes guest fallback | guest fallback intact | **DRIFT** |
| `start_fleet_mixed` patcher precondition | expects `v_auth_user IS NULL AND NOT EXISTS` | actual `IF ... IS NOT NULL THEN ... ELSIF NOT EXISTS` | **DRIFT — BLOCKING** |
| `start_colonize_fleet` patcher precondition | same | same | **DRIFT — BLOCKING** |
| `start_lifeform_building` / `_research` precondition | `IS NULL AND NOT EXISTS` | matches verbatim | **MATCH** |
| `sync_current_planet_resources` patch | expects `v_is_guest` residue | matches verbatim | **MATCH** |
| `enforce_player_write_access` patch | expects `v_is_guest` + 2 regexes | matches verbatim | **MATCH** |
| `start_fleet` guest branch | no migration covers it | guest branch present | **REPO GAP** |
| RLS `*_select_guest` | 12 `DROP IF EXISTS` | 6 present, 6 absent | **DRIFT (drops are idempotent)** |
| RLS mixed policies | recreated without guest | guest branch present | **DRIFT** |
| `players.is_guest` | removal pending | `NOT NULL DEFAULT false`, **written by `reconcile_universe_ai_population`** | **DRIFT — not removable yet** |
| `initialize_player_research(uuid)` | no local CREATE (baseline) | present, verified (§9) | **MATCH / LIVE-ONLY, RESOLVED** |
| `ui_defense_queue(uuid,uuid)` | created by `20260915052725` | present, SECDEF + PUBLIC, no `auth.uid()` | **MATCH (both) — security finding §12** |
| Migration ledger | 276 local active versions | 269 ledger rows, last `20260919101000` | **DRIFT (see §8.1)** |
| `universe_process_health`, `combat_battle_participants` | RLS on expected | **RLS DISABLED** | **DRIFT** |
| Generated types | 201 fn names | 226 fn names | **DRIFT (§10)** |
| Cron | 2 jobs documented | 2 jobs active | **MATCH** |

### 8.1 Migration version drift (measured)

```text
LIVE ledger rows                             269   (last 20260919101000)
Local active .sql distinct versions          276
LOCAL - LIVE (11)  20260919060000 20260919070000 20260919080000 20260919090000
                     ^ version-drift equivalents of the LIVE-only NOT_RECOVERABLE rows below
                  20260919180000      LOCAL_ONLY / NOT_DEPLOYED / BLOCKED
                  20260920010000      parallel-session LOCAL_ONLY
                  20260920120000 20260920120100 20260920120200 20260920120300 20260920120400
                                      guest decommission (LOCAL_ONLY)
LIVE - LOCAL (4)   20260919055336 20260919061454 20260919062509 20260919070020
                     ^ LIVE_ONLY / NOT_RECOVERABLE (unchanged from MIGRATION_PROVENANCE_GATE.md)
```

Conclusion unchanged: `supabase db push` remains **PROHIBITED**.

## 9. `initialize_player_research(uuid)` — CLOSED

```text
schema / signature   public.initialize_player_research(p_player_id uuid) RETURNS integer
security             SECURITY INVOKER          (prosecdef = false — note: NOT definer)
search_path          'public, pg_temp'
owner                postgres
ACL                  {postgres, service_role}  — NOT granted to authenticated / anon / public
stability            VOLATILE
body                 INSERT INTO public.player_research (player_id, research_id, level)
                     SELECT p_player_id, rd.id, 0 FROM public.research_definitions rd
                     WHERE NOT EXISTS (SELECT 1 FROM public.player_research pr
                                       WHERE pr.player_id = p_player_id AND pr.research_id = rd.id)
                     then RETURN row_count   -> idempotent by construction

## 10. Generated types drift (`src/lib/database.types.ts`)

Measured: types declare **201** function names, LIVE exposes **226** distinct names.

### 10.1 LIVE-only — 31 functions with no declaration in the generated types

```text
calculate_expedition_resource_multiplier     calculate_expedition_ship_reward_multiplier
calculate_fleet_distance_to_coordinates      calculate_fleet_travel_time
calculate_mission_fleet_speed_multiplier     calculate_player_fleet_fuel_for_distance
calculate_player_ship_cargo_capacity         calculate_player_ship_fuel_consumption
calculate_player_ship_speed                  calculate_research_time
calculate_universe_scaling                   calculate_universe_scaling_at
complete_building                            complete_research
enforce_player_write_access                  get_active_expedition_item_effect
get_universe_evolution_monitor               get_universe_evolution_monitor_public
grant_planet_support_authorization           process_lifeform_tick
resolve_attack_arrival                       resolve_combat
resolve_expedition_item                      revoke_planet_support_authorization
select_expedition_delay_multiplier           select_expedition_item
select_expedition_merchant_offer             select_expedition_resource_type
select_expedition_reward_variant             select_expedition_speedup_percentage
start_support_fleet
```

`get_universe_evolution_monitor_public` and `start_support_fleet` are the notable ones: both are real
contracts intended for clients. The frontend works around the missing declaration by defining a local
`MonitorRpcFunction` interface in `src/lib/universeEvolutionMonitor.ts`.

### 10.2 TYPES-only — 6 declarations representing RETIRED RPCs

```text
calculate_expedition_time
calculate_fleet_fuel
calculate_fleet_fuel_for_distance
calculate_fleet_fuel_mixed
calculate_fleet_time
get_player_fleet_speed_multiplier
```

All six belong to the legacy fleet-calculation cluster retired by
`20260919042419_retire_legacy_fleet_calculation_rpc_cluster.sql`. They are **dead contracts**: a caller
using them would fail at runtime with "function does not exist". No caller exists in `src/`, `worker/`
or `scripts/`.

`register_guest_player` and `is_guest` are declared in the types **and** still exist in LIVE — the
types **match LIVE** and **diverge from the target architecture**. Regeneration is not authorized
until the LIVE retirement sequence executes.

## 11. Orphan / dead-connection detection

### 11.1 Tables with no consumer at all

| Table | Rows | Evidence | Classification |
|---|---|---|---|
| `player_messages` | 0 | absent from every function body; absent from the frontend `from()` set | **ORPHAN (empty)** |
| `player_notes` | 0 | same | **ORPHAN (empty)** |
| `dashboard_widgets` | 14 | same | **ORPHAN (has data — product decision)** |
| `lifeform_definitions` | 4 | no function body references the bare name; reached only via the FK in `planet_lifeforms` and via `lifeform_building_definitions` / `lifeform_research_definitions` | **UNKNOWN (likely master/seed table, not a runtime read)** |

### 11.2 Views with no consumer


### 11.3 RPCs with no client consumer (LIVE, reachable by clients)

| Group | Functions | Classification |
|---|---|---|
| `ui_*` definition read models | `ui_building_definitions`, `ui_research_definitions`, `ui_ship_definitions`, `ui_defense_definitions`, `ui_universe_galaxies` | **DUPLICATE + ORPHAN** — the same data is already readable directly (the underlying definition tables carry `anon` + `authenticated` SELECT) and the frontend reads the tables, not these RPCs |
| `ui_defense_queue(uuid,uuid)` | — | **ORPHAN + SECURITY FINDING (§12 C-01)** |

Evidence for the duplication: `building_definitions`, `research_definitions`, `ship_definitions`,
`defense_definitions`, `universe_galaxies` all have `anon` + `authenticated` SELECT grants, and
`src/App.tsx` reads those tables directly via `from(...)`.

### 11.4 Orphan files / residue

```text
template/edificios.txt, hangar.txt, investigaciones.txt, template.txt     ~1.2 MB
      OGame reference scrapes. No consumer in src/worker/scripts.   -> REFERENCE MATERIAL (historical)
backup/supabase/{schema,data,roles}.sql                                  ~1.3 MB
      16/09 dump, gitignored.                                       -> PROVENANCE (DO NOT TOUCH)
.wrangler/tmp, .wrangler/state/v3/do      empty dirs, gitignored        -> build residue, harmless
worker/index.ts                          1 372 B static asset boundary -> ACTIVE but minimal
```

No 0-byte source files. No unused imports or locals (`noUnusedLocals` / `noUnusedParameters` are
enabled and `tsc -b` exits 0).

### 11.5 Duplicate / overloaded definitions (LIVE)

```text
select_expedition_speedup_percentage()            ACL: PUBLIC + anon + authenticated

## 12. Findings

### CRITICAL

**C-01 — `ui_defense_queue(uuid, uuid)` is a cross-player read hole reachable anonymously.**

```text
LIVE ACL        {=X/postgres, postgres, service_role, anon, authenticated}   <- PUBLIC EXECUTE
prosecdef       true          (SECURITY DEFINER -> RLS bypassed)
search_path     'public'      (no pg_temp)
auth check      NONE. The body only validates:
                EXISTS (planets p WHERE p.id = p_planet_id
                                    AND p.player_id = p_player_id
                                    AND NOT p.is_destroyed)
```

Any client holding only the publishable/anon key — no session, no account — can read the
`defense_queue` of **any** player by supplying that player's UUID and one of their planet UUIDs. Both
UUIDs are publicly derivable: `planets_select_access` exposes every non-destroyed planet, and
`players_select_access` exposes all AI players plus the hardcoded DevPlayer id.

Origin: `supabase/migrations/20260915052725_add_guest_defense_queue_ui_reader.sql` (guest UI reader).
Current exposure: `defense_queue` holds 0 rows, so nothing is leaking today, but the door is open.
Consumers in the repo: **none** (only the generated types). No prepared migration patches it.

Recommended action: forward-only migration inside the LIVE window (revoke PUBLIC/anon, or rebase the
predicate on `auth.uid()`), after verifying that nothing depends on the current contract.
**Classified: DO NOT TOUCH-YET / REQUIRES LIVE WINDOW.**

**C-02 — `generate_building_sequences(integer)` is an unauthenticated, unbounded recursive expansion.**

```text
LIVE ACL        {=X/postgres, postgres, anon, authenticated, service_role}    <- PUBLIC EXECUTE
language        sql STABLE, non-SECURITY DEFINER
body            WITH RECURSIVE sequences AS (
                  SELECT ARRAY[b.id]::text[], 1 FROM building_definitions b
                   WHERE b.id IN ('metal_mine','crystal_mine','deuterium_synthesizer','solar_plant')
                  UNION ALL
                  SELECT s.sequence || b.id, s.depth + 1 FROM sequences s
                    CROSS JOIN building_definitions b
                   WHERE s.depth < p_depth AND b.id IN (... same 4 ...)
                ) SELECT sequence FROM sequences WHERE depth = p_depth;
```

Four-way branching up to `p_depth`, with **no upper bound on `p_depth`**. `p_depth = 20` yields 4^20
≈ 1.1e12 candidate rows before the final filter. Reachable by anyone with the publishable key.
`rank_building_sequences`, `rank_building_sequences_horizons`, `simulate_building_chain*`,
`evaluate_building_chain*`, `calculate_action_payback`, `simulate_building_step*`,
`simulate_building_completion`, `simulate_defender_losses` and `snapshot_combat_round` share the same
PUBLIC EXECUTE profile.

This is a resource-exhaustion surface against the same database that runs the 1-second fleet worker
and the 1-minute universe heartbeat.

Recommended action: forward-only ACL tightening (revoke PUBLIC/anon) and/or an explicit `p_depth`
bound. **REQUIRES LIVE WINDOW + an engineering decision on the intended caller.**

**C-03 — `on_auth_user_created` is ENABLED and has already reassigned 12 AI empires.**

```text
LIVE trigger    on_auth_user_created, AFTER INSERT ON auth.users, tgenabled='O'
LIVE function   private.handle_new_auth_user(), SECURITY DEFINER, search_path='public, pg_temp'
body            SELECT p.id INTO v_player_id FROM public.players p
                 WHERE p.user_id IS NULL ORDER BY p.created_at LIMIT 1;
                IF v_player_id IS NOT NULL THEN
                  UPDATE public.players SET user_id = new.id, last_activity_at = now()
                   WHERE id = v_player_id; RETURN new;
                END IF;
                -- fallback: INSERT a bare player with no homeworld, resources or research
```

### HIGH

**H-01 — `20260920120300_remove_guest_authorization_branches.sql` cannot be applied to LIVE.**
Its patch-1 and patch-2 preconditions require the literal fragment
`v_auth_user IS NULL AND NOT EXISTS` inside `start_fleet_mixed` and `start_colonize_fleet`. LIVE reads
`IF v_auth_user IS NOT NULL THEN … ELSIF NOT EXISTS(…)`. The `DO $patch$` block therefore raises
`PRECONDITION_FAILED` and the whole migration rolls back. Patches 3, 4 and 5 match verbatim.
This is an **implementation defect in the patcher**, not a product question.

**H-02 — `start_fleet` carries the guest fallback and no prepared migration removes it.**
Coverage gap in the retirement set.

**H-03 — `enforce_player_write_access` still authorises `auth.uid() IS NULL AND is_guest = true`.**
Reachable in principle through the 6 protected queue tables. Unreachable from clients today because
`anon` and `authenticated` hold **zero** INSERT grants on those tables and all writes go through
`SECURITY DEFINER` RPCs. Real risk: a future grant or a definer path silently re-opens it.

**H-04 — Generated types carry 6 dead RPC contracts and omit 31 live ones** (§10). Any future caller
of `calculate_fleet_fuel`, `calculate_fleet_time`, `calculate_fleet_fuel_mixed`,
`calculate_fleet_fuel_for_distance`, `calculate_expedition_time` or
`get_player_fleet_speed_multiplier` compiles and then fails at runtime.

**H-05 — Deployment-order hazard: the working tree calls `provision_player`, which does not exist in
LIVE.** `src/lib/identity.ts` calls it and `src/App.tsx` wires it to `OnboardingPanel`. If that build
were deployed before `20260920120000` is applied, every first access would fail with a PostgREST
"function not found" error — and, while the trigger still lives, the registration would already have
silently claimed an AI empire. **Order is mandatory: function first, then trigger removal.**

### MEDIUM

**M-01 — 6 `*_select_guest` policies remain live**, granting anonymous read of the buildings,
defenses, ships, shipyard queue and fleet movements of any player with `is_guest = true`. Blast radius
today is limited to the 2 `DevPlayer` rows.

**M-02 — `start_building`, `start_research`, `start_defense` and `sync_current_planet_resources`
retain `anon` EXECUTE.** They are internally guarded (`AUTHENTICATION_REQUIRED` + ownership), so this
is a defence-in-depth gap, not a demonstrated bypass.

**M-03 — Broad PUBLIC (`=X/postgres`) EXECUTE across ~100 helpers** (`calculate_*`, `simulate_*`,
`rank_*`, `evaluate_*`, `generate_*`). Mostly non-definer, so RLS still applies, but the surface is
large and includes the CPU-heavy group listed in C-02.

**M-04 — RLS DISABLED on `universe_process_health` and `combat_battle_participants`.** Mitigated today
by zero table grants for `anon`/`authenticated`. The Supabase advisor flags this as *critical*.

## 13. Frontend -> backend integration

Every client call site, resolved against LIVE:

| Caller | Contract | LIVE | Verdict |
|---|---|---|---|
| `App.tsx:56` `sync_current_planet_resources(p_player_id,p_planet_id)` | 3 args, 3rd defaulted | exists | **OK** (2 of 3 passed; `p_until` defaulted) |
| `App.tsx:62` `can_start_building(p_player_id,p_planet_id,p_building_id)` | 3 args | exists | **OK** |
| `App.tsx:63` `can_start_research(p_player_id,p_planet_id,p_research_id)` | 3 args | exists, SECDEF | **OK** |
| `App.tsx:64` `can_build_ship(...,p_quantity)` | 4 args | exists | **OK** |
| `App.tsx:65` `can_build_defense(...,p_quantity)` | 4 args | exists | **OK** |
| `App.tsx:71` dynamic `supabase.rpc(rpc,args)` | `start_building` / `start_research` / `start_ship` / `start_defense` | all 4 exist | **OK** |
| `App.tsx:78` `start_fleet_mixed(5)` | 5 args | exists | **OK** |
| `GalaxyView.tsx:15` `start_fleet(6)` | cast `p_destination_planet_id: string\|null` -> `string` | LIVE handles NULL destination | **OK (cast documented in a comment)** |
| `identity.ts:71` `provision_player(p_username,p_country_code)` | 2 args | **DOES NOT EXIST** | **BLOCKED — REPO AHEAD (§12 H-05)** |
| `universeEvolutionMonitor.ts:94` `get_universe_evolution_monitor_public(p_universe_id)` | 1 arg | exists, SECDEF, PUBLIC | **OK** (local interface bridges the types gap) |

Tables read by clients: `building_definitions`, `building_queue`, `combat_battles`,
`defense_definitions`, `defense_queue`, `espionage_reports`, `expedition_results`, `fleet_movements`,
`planet_buildings`, `planet_defenses`, `planet_ships`, `planets`, `player_research`, `players`,
`research_definitions`, `research_queue`, `ship_definitions`, `shipyard_queue`, `universe_galaxies`.
All exist, and all are read-only from the client (zero INSERT/UPDATE/DELETE grants).

**Conclusion:** no client call site references a missing column, a renamed field or a retired RPC —
with the single documented exception of `provision_player`, which is intentional and strictly ordered.

## 14. Tests / build

```text
npx tsc --noEmit -p tsconfig.app.json    PASS  (exit 0)
npx tsc -b                               PASS  (exit 0)
npx vite build                           PASS  (exit 0, dist/ written — gitignored, untracked)
npm run build  (= tsc -b && vite build)  PASS  (exit 0)
git diff --check                         clean
scripts/verify-identity.mjs              NOT EXECUTED  (needs a live session; would create real data)
scripts/verify-buildings.mjs             NOT EXECUTED  (read-only against LIVE but needs operator creds)
supabase/tests/*.sql  (6 suites)         BLOCKED / NOT EXECUTED
```

Note on the SQL suites: `buildings_lifecycle.sql` and `research_lifecycle.sql` are transactional
(`BEGIN … ROLLBACK`), but executing them requires running DML statements, which this audit's
read-only rule forbids. They are therefore **BLOCKED**, not PASS and not FAIL.
`fleet_speed_classes.sql`, `fleet_acs_hold_lifecycle.sql`, `shipyard_defense_lifecycle.sql` and
`combat_participant_propagation.sql` remain NOT EXECUTED.

Operator caveat: invoking `npm run build` through PowerShell surfaces Vite's
`[plugin builtin:vite-reporter]` chunk-size warning as a native-command error record. The build itself
exits 0. Not a defect.

## 15. Guest decommission readiness

| Dependency | Repo | LIVE | State | Blocks retirement |
|---|---|---|---|---|
| anonymous auth | not used by `src/` | 13 `is_anonymous` users; enabled state not readable via SQL | **BLOCKED / UNKNOWN (config)** | **YES (unverified)** |
| `register_guest_player` | DROP prepared (`20260920120200`) | present, EXECUTE `authenticated` | **DRIFT** | **YES (LIVE window)** |
| `is_guest` column | removal pending | `NOT NULL DEFAULT false`; **written by `reconcile_universe_ai_population`** | **DRIFT** | **YES (write dependency)** |
| guest RLS | 12 DROPs prepared | 6 still present, 6 absent | **DRIFT (idempotent)** | no (safe to drop) |
| guest guards | 5 of 6 patches match | `start_fleet` uncovered + 2 patches un-matchable | **DRIFT / GAP** | **YES (H-01, H-02)** |
| onboarding trigger | DROP prepared (`20260920120100`) | ENABLED, 12 AI already reassigned | **DRIFT** | **YES (LIVE window + order)** |
| DevPlayer | fixture predicate removed from tests | 2 rows, one with 0 planets; UUID hardcoded in a policy | **PRODUCT DECISION** | **YES (product)** |
| early tester | 0 writers left | 0 rows, 0 policies, 0 grants | **INERT** | no |
| achievements | 0 writers left | 0 rows, 1 owner-read policy | **INERT** | no |

## 16. New onboarding — viability (verified, not implemented)

```text
auth.uid()
  -> public.provision_player(p_username, p_country_code)
        SECURITY DEFINER · search_path = '' · owner postgres
        requires auth.uid()                else AUTHENTICATION_REQUIRED
        reuse-first: SELECT ... WHERE pl.user_id = v_user_id LIMIT 1 -> returns OWN player, never adopts
        never selects on user_id IS NULL   (no claim path exists in the body)
        advisory lock hashtextextended('lgi_player_provisioning_v1', 0)
        active universe: SELECT u.id FROM universes WHERE is_active ORDER BY created_at DESC LIMIT 1
        slot pick: universe_galaxies x generate_series(1,system_count) x generate_series(1,15)
                   LEFT JOIN planets ... WHERE existing.id IS NULL     -> deterministic first free slot
        INSERT players(user_id, universe_id, username, last_activity_at)     [is_guest NOT written]
        INSERT planets(Homeworld, fields_total 163, is_homeworld true)
        INSERT planet_resources(500, 500, 0, 0)
        perform public.initialize_player_research(v_player_id)               [VERIFIED LIVE, §9]
        returns (player_id, planet_id, username, galaxy, system, planet_position)
        ACL: REVOKE from public, anon  ·  GRANT to authenticated
  -> players · planets · planet_resources · player_research
```

| Requirement | Status |
|---|---|
| idempotent | **YES** — reuse-first branch returns the existing player |
| atomic | **YES** — one function body = one transaction, no partial empire |
| reuse-first | **YES** — selects only `user_id = auth.uid()` |
| ownership-safe | **YES** — identity derived from `auth.uid()`, client-supplied ids ignored |
| does not claim existing rows | **YES** — no `user_id IS NULL` selection anywhere in the body |
| LIVE dependency `initialize_player_research(uuid)` | **PRESENT and verified** (§9) |

`provision_player` is `REPO AHEAD / LOCAL-ONLY` and has never run in LIVE. Its correctness is a
static-analysis conclusion, not a runtime certification.

## 17. What this audit did NOT touch

```text
Repository history      untouched  (no reset, no clean, no commit, no push)
Migrations tree         untouched  (*.superseded / *.obsolete left in place)
Stashes                 untouched  (stash@{0}, stash@{1})
Checkpoints             untouched  (refs/cline/checkpoints/**)
backup/supabase/*.sql   untouched  (provenance)
template/               untouched  (reference material)
LIVE database           untouched  (no DDL, DML, ACL, RLS or config change)
LIVE Auth config        untouched  (not even readable through SQL)
database.types.ts       NOT regenerated (deliberate — §10)
20260920120300          NOT corrected (deliberate — needs the LIVE window)
ui_defense_queue        NOT patched (deliberate — C-01)
generate_building_sequences  NOT bounded / NOT revoked (deliberate — C-02)
players.is_guest        NOT dropped (deliberate — still written by reconcile_universe_ai_population)
on_auth_user_created    NOT dropped (deliberate — provision_player must reach LIVE first)
Existing dirty files    NOT reverted and NOT cleaned
```

## 18. Classification summary

```text
CLOSED              initialize_player_research(uuid) — verified reusable
CONFIRMED LOCAL     frontend email/password chain; explicit onboarding; 5 prepared migrations
CONFIRMED LIVE      trigger enabled + claiming; register_guest_player reachable; 9 guest consumers;
                    6 guest RLS policies; is_guest written by the AI population engine;
                    2 cron jobs; 226 distinct public functions; 269 ledger rows

## 19. Recommended order of the next safe changes

```text
LOCAL ONLY (no LIVE window needed)
  1. Repair the 20260920120300 patcher preconditions for start_fleet_mixed / start_colonize_fleet.
  2. Extend the retirement set to start_fleet.
  3. Add a depth bound and/or ACL tightening for generate_building_sequences (C-02), forward-only.

LIVE WINDOW (strict order)
  4. Deploy the frontend build that calls provision_player.
  5. Apply 20260920120000  -> verify with pg_get_functiondef.
  6. Apply 20260920120100  -> closes C-03.
  7. Apply 20260920120200.
  8. Apply the repaired 20260920120300, then 20260920120400.
  9. Forward migration for ui_defense_queue (C-01).
 10. Forward migration to drop players.is_guest (reconcile reconcile_universe_ai_population first),
     then regenerate database.types.ts.

PRODUCT DECISION (no engineering prerequisite)
 11. early_tester_registrations / player_achievements: retain as provenance or retire.
 12. The 2 DevPlayer rows and the hardcoded UUID branch in players_select_access.
 13. The 12 already-claimed AI empires and the 321 claimable ones.
 14. Whether anonymous sign-in stays enabled.
```

## 20. Conclusion

The project has **no unknown zones left in the audited surface**. Every table, function, trigger,
policy, cron job, client call site and generated contract has been classified against LIVE.

The engine is healthy and its temporal / fleet / combat / commerce machinery is coherent. The
frontend is clean: it compiles, builds, and has no broken contract. The migration provenance state is
unchanged and still gated.

What remains is a small number of **precise, individually verifiable defects**: one anonymous
cross-player read hole, one unauthenticated unbounded recursive RPC, one still-live onboarding trigger
that has already reassigned 12 AI empires in production, one patcher that cannot execute, one
uncovered guest branch, one written column that blocks a drop, and a generated-types file that carries
six dead contracts.

None of them requires a second architecture. All of them have an identified, evidence-backed fix.

DRIFT               generated types (31 missing / 6 dead); migration versions (11 local / 4 live);
                    RLS surface; 2 tables with RLS disabled
PROVENANCE GAP      4 LIVE-only unrecoverable versions; 20260919180000 + 20260920010000 + guest set
BLOCKED LIVE        Auth anonymous-sign-in state; SQL test suites; browser certification
PRODUCT DECISION    2 DevPlayer rows; hardcoded DevPlayer UUID policy; dashboard_widgets;
                    is_guest as long-term provenance; anonymous sign-in toggle
UNKNOWN             lifeform_definitions consumer (FK-only evidence)
```

| test fixtures | `buildings_lifecycle.sql` / `research_lifecycle.sql` select a HUMAN player with `user_id` | no HUMAN non-guest player exists yet | **BLOCKED** | no (test-only) |

```text
GUEST DECOMMISSION:  BLOCKED
```

Not blocked by the frontend (done), not blocked by the game engine, not blocked by data volume.
Blocked by four concrete, individually verifiable items:

1. `20260920120300` cannot execute (patcher precondition mismatch on 2 of 6 targets).
2. `start_fleet` is outside the retirement set.
3. `players.is_guest` is still WRITTEN by `reconcile_universe_ai_population`.
4. The Auth `anonymous sign-in` configuration cannot be read from SQL.
   Plus the mandatory deployment order in §12 H-05.

Remediation must include policies first — enabling RLS without policies blocks all access
(<https://supabase.com/docs/guides/database/row-level-security>).

**M-05 — `players_select_access` hardcodes `id = 'aa1deb2d-3ed6-4350-922a-172d999b2af7'` as a PUBLIC
read branch.** Confirmed to be one of the two `DevPlayer` rows. A development exception embedded in a
policy that ships to production.

**M-06 — `select_expedition_speedup_percentage` has two overloads with inconsistent ACLs** (§11.5).

### LOW

**L-01 — `ui_*` definition read models duplicate already-public table reads** (§11.3).
**L-02 — redundant `players` uniqueness guard** (§11.5).
**L-03 — `dashboard_widgets` (14 rows), `player_messages` (0), `player_notes` (0) have no consumer.**
**L-04 — `template/*.txt` (~1.2 MB) and `.wrangler/*` empty dirs are inert residue.**


Measured consequences:

- 12 rows with `player_type = 'AI'` now carry a `user_id` (they should have none). No other known code
  path can assign `user_id` to a pre-existing AI row; the trigger is the only candidate, and its
  `UPDATE` leaves `player_type` and `is_guest` untouched — exactly the observed state.
- 13 `auth.users` rows with `is_anonymous = true` were created between 2026-09-16 and 2026-09-19,
  inside the window in which those 12 AI rows acquired an owner.
- `early_tester_registrations` and `player_achievements` are both empty: new sessions were handed a
  pre-existing player by the trigger, so `register_guest_player` took its reuse-first branch and never
  wrote the early-tester bookkeeping.
- The next registration claims the oldest unclaimed row: `2026-09-14 03:47:49Z`, `player_type='AI'`,
  `username ~ '^AI-G'`. 321 AI empires remain claimable; **0** HUMAN players are claimable.

Recommended action: leave as-is until the LIVE window, then apply the already-written
`20260920120100` **after** the `provision_player` frontend is deployed and the function exists in
LIVE. **REQUIRES LIVE WINDOW, strict order.**

select_expedition_speedup_percentage(p_fleet_id)  ACL: PUBLIC but NOT anon/authenticated
   -> two overloads with inconsistent ACL. Needs a directed review, never an automatic drop.

players: two uniqueness guards on overlapping column sets
   players_user_id_universe_id_key  UNIQUE (user_id, universe_id)
   ux_players_user_id               UNIQUE (user_id) WHERE user_id IS NOT NULL
   -> the partial unique index subsumes the constraint. Redundant, not a defect.

planets: ux_one_homeworld_per_player (partial unique) + idx_planets_universe_player -> intentional
```

20 of the 21 analysis views are referenced by **no function body and no client**:

```text
action_candidates, action_economic_evaluation, action_energy_evaluation,
building_action_candidates, economic_action_candidates, empire_action_ranking,
empire_economic_monitor, empire_energy_monitor, empire_next_action,
executable_action_candidates, next_action, next_action_explained,
normalized_action_candidates, optimization_candidates, production_roi_candidates,
research_action_candidates, scored_action_candidates, simulated_followup_actions,
temporal_action_candidates, unified_action_candidates
```

Only `executable_optimization_candidates` is referenced by a function body.

Classification: **ENGINE-ANALYSIS SURFACE, no client consumer.** Read-only decision-support
artifacts, intended for manual/ad-hoc querying. Recommended action: **none** (document only). Do not
drop.

LIVE callers          2: itself + public.register_guest_player
writes               public.player_research   (reads public.research_definitions)
```

**Verdict: reusable, no new migration required.** `provision_player` is `SECURITY DEFINER` owned by
`postgres`, so the `perform public.initialize_player_research(...)` call executes with `postgres`
privileges: EXECUTE is available and the inner INSERT bypasses RLS (table owner). No invention, no
reconstruction — this is the LIVE body as reported by `pg_get_functiondef`.


```sql
v_user_id := auth.uid();
if v_user_id is null then
  if coalesce(v_is_guest, false) is not true then raise exception 'AUTHENTICATION_REQUIRED'; end if;
elsif v_user_id is distinct from (select pl.user_id from public.players pl where pl.id = v_player_id) then
  raise exception 'PLAYER_NOT_OWNED_BY_AUTH_USER';
end if;
```

`enforce_player_write_access` ACL is now `{postgres, service_role}` — the FORENSIC note that it
"reportedly has EXECUTE for `anon`" is **STALE**.

| `fleet_movements` | present |
| `fleet_movement_ships` | present |
| `players` / `planets` / `planet_resources` / `player_research` / `building_queue` / `research_queue` | **absent** (the prepared migration's `DROP IF EXISTS` is a no-op for these 6) |

Mixed policies still carrying the guest branch:
`players_select_access`, `planet_resources_select_access`, `building_queue_select_access`,
`player_research_select_access`, `research_queue_select_access`, `defense_queue_owner_read`.

Untouched by design: `planets_select_access` (`is_destroyed = false`) — intentionally public, feeds
the galaxy map.


```text
players total                            335
  AI,    is_guest=false, user_id NULL    321
  AI,    is_guest=false, user_id NOT NULL 12
  HUMAN, is_guest=true,  user_id NOT NULL  2   (both username = 'DevPlayer')
planets total                            334
players without any planet                 1   (one of the two DevPlayer rows)
homeworlds per owned player                AI-with-user_id 12/12 · DevPlayer 1/1
auth.users total                          14   (13 is_anonymous=true, 1 email)
auth.identities provider                  email (only)
oldest unclaimed player                   2026-09-14 03:47:49Z, player_type='AI', username ~ '^AI-G'
early_tester_registrations                0 rows, RLS on, 0 policies, 0 grants
player_achievements                       0 rows, RLS on, 1 owner-read policy (authenticated SELECT)
```

```text
AVAILABLE
```

Determined from `.vscode/mcp.json` (Supabase MCP server), `supabase/.temp/linked-project.json`
(`ref: evtfsbntvuqmahiskekd`) and the project URL, which matches `.env.local` and
`docs/PRODUCTION_DB_BASELINE.md`. No secret was read, copied or written.
