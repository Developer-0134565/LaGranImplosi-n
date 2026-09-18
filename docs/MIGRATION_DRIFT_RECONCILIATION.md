# MIGRATION DRIFT RECONCILIATION — LA GRAN IMPLOSIÓN

> Drift mission 2026-09-18. Question answered: **why was LIVE ahead of this repository and how is the
> traceability recovered without losing the certified state.** Read-only against LIVE: no `db push`,
> no `migration repair`, no DB mutation.

## 1. What the drift really is (measured, not assumed)

| Metric | Value |
|---|---|
| Local migration files **before** this mission | 30 |
| Local migration files **after** recovery | 40 |
| LIVE ledger rows | 260 (`20260912092555` … `20260918100000`) |
| Ledger rows **with** the original SQL payload | **260 / 260** (100 % recoverable) |
| Ledger rows with **no local file** | **249 before → 239 after** |
| Local files whose version is **not** in the ledger | **19** (reverse drift) |
| Local files added by this mission (declared 10) | 10 |

```text
The repository folder never contained the full applied history: it held 30 of 260 migrations.
The "10 missing" of the fleet audit are the newest, highest-risk slice of a much larger gap, and every
one of them was still recoverable verbatim from the LIVE ledger.
```

## 2. The 10 declared migrations (recovered verbatim)

| version | name | objects touched |
|---|---|---|
| 20260918085406 | (ledger name `20260918110000_add_can_start_research_contract`) | `can_research` (SECURITY DEFINER) + research contract RPCs |
| 20260918094108 | `harden_shipyard_queue_processing_ownership` | `process_shipyard_queue_until` |
| 20260918094128 | `lock_internal_shipyard_queue_until` | `process_shipyard_queue_until` (ACL) |
| 20260918094440 | `use_canonical_fleet_travel_time_in_dispatch` | `start_fleet`, `start_fleet_mixed` (DO-block patch) |
| 20260918094959 | `add_ogame_drive_speed_and_fuel_logic` | `get_player_research_level`, `calculate_player_ship_speed`, `calculate_player_fleet_fuel_for_distance` |
| 20260918095005 | `apply_drive_tech_to_fleet_dispatch` | `start_fleet`, `start_fleet_mixed`, drive/fuel helpers (DO-block patch) |
| 20260918095009 | `lock_internal_drive_calculation_helpers` | REVOKEs on `get_player_research_level`, `calculate_player_ship_speed`, … |
| 20260918095029 | `fix_zero_level_drive_research_lookup` | `get_player_research_level` |
| 20260918095306 | `harden_fleet_movement_idempotency_and_processing` | unique `combat_battles_fleet_id_uq`, `fleet_movements_*` indexes, `process_fleet_movements`, REVOKE |
| 20260918095315 | `deduplicate_fleet_event_indexes` | drops legacy `idx_fleet_movements_outbound_arrival` / `_returning` |

**Method (reproducible, no invention):** the applied-migration ledger stores the submitted payload in
`supabase_migrations.schema_migrations.statements` (one element per `apply_migration` call). Each file
was written as `<version>_<name>.sql` with a provenance header
(`RECOVERED MIGRATION … do not re-apply`). Nothing was reconstructed from memory.

## 3. Verification against the certified LIVE state

Bodies compared as `md5(whitespace-normalised body)` of `pg_get_functiondef` (LIVE) vs the same body
extracted from the local files:

```text
MATCH   can_research                          (20260918085406_add_can_start_research_contract.sql)
MATCH   get_player_research_level             (20260918095029_fix_zero_level_drive_research_lookup.sql)
MATCH   calculate_expedition_delay_seconds    (20260918100000_converge_expedition_hold_to_mission_class.sql)
MATCH   process_shipyard_queue_until          (20260918094128_lock_internal_shipyard_queue_until.sql)
DIFF    calculate_player_ship_speed           → superseded by the patcher 20260918095005 (recovered)
DIFF    calculate_player_fleet_fuel_for_distance → superseded by the same patcher (recovered)
ABSENT  calculate_player_ship_fuel_consumption / calculate_fleet_travel_time /
        calculate_mission_fleet_speed_multiplier → their creating migrations (e.g. 20260917040727
        centralize_universe_scaling_and_fleet_travel_formula) belong to the older 239-row gap;
        LIVE bodies remain the reference until they are recovered.
PATCHED start_fleet             → LIVE contains calculate_fleet_travel_time + calculate_player_ship_speed ✔
PATCHED start_fleet_mixed       → LIVE contains calculate_mission_fleet_speed_multiplier ✔
PATCHED start_colonize_fleet    → LIVE contains calculate_mission_fleet_speed_multiplier ✔
```

The two DIFFs are **explained and closed**: newer migrations inside the same recovered set patch those
functions dynamically (`pg_get_functiondef` + `replace`), so the earlier static body is not expected to
match LIVE. The certified expedition fix (`20260918100000`) matches LIVE after normalisation.

## 4. Reverse drift (the real remaining `db push` hazard)

19 local files carry a version prefix that **does not exist in the ledger**, for example:

```text
local 20260913044000_harden_internal_rpc_permissions.sql         → ledger 20260913043732 (same name)
local 20260915050000_add_guest_temporal_ui_sync_rpc.sql          → ledger 20260915045311 (same name)
local 20260918020000_register_universe_evolution_monitor.sql     → ledger 20260918015016 (same name)
local 20260916021500_fix_attack_arrival_temporal_order.sql       → ledger 20260916020648 (ledger name carries the prefix)
local 20260915_add_sidebar_social_data_v1.sql                    → ledger 20260915032657 (malformed 14-digit prefix)
(14 confirmed by exact name match + 5 whose ledger name embeds the intended version)
```

All 19 **were applied** (the ledger records them under the version captured at apply time), so no
content is lost. But the CLI compares versions, so a naive `db push` from this folder would treat those
19 as *pending* and re-apply already-applied DDL on top of the certified state.

## 5. Rules until this is closed

```text
NEVER run `supabase db push` from this copy
NEVER run `supabase db reset`
      (and do not use `migration repair` as a workaround before §6.1 is decided)
SAFE  read the LIVE ledger / definitions; edit repository files locally
SAFE  add recovered files whose versions already exist in the ledger (the CLI would skip them)
```

## 6. Next attack (bounded, suggested order)

1. Re-label (or move to an `applied/` archive) the 19 phantom local files so that every local version
   prefix exists in the ledger → removes the double-apply hazard.
2. Recover the remaining **239** ledger-only migrations verbatim with the same mechanism
   (`statements` payload): 100 % of them carry SQL, so `LOCAL = LIVE` is reachable without inventing
   anything. Validate each against LIVE as in §3.
3. Only after 1 + 2: treat the folder as authoritative again and record the recovery in
   `PROJECT_CONTEXT_PROMPT.md`.

## Inverse drift audit

Measured 2026-09-18 (detail and full matrix: [`MIGRATION_INVERSE_DRIFT_AUDIT.md`](MIGRATION_INVERSE_DRIFT_AUDIT.md)).

```text
local files : 40          LIVE ledger rows : 260 (all with SQL payload)
EXACT 19 · EXACT_VERSION_COSMETIC 2 · VERSION_DRIFT 11 · VERSION_DRIFT_COSMETIC 4
VERSION_AND_NAME_DRIFT 1 · DUPLICATE 0 · REAL_DIVERGENCE 2 · AMBIGUOUS 1
local versions absent from LIVE (= re-applied by a naive push) : 19
```

- **16 of those 19 files are SQL-equivalent** to the ledger payload (formatting-only differences:
  whitespace, `AS` aliases, `AND` clause order) → renameable to the ledger version in a future mission.
- **2 REAL_DIVERGENCE**: `20260916020230_harden_fleet_arrival_queue_timestamps.sql` is a subset of the
  applied payload (which also defines `resolve_attack_arrival` / `resolve_espionage_arrival`), and
  `20260918020000_register_universe_evolution_monitor.sql` is a superset (two extra REVOKEs).
- **1 AMBIGUOUS**: `20260918020300_allow_authenticated_universe_evolution_monitor.sql` has **no** ledger
  row; its intended end state is already present in LIVE (ACL: PUBLIC revoked, anon+authenticated granted).
- **Decision: STOP — nothing renamed, moved or repaired** (mission gate: REAL_DIVERGENCE = 0 and
  AMBIGUOUS = 0 required). `supabase db push` and `migration repair` remain PROHIBITED from this copy.

### Resolution (same day, blocker mission)

The three blockers were closed with ledger evidence (`MIGRATION_INVERSE_DRIFT_AUDIT.md` §8):
`20260916020215` and `20260918015016` recovered VERBATIM, the three blocking local files preserved as
`*.sql.obsolete` with provenance headers, and the remaining 16 SQL-equivalent files re-labelled to the
version LIVE recorded.

```text
after : 39 local files · REAL_DIVERGENCE 0 · AMBIGUOUS 0 · LOCAL - LIVE = EMPTY · LIVE - LOCAL = 221
OPEN  : 2 out-of-band ACL changes (private + public monitor) need a FORWARD migration for
        reproducibility; 221 ledger rows still need recovery (next mission).
```

## 7. Provenance of this reconciliation

```text
inputs : supabase_migrations.schema_migrations (260 rows: version/name/statements/created_by)
         local supabase/migrations (40 files), git history (all branches), 2 stashes,
         _LGI_CONSOLIDATION_BACKUP_2026-09-18, LaGranImplosi-n__CLONE_A_QUARANTINE
finding: the fleet migrations were never in any local copy or commit — they existed only as
         apply_migration payloads, which is why the folder silently fell behind.
output : 10 recovered files + this document; LIVE untouched (no push, no repair, no DDL).
```

