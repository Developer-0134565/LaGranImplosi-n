# RANKING / POINTS — LA GRAN IMPLOSIÓN

> State, authority, contracts, formula, OGameX comparison, tests and gaps for `players.points` / `players.rank`.
> Operational status: [`../PROJECT_CONTEXT_PROMPT.md`](../PROJECT_CONTEXT_PROMPT.md). Related:
> [`README_COMBAT_ENGINE.md`](README_COMBAT_ENGINE.md) (debris), [`README_ECONOMY.md`](README_ECONOMY.md)
> (cost helpers used as prices), [`../reference/README_OGAMEX_LGI_MAP.md`](../reference/README_OGAMEX_LGI_MAP.md).

## 1. State (2026-09-26)

```text
BEFORE  players.points = 0 and players.rank IS NULL for all 567 players. No trigger and no function wrote
        either column; the only reader was get_universe_top1_points, consumed by
        calculate_expedition_resource_cap → every universe resolved the LOWEST bracket
        (min_top1_points 0 → max_resource_find 40 000). A live mechanic was pinned to its floor value.
AFTER   migration 20260926091604_add_player_ranking_contract (LIVE, forward-only, no schema change):
        calculate_player_points · recalculate_player_points · recalculate_universe_ranking ·
        get_universe_ranking. Certified by supabase/tests/player_ranking_points.sql — 17 PASS + 1 INFO,
        LIVE 2026-09-26, inside a rollback transaction with zero residue.
```

## 2. Authority

| Function | Role | ACL |
|---|---|---|
| `calculate_player_points(player)` | read-only raw investment (no writes, no rounding) | `postgres`/`service_role` |
| `recalculate_player_points(player)` | materialises `points` for one player | `postgres`/`service_role` |
| `recalculate_universe_ranking(universe)` | materialises `points` + `rank` for a universe, returns rows updated | `postgres`/`service_role` |
| `get_universe_ranking(universe, limit)` | **client read contract** (rank, player, type, points, is_current_player) | `authenticated`/`service_role` (never `anon`) |

Every recalculation is idempotent: points are a pure function of the current assets, so replaying it cannot
accumulate. It writes **only** `players.points` / `players.rank` — never resources, ships, buildings, queues or
fleets (asserted by digest in the fixture).

## 3. Formula

```text
raw(player) = Σ buildings   Σ_{i=1..level} (metal+crystal+deuterium) of calculate_building_cost(id, i)
            + Σ research    Σ_{i=1..level} (metal+crystal+deuterium) of calculate_research_cost(id, i)
            + Σ planet_ships     quantity × (base_metal+base_crystal+base_deuterium)
            + Σ in-transit ships quantity × base price        (fleet status NOT IN (COMPLETED, CANCELLED))
            + Σ planet_defenses  quantity × (metal_cost+crystal_cost+deuterium_cost)

points(player) = floor(raw(player) / 1000)                     (bigint in players.points)
rank(player)   = rank() OVER (ORDER BY points DESC)            (integer; ties share a rank)
```

Notes that matter:

* prices come from the **same certified helpers the engine charges with** — no second price model exists;
* **in-progress queues are not scored** (OGameX parity: it sums planet objects and *unprocessed* missions, so
  a queued item is not counted until it completes);
* destroyed planets (`planets.is_destroyed`) are excluded from the building/ship/defence terms;
* the per-level accumulation is the classic OGame rule (a level-L building contributes the sum of levels 1..L).

## 4. Lifecycle and consumers

```text
producer of the data   recalculate_universe_ranking(universe)   (manual/ops today — see GAPS)
consumer               get_universe_ranking(universe, limit)    (client read contract, no recomputation)
consumer (engine)      get_universe_top1_points(universe) → calculate_expedition_resource_cap(universe)
                       → the max_resource_find bracket of expedition resource finds
```

Verified coupling (fixture assertion 7): with a top-1 player at 1 258 290 points the expedition resource cap
resolves to **1 800 000** instead of the 40 000 floor the dead field produced.

## 5. OGameX comparison (`7c420bad3478d7099791e1f33c920e9ff92822e8`)

```text
LGI actual   players.points (bigint) + players.rank (integer); the four functions above; no per-bucket columns.
OGameX       app/Services/HighscoreService.php + Console/Commands/Scheduler/GenerateHighscores.php: one
             highscores row per player with general/economy/research/military and a *_rank per column,
             refreshed by a scheduled command iterating users in chunks of 200.
Verified     score = floor(resources_spent.sum() / 1000) — read verbatim in getPlayerFleetMissionScore();
             ships on unprocessed missions ARE counted (`if ($mission->processed) continue;`).
Unverified   the OGameX region that performs the per-level accumulation could not be read from this
             environment (the 16.8 kB file is cut by the fetch window): recorded as UNVERIFIED EQUIVALENCE
             instead of being claimed as byte-identical.
Decision     ADAPTATION — a single `points` column plus `rank()` instead of four buckets; no schema change.
             INTENTIONAL — AI players are ranked like any other player (OGameX hides admins; LGI has no role
             concept and inventing an exclusion was refused). `player_type` is exposed so a UI can filter.
```

## 6. Tests

`supabase/tests/player_ranking_points.sql` — 17 PASS + 1 INFO (LIVE 2026-09-26, ROLLBACK):

```text
1-4    raw investment for a synthetic building (cumulative levels), for research, and for a zero-asset
       player; points = floor(raw/1000) materialised into players.points
5-5b   the authenticated player matches a component-by-component recomputation; the in-transit term is part of
       the function (structural assertion — this universe has no fleet row)
6-7    universe recalculation: rank 1 for the top score, tied players share a rank, no unranked player, and the
       live expedition-cap consumer moves off its floor bracket
8-9    materialised once and identical on replay (digests); every asset digest is conserved
10     rejections (unknown player / unknown universe) leave points and ranks untouched
11     read contract: limit honoured and clamped to 1..500; `is_current_player` true only for the caller's
       player, and never when there is no session
12     ACL: clients read, only service_role recalculates
LIMITATION  single-session harness; concurrency is not executed.
```

## 7. GAPS

```text
* Scheduling: NO cron/job calls the recalculation. The contract is idempotent and ready; wiring it (cron entry
  or heartbeat hook) is deliberately NOT done here. The exact call is:
      select public.recalculate_universe_ranking('<universe uuid>');
* No UI: `src/**` does not read points/rank and was not modified (the read contract is ready for a future UI).
* Per-bucket scores (economy / research / military) are NOT implemented: the LGI schema has no columns for them.
* No alliance ranking (explicitly out of scope for this block).
```

## 9. SCHEDULER WIRED + UI (2026-09-26)

The gap of §7 ("NO cron/job calls the recalculation") and of §7's "No UI" are closed.

```text
Migration 20260926123000_ranking_refresh_scheduler (LIVE 2026-09-26)
  run_ranking_worker()  internal entry point (SECURITY DEFINER; EXECUTE postgres/service_role only):
                        iterates the ACTIVE universes and calls the certified, idempotent
                        `recalculate_universe_ranking(universe)` once per universe, returning
                        (universe_id, players_ranked) per universe.
  pg_cron               jobname 'lagranimplosion-ranking-refresh', schedule '*/5 * * * *' — the OGameX cadence
                        (`routes/console.php` schedules GenerateHighscores/GenerateHighscoreRanks every 5 minutes
                        @ 7c420bad), so no arbitrary constant was invented. The EXISTING pg_cron list is reused;
                        no parallel scheduler was created.
```

Consumer unlocked (fixture assertion 4): with a real top player the expedition resource cap resolves to
**1 800 000** instead of the **40 000** floor bracket the dead field produced — `get_universe_top1_points` →
`calculate_expedition_resource_cap`.

UI: `get_universe_ranking` is rendered by `src/GameplayEnginePanel.tsx` (`RankingPanel`, top 10 with the
`TÚ` marker) mounted on the overview screen. The UI holds no authority: it only displays what the contract returns.

Tests: `supabase/tests/ranking_refresh_worker.sql` — **6 PASS + 1 INFO, LIVE 2026-09-26, ROLLBACK** (worker covers
every active universe, points/rank materialised, idempotent replay, cap consumer off its floor, pg_cron job present
and active with the 5-minute schedule, ACL).

Remaining gaps:

```text
* Per-bucket scores (economy/research/military) were implemented on 2026-09-26 (see «Category scores» below);
  alliance ranking stays OUT OF SCOPE (there is no alliance subsystem).
* AI players are ranked like any other player (INTENTIONAL, see §5).
* The freshly added function signatures in `src/lib/database.types.ts` were written by hand; regenerating the file
  with the Supabase CLI needs credentials this environment does not have.
```


```text
* Whether to schedule the refresh, and at which cadence — the mechanic works without it; the data only stays
  stale. Not invented here.
* Whether AI players should be visible in the ranking. They are ranked today (see §5, INTENTIONAL).
```


## Category scores (economy / research / military) — 2026-09-26

`20260926170000_ranking_category_scores.sql` implements the OGameX `HighscoreService` categories (types 1/2/3):

* `players.economy_points / research_points / military_points` (+ `economy_rank / research_rank /
  military_rank`). The certified general `points` / `rank` contract is untouched.
* `calculate_player_category_scores(player)` composes the buckets exactly as the OGameX docblocks and code do,
  flooring every component (÷1000) per planet and per transit block:
  * **economy** = buildings + stations (100 %) + defenses (100 %) + civil ships (50 %), plus civil ships in
    transit (50 %);
  * **research** = cumulative cost of every owned research level;
  * **military** = defenses (100 %) + military ships (100 %) + civil ships (50 %), plus in-transit military
    (100 %) and civil (50 %).
* The military/civil split is **data-driven**: `ship_definitions.ship_type = 'combat'` are the OGameX
  `MilitaryShipObjects` (light/heavy fighter, cruiser, battleship, battlecruiser, bomber, destroyer, deathstar,
  reaper) and every other type (civil/transport/support) maps 1:1 to the OGameX `CivilShipObjects` (small/large
  cargo, colony ship, recycler, espionage probe, solar satellite, crawler, pathfinder). No new classification was
  invented.
* OGameX documents phalanx and jump gate at **50 %** but its loop still counts them at 100 % because its moon
  wiring is a TODO; LGI has moons, so the documented 50 % weight is applied (they are excluded from the 100 %
  building sum). This is the only deliberate divergence and it is recorded in the migration header.
* Refresh: `recalculate_universe_ranking` (patched, used by the pg_cron `run_ranking_worker`) and
  `recalculate_player_points` (patched) fill the buckets and recompute every category rank, so the ranks can
  never drift from the scores.
* Read contract: `get_universe_ranking_by_category(universe, 'GENERAL'|'ECONOMY'|'RESEARCH'|'MILITARY', limit)`;
  the certified `get_universe_ranking` stays available and unchanged. ACL: `authenticated` + `service_role`
  only (no anon bypass).
* UI: the ranking panel has a category selector (GENERAL/ECONOMY/RESEARCH/MILITARY); the panel still decides
  nothing, it only renders the server answer.

Fixture `supabase/tests/ranking_category_scores.sql`: **8/8 PASS LIVE** (transactional, `ROLLBACK`, zero
residue) with a moon, a station, defenses, combat/civil/support ships, research and an in-transit fleet; it also
asserts that the certified general ranking keeps working. LIMITATION: the worker is invoked directly instead of
waiting for the cron tick.

