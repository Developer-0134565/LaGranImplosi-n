# MIGRATION INVERSE DRIFT AUDIT — LA GRAN IMPLOSIÓN

> Inverse-drift mission 2026-09-18. Scope: make the **local** migration history push-safe — every local
> file should carry the version LIVE recorded. Read-only against LIVE: no `db push`, no `db reset`,
> no `migration repair`, and **no rename executed** (see §5).
> Companion document: [`MIGRATION_DRIFT_RECONCILIATION.md`](MIGRATION_DRIFT_RECONCILIATION.md).

## 1. Counts (measured)

```text
local migration files inspected : 40
LIVE ledger rows inspected      : 260  (260 with SQL payload)
EXACT (version = live)          : 19
EXACT_VERSION_COSMETIC          :  2   (same version, formatting-only difference)
VERSION_DRIFT (SQL equivalent)  : 11
VERSION_DRIFT_COSMETIC          :  4
VERSION_AND_NAME_DRIFT          :  1
DUPLICATE                       :  0
REAL_DIVERGENCE                 :  2
AMBIGUOUS                       :  1
local versions absent from LIVE : 19  → these are what `db push` would re-apply
```

**Decision gate (mission rule):** automation stops when `REAL_DIVERGENCE > 0` or `AMBIGUOUS > 0`.
Here **2 + 1 > 0 → STOP: no file was renamed, moved or repaired.**

## 2. Method

```text
match order per local file: exact version -> normalised name -> normalised SQL
SQL compared against supabase_migrations.schema_migrations.statements (verbatim applied payload) with
two hashes: strict (BOM/EOL/trailing whitespace) and semantic (comments stripped, whitespace collapsed).
For every mismatch the first differing offset, both contexts and the object inventory
(functions / indexes / policies / tables / ACL statements) were extracted as evidence (see §4).
```

## 3. Matrix

| Local version | Local name | LIVE version | LIVE name | SQL match | Classification |
|---|---|---|---|---|---|
| 20260913043259 | harden_api_security_and_indexes | 20260913043259 | = | formatting (whitespace + `AS` aliases; 29 idx / 11 policies SAME) | EXACT_VERSION_COSMETIC |
| 20260913043318 | harden_lifeform_mutations_and_fix_legacy_combat | 20260913043318 | = | formatting (`new.planet_id` spacing; 2 fns SAME) | EXACT_VERSION_COSMETIC |
| 20260913043356 | lock_down_public_default_privileges | 20260913043356 | = | semantic | EXACT |
| 20260913044000 | harden_internal_rpc_permissions | 20260913043732 | = | strict | VERSION_DRIFT |
| 20260913051000 | fix_start_fleet_guest_auth | 20260913051303 | = | formatting (`NOT IN ( '…' )` spacing; 1 fn SAME) | VERSION_DRIFT_COSMETIC |
| 20260913080500 | grant_authenticated_building_and_research_rpcs | 20260913080256 | = | strict | VERSION_DRIFT |
| 20260913091000 | harden_calculate_building_cost_security | 20260913090452 | = | semantic | VERSION_DRIFT |
| 20260913094500 | harden_start_research_concurrency | 20260913093737 | = | strict | VERSION_DRIFT |
| 20260913100000 | harden_start_fleet_destination_universe | 20260913093046 | = | semantic | VERSION_DRIFT |
| 20260913103000 | remove_orphan_strict_audit_table | 20260913103153 | = | semantic | VERSION_DRIFT |
| 20260914073000 | align_economy_projection_helpers | 20260914052934 | = | strict | VERSION_DRIFT |
| 20260914074800 | integrate_evolution_over_resource_time | 20260914054021 | = | formatting (`LEAST( v_end, …)` spacing) | VERSION_DRIFT_COSMETIC |
| 20260914215000 | close_legacy_state_mutation_entrypoints | 20260914214728 | = | strict | VERSION_DRIFT |
| 20260914215616 | final_audit_close_public_state_mutation_gaps | 20260914215616 | = | strict | EXACT |
| 20260915050000 | add_guest_temporal_ui_sync_rpc | 20260915045311 | = | semantic | VERSION_DRIFT |
| 20260915210651 | create_normal_guest_onboarding_and_early_tester | 20260915210651 | = | strict | EXACT |
| 20260915210748 | allow_dev_frontend_player_read | 20260915210748 | = | strict | EXACT |
| 20260915210912 | allow_dev_frontend_resource_read | 20260915210912 | = | strict | EXACT |
| MALFORMED | 20260915_add_sidebar_social_data_v1 | 20260915032657 | add_sidebar_social_data_v1 | strict | VERSION_AND_NAME_DRIFT |
| 20260916014916 | harden_universe_temporal_catchup_v2 | 20260916014916 | = | semantic | EXACT |
| 20260916020002 | harden_universe_fleet_event_order | 20260916020002 | = | strict | EXACT |
| 20260916020230 | harden_fleet_arrival_queue_timestamps | 20260916020215 | = | **local 2 fns vs LIVE 4 fns** (live-only: `resolve_attack_arrival`, `resolve_espionage_arrival`) | REAL_DIVERGENCE |
| 20260916020500 | harden_fleet_event_time_rewards | 20260916015541 | 20260916020500_… | formatting (`AND ( eu…` spacing; 5 fns SAME) | VERSION_DRIFT_COSMETIC |
| 20260916021500 | fix_attack_arrival_temporal_order | 20260916020648 | 20260916021500_… | formatting (`AND` clause order swapped; 1 fn SAME) | VERSION_DRIFT_COSMETIC |
| 20260918020000 | register_universe_evolution_monitor | 20260918015016 | = | **local adds 2 REVOKE statements** absent from the applied payload | REAL_DIVERGENCE |
| 20260918020100 | add_public_universe_evolution_monitor | 20260918015023 | = | strict | VERSION_DRIFT |
| 20260918020200 | lock_public_universe_evolution_monitor_to_guest | 20260918015116 | = | strict | VERSION_DRIFT |
| 20260918020300 | allow_authenticated_universe_evolution_monitor | — | — | no ledger row; effect present in LIVE (§4.3 ACL evidence) | AMBIGUOUS |
| 20260918030000 | harden_player_ownership_in_owned_rpcs | 20260918030000 | = | ledger payload is a **pointer comment** naming this file (146 bytes) | EXACT |
| 20260918085406 | add_can_start_research_contract | 20260918085406 | = | semantic | EXACT |
| 20260918094108 | harden_shipyard_queue_processing_ownership | 20260918094108 | = | semantic | EXACT |
| 20260918094128 | lock_internal_shipyard_queue_until | 20260918094128 | = | semantic | EXACT |
| 20260918094440 | use_canonical_fleet_travel_time_in_dispatch | 20260918094440 | = | semantic | EXACT |
| 20260918094959 | add_ogame_drive_speed_and_fuel_logic | 20260918094959 | = | semantic | EXACT |
| 20260918095005 | apply_drive_tech_to_fleet_dispatch | 20260918095005 | = | semantic | EXACT |
| 20260918095009 | lock_internal_drive_calculation_helpers | 20260918095009 | = | semantic | EXACT |
| 20260918095029 | fix_zero_level_drive_research_lookup | 20260918095029 | = | semantic | EXACT |
| 20260918095306 | harden_fleet_movement_idempotency_and_processing | 20260918095306 | = | semantic | EXACT |
| 20260918095315 | deduplicate_fleet_event_indexes | 20260918095315 | = | semantic | EXACT |
| 20260918100000 | converge_expedition_hold_to_mission_class | 20260918100000 | = | pointer payload; equivalence proven by `pg_get_functiondef` body hash MATCH | EXACT |

## 4. Evidence for the non-trivial cases

### 4.1 Formatting-only differences (6 cases, NOT real divergences)

```text
20260913043259  local: "SELECT n.nspname AS schema_name, p.proname AS function_name, …"
                live : "SELECT n.nspname schema_name,p.proname function_name,…"      (AS dropped)
20260913043318  local: "where p.id=new.planet_id"      live: "where p.id = new.planet_id"
20260913051000  local: "NOT IN ( 'ATTACK', 'TRANSPORT', … )"  live: "NOT IN ('ATTACK','TRANSPORT',…)"
20260914074800  local: "LEAST(v_end, …)"               live: "LEAST( v_end, … )"
20260916020500  local: "AND ( eu.effect_snapshot->>…"  live: "AND ( eu.effect_snapshot->>…"  (space)
20260916021500  local: "ciu.unit_id=pd.defense_id and ciu.unit_type='DEFENSE'"
                live : "ciu.unit_type='DEFENSE' and ciu.unit_id=pd.defense_id"      (AND order)
```

In all six the object inventory is identical (same functions, indexes and policies; e.g. 29 indexes +
11 policies in `harden_api_security_and_indexes`). They represent the same migration with different
authorship formatting, so the local file is a faithful representation of the applied change.

### 4.2 REAL_DIVERGENCE (content really differs)

```text
20260916020230_harden_fleet_arrival_queue_timestamps.sql
  local : 2 functions, 2258 normalised chars
  LIVE  : 4 functions, 9216 normalised chars (payload of ledger 20260916020215)
  live-only objects: resolve_attack_arrival, resolve_espionage_arrival
  → the local file is a SUBSET: re-applying it would rewrite the two shared functions with the older
    definitions (regression risk). Needs a body-level comparison before any renaming.

20260918020000_register_universe_evolution_monitor.sql
  local : function body + 2 REVOKE statements (6021 chars)
  LIVE  : function body only (5776 chars, payload of ledger 20260918015016)
  → the local file is a SUPERSET: the ACL tightening is covered in LIVE by the later ledger row
    20260918015116, but the payloads are not identical, so the file cannot be declared equivalent.
```

### 4.3 AMBIGUOUS (no ledger counterpart at all)

```text
20260918020300_allow_authenticated_universe_evolution_monitor.sql (191 bytes)
  content: revoke execute … from public;  grant execute … to anon, authenticated;
  ledger : no row matches by version, name or SQL; the only monitor ACL row is
           20260918015116 (revoke … from authenticated)
  LIVE   : get_universe_evolution_monitor_public(uuid) ACL =
           {postgres=X, service_role=X, anon=X, authenticated=X}  → PUBLIC has no EXECUTE
  reading: the END STATE intended by this file is present in LIVE, but no migration row records it
           (applied out-of-band or folded into another payload) → it cannot be re-labelled to a
           ledger version because none exists.
```

## 5. Decision: STOP (no sanitisation performed)

```text
REAL_DIVERGENCE = 2  and  AMBIGUOUS = 1  →  the mission gate forbids renaming / moving / repairing.
Files renamed : 0      Files moved : 0      LIVE modified : NO
db push : NO           migration repair : NO
```

The audit still proves that **16 of the 19 push-affected files are SQL-equivalent** to their ledger
counterpart (11 VERSION_DRIFT + 4 VERSION_DRIFT_COSMETIC + 1 VERSION_AND_NAME_DRIFT), so a future mission
can rename them to the ledger versions using the evidence in §3 and §4.1.

## 6. Proposed resolution (next mission — not executed)

```text
1. 20260916020230 → decide between the local subset and the applied 4-function payload: compare the two
   shared function bodies with LIVE; if LIVE already holds the newer bodies, archive the local file and
   recover the ledger payload as 20260916020215_harden_fleet_arrival_queue_timestamps.sql.
2. 20260918020000 → the applied payload is the function only; move the two extra REVOKEs into an
   explicitly versioned migration (or drop them if LIVE ACLs are already correct).
3. 20260918020300 → no ledger row exists: keep it documented as an unrecorded apply, or fold it into the
   next forward migration. Do NOT use `migration repair` without a project decision.
4. Then rename the 16 equivalent files to their ledger versions (target must not exist; verified per file).
5. Only when REAL_DIVERGENCE = AMBIGUOUS = 0, continue with the full ledger recovery (239 rows).
```

## 8. Blocker Resolution (2026-09-18, same day)

The three blockers of §5 were resolved with ledger evidence; the STOP is lifted for them.

| Blocker | LIVE provenance | Local provenance | Conclusion | Action |
|---|---|---|---|---|
| `20260916020230_harden_fleet_arrival_queue_timestamps.sql` | ledger `20260916020215` — 4 functions, 9486 B | local file = 2 functions (`process_shipyard_queue_until`, `process_defense_queue_until`); its own closing comment says it installs the authoritative `resolve_attack_arrival` / `resolve_espionage_arrival` | **A — obsolete/incomplete local representation** (its first normalised 2258 chars equal the start of the applied payload) | recovered `20260916020215_harden_fleet_arrival_queue_timestamps.sql` VERBATIM; local file moved to `*.sql.obsolete` (content preserved) |
| `20260918020000_register_universe_evolution_monitor.sql` | ledger `20260918015016` — function only, 6010 B | same function body + 3 `REVOKE … get_universe_evolution_monitor(uuid)` (public / anon / authenticated) | **B — LOCAL SUPERSET with an OUT-OF-BAND ACL change**: no payload among the 260 contains those REVOKEs; LIVE ACL confirms the effect (`{postgres, service_role}` only) | recovered `20260918015016_register_universe_evolution_monitor.sql` VERBATIM; local file moved to `*.sql.obsolete`; the ACL stays OPEN (§9) |
| `20260918020300_allow_authenticated_universe_evolution_monitor.sql` | **no ledger row** (no version, no name, no SQL match). Ledger records only the earlier part of the chain: `20260918015023` = `revoke … from public`, `revoke … from anon`, `revoke … from authenticated`, `grant … to anon`; `20260918015116` = `revoke … from authenticated` | local 191 B = `revoke … from public` + `grant … to anon, authenticated` | **C — manual/out-of-band apply**: LIVE state exists, no ledger provenance (the `GRANT to authenticated` is unrecorded) | local file moved to `*.sql.obsolete`; forward migration required for reproducibility (§9) |

### Function chronology and dependencies (BLOQUE 4)

```text
resolve_attack_arrival
  20260912120221 → 20260912124054 → 20260912132252 → 20260914042532 → 20260914044523
  → 20260916020215 (harden_fleet_arrival_queue_timestamps, 4 functions)
  → 20260916020648 (fix_attack_arrival_temporal_order)  ← LAST definition in the whole ledger
resolve_espionage_arrival
  20260912232456 → 20260914153426 → 20260916020215                  ← LAST definition
process_shipyard_queue_until
  20260916020215 → 20260918094108 → 20260918094128 (ACL lock)       ← LAST definition
process_defense_queue_until
  20260916020215                                                    ← LAST (and only recent) definition
get_universe_evolution_monitor
  20260918015016                                                    ← only definition
get_universe_evolution_monitor_public
  20260918015023 (+ ACLs) → 20260918015116 (revoke authenticated)   ← ACL chain, no grant to authenticated
```

Body verification (`md5` of the normalised body, LIVE vs file):

```text
MATCH  resolve_espionage_arrival      (20260916020215)   ← LIVE explained by the recovered payload
MATCH  process_defense_queue_until    (20260916020215)   ← idem
MATCH  process_shipyard_queue_until   (20260918094128)   ← superseded later, chain closed
MATCH  get_universe_evolution_monitor (20260918015016)   ← idem
DIFF   resolve_attack_arrival         (20260916020215 → superseded; 20260916020648 file carries the
       already-evidenced cosmetic AND-clause-order variant). No ledger payload after 20260916020648
       redefines this function, so LIVE corresponds to that payload modulo that cosmetic difference.
```

### Local artefacts moved aside (content preserved, reversible)

```text
supabase/migrations/20260916020230_harden_fleet_arrival_queue_timestamps.sql.obsolete
supabase/migrations/20260918020000_register_universe_evolution_monitor.sql.obsolete
supabase/migrations/20260918020300_allow_authenticated_universe_evolution_monitor.sql.obsolete
```

Each `.obsolete` file starts with a provenance header stating the reason, the authoritative file and (when
applicable) the OPEN item. The `.obsolete` extension is not discovered as a migration by the CLI.

### Sanitation executed in the same pass (16 version re-labels)

Because the remaining 16 push-affected files were proven SQL-equivalent (§3/§4.1), they were renamed to
the version LIVE recorded (mapping: [`migration-inverse-drift-renames.json`](migration-inverse-drift-renames.json)):
`20260913044000→20260913043732`, `20260913051000→20260913051303`, `20260913080500→20260913080256`,
`20260913091000→20260913090452`, `20260913094500→20260913093737`, `20260913100000→20260913093046`,
`20260913103000→20260913103153`, `20260914073000→20260914052934`, `20260914074800→20260914054021`,
`20260914215000→20260914214728`, `20260915050000→20260915045311`,
`20260915_add_sidebar_social_data_v1→20260915032657_add_sidebar_social_data_v1`,
`20260916020500→20260916015541`, `20260916021500→20260916020648`, `20260918020100→20260918015023`,
`20260918020200→20260918015116`. Destination existence was verified; no file was overwritten.

### Post-resolution audit (BLOQUE 7)

```text
local .sql files: 39        LIVE ledger rows: 260
EXACT 13 · EXACT_COMMENTS 18 · EXACT_POINTER 2 · EXACT_VERSION_COSMETIC 6
VERSION_DRIFT 0 · VERSION_DRIFT_COSMETIC 0 · VERSION_DRIFT_POINTER 0 · VERSION_AND_NAME_DRIFT 0
REAL_DIVERGENCE 0 · AMBIGUOUS 0
LOCAL - LIVE : EMPTY        LIVE - LOCAL : 221 rows (the old gap — deferred, BLOQUE 8)
```

## 8b. Verification protocol (state after resolution)

```text
for every local file: version exists in supabase_migrations.schema_migrations   → TRUE (39/39)
                      normalised(local SQL) == normalised(LIVE payload)         → TRUE for all but the
                      6 files whose difference is formatting-only (whitespace /
                      AS aliases / AND clause order — §4.1) plus the 2 pointer
                      payloads and the 18 files carrying a recovery/provenance
                      comment header (EXACT_COMMENTS)
LOCAL - LIVE : EMPTY                    (every local version exists in LIVE)
LIVE - LOCAL : 221 rows                 (old gap, deferred to the full-ledger recovery)
```

## 9. OPEN items from the blocker resolution (no LIVE change made)

```text
OPEN-1  ACL of get_universe_evolution_monitor(uuid)  [private monitor]
        LIVE state : EXECUTE only for postgres + service_role (PUBLIC/anon/authenticated revoked)
        provenance : OUT-OF-BAND — no ledger payload contains those REVOKEs
        required   : a FORWARD migration that re-asserts the revokes, so a rebuild from migrations
                     reproduces the hardening. Not created in this mission (task instruction).

OPEN-2  ACL of get_universe_evolution_monitor_public(uuid)
        LIVE state : anon + authenticated have EXECUTE, PUBLIC revoked
        provenance : partially recorded — 20260918015023 (revoke public/anon/authenticated, grant anon)
                     and 20260918015116 (revoke authenticated); the GRANT to authenticated is
                     UNRECORDED (out-of-band)
        required   : a FORWARD migration that grants EXECUTE to authenticated explicitly.
                     Not created in this mission.

OPEN-3  Full ledger recovery: 221 ledger rows still have no local file
        (the next mission: recover them VERBATIM from statements, validate as in §8, then
        REPOSITORY HISTORY == CERTIFIED LIVE HISTORY).
```

Note (corrected 2026-09-18, second pass): after the integration merge the folder also contains four
`origin/main` files whose version IDs are absent from the ledger (§10), so a `supabase db push` from this copy
would no longer be a no-op. It remains PROHIBITED until §10 is resolved; `migration repair` stays prohibited.

## 10. Post-merge remote-origin migrations — drift audit (2026-09-18, second pass)

Four migrations brought in by the integration merge (`6aa73ed` = local `55494aa` + `origin/main 64ecc14`).
**None of their version IDs exists in the LIVE ledger**:

| Local file (origin/main commit) | Version in ledger? | Ledger row(s) carrying the same change | LIVE reflection | Classification |
|---|---|---|---|---|
| `20260918101500_converge_fleet_mission_timing_and_lock_mixed_rpc.sql` (`22a380b`) | **NO** | `20260918094440` (canonical travel time in dispatch), `20260918095005` (drive tech in dispatch), `20260918100000` (expedition hold class) | yes — dispatchers are already canonical and no longer contain the legacy inline expedition formula; `start_fleet_mixed` has no `anon` EXECUTE | **DERIVA DE VERSION** |
| `20260918110000_add_can_start_research_contract.sql` (`19f6507`) | **NO** (version absent; the *name* is recorded under version `20260918085406`) | `20260918085406` (identical logical change) | yes — `can_research` is SECURITY DEFINER, `can_start_research` exists, ACLs verified | **DERIVA DE VERSION** |
| `20260918113000_fleet_engine_canonical_calculation_sweep.sql` (`1fd413b`) | **NO** | `20260917040727`, `20260918094440`, `20260918094959`/`20260918095005`, `20260918095009` | yes — distance/fuel helpers and the legacy REVOKE match LIVE; the dispatch distance patches are no-ops | **DERIVA DE VERSION** (with a semantic note) |
| `20260918125000_fleet_mission_speed_and_fuel_convergence.sql` (`81c7b45`) | **NO** | **none** — 0 of the 260 payloads mention the three class columns or the classifier | yes — columns exist (`NOT NULL DEFAULT 1`), classifier and fuel helper are LIVE-equivalent | **ALINEADA (procedencia ausente en el ledger)** |

### Semantic vs formatting differences (whitespace-normalised body hashes)

```text
equivalent (formatting only: `a = b` vs `a=b`, indentation, trailing space):
  calculate_fleet_distance_to_coordinates   (113000)  file=c8b51c9f4b  LIVE=c8b51c9f4b…
  calculate_fleet_fuel                      (113000)  file=4d3b987b74  LIVE=4d3b987b74…
  calculate_mission_fleet_speed_multiplier  (125000)  file=8682c308f5  LIVE=8682c308f5…
  calculate_player_fleet_fuel_for_distance  (125000)  file=3f3ef3cae2  LIVE=3f3ef3cae2…
  can_research                              (110000)  first diff: `rd.id = p_research_id` vs `rd.id=p_research_id`
  can_start_research                        (110000)  first diff: `uuid := auth.uid()` vs `uuid:=auth.uid()`
  calculate_expedition_time                 (101500)  first diff: `p.id = p_origin_planet_id` vs `p.id=p_origin_planet_id`

semantically different — both are DEAD legacy helpers (no live callers):
  calculate_fleet_time        (113000)  file=1255 chars vs LIVE=754: the file re-introduces the
                                        `universes.fleet_speed` + `get_player_fleet_speed_multiplier` variant,
                                        while LIVE holds the shorter classifier-based (TRANSPORT) variant
  calculate_fleet_fuel_mixed  (113000)  file=1430 vs LIVE=1500: the file builds `v_slowest_ship` explicitly,
                                        while LIVE computes the slowest ship inside the `calculate_fleet_time(...)` call
```

### LIVE state verified for the objects these files touch

```text
start_fleet / start_fleet_mixed / start_colonize_fleet : calls_classifier=YES · calls_distance_helper=YES
                                                         inline-legacy-expedition=NO · inline-legacy-distance=NO
start_fleet_mixed ACL                  {postgres, service_role, authenticated}   ← anon already revoked (101500 no-op)
calculate_fleet_fuel_for_distance ACL  {postgres, service_role}                  ← legacy helper already revoked (113000 no-op)
universes                              fleet_speed=1 · peaceful=1 · war=1 · holding=1 (NOT NULL DEFAULT 1)
can_start_research ACL                 authenticated=YES · anon=NO ;  can_research / check_ / get_ revoked
```

### What a `db push` would do (analysis only — NOT executed)

```text
20260918101500 : REVOKE no-op; CREATE OR REPLACE calculate_expedition_time (dead, equivalent body); the DO-block
                 patches target text that no longer exists → the dispatchers are re-created with their current
                 (canonical) definitions. Benign; would add one ledger row.
20260918110000 : CREATE OR REPLACE (equivalent) + ALTER OWNER (no-op) + REVOKE/GRANT (idempotent). Benign, but
                 creates a SECOND ledger row for a change already recorded as 20260918085406.
20260918113000 : equivalent for the live helpers + REVOKE no-op; HOWEVER it would rewrite the two dead legacy
                 helpers to the `fleet_speed`-generic variants (against the README guardrail). Benign for
                 gameplay; undesired for canonical hygiene.
20260918125000 : ADD COLUMN IF NOT EXISTS (no-op) + UPDATE writing the same values (no-op) + CREATE OR REPLACE
                 (equivalent) → benign, and it would CREATE the missing ledger provenance of the class layer.
```

### New verified finding (recorded here, NOT fixed)

**The mission-speed-class layer has no ledger provenance.** A global search over all 260 ledger `statements`
payloads returns **0 matches** for `peaceful_fleet_speed`, `war_fleet_speed`, `holding_fleet_speed` and
`calculate_mission_fleet_speed_multiplier`. The layer therefore exists in LIVE without any recorded migration
(same class of gap as the two monitor ACLs in §9/OPEN-1/OPEN-2). The only authored record of that change in the
project is `20260918125000_fleet_mission_speed_and_fuel_convergence.sql` (from `origin/main`).

Consequences:

```text
· the LIVE class layer cannot be reproduced from the ledger → a rebuild from migrations would fall back to a
  single fleet speed (the dispatchers would still call the classifier, so it must exist before them);
· the repo file is the change's only documentation → treat it as valuable provenance, not as dead weight;
· OPEN items for the next phase: give the class layer an explicit FORWARD migration (or let an approved push
  record it) together with the two out-of-band monitor ACLs.
```

### Recommended reconciliation (next phase — still no push)

```text
1. Do NOT run `supabase db push`: it would apply four unrecorded versions, create duplicate ledger rows for the
   research contract and rewrite two dead legacy helpers.
2. Decide, per file:
   a. 20260918101500, 20260918110000, 20260918113000 → their logical change is already recorded in the ledger
      under other versions. Options: keep them as authored records (and accept that a future push would create
      extra rows), or archive them as `*.sql.superseded` with a provenance header pointing at the ledger rows.
   b. 20260918125000 → KEEP: it is the only provenance of the out-of-band class layer; a future forward
      migration or an approved push should record it in the ledger.
3. Record the out-of-band items (class layer + the two monitor ACLs of §9) as an explicit FORWARD migration set
   so `REPOSITORY HISTORY == CERTIFIED LIVE HISTORY` becomes achievable.
4. Only after 2+3 (and after recovering the remaining 221 ledger rows) may `db push` be revisited as a no-op check.
```
