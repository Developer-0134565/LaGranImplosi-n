-- RANKING / POINTS — first functional contract for `players.points` and `players.rank` (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- Reality before this migration (measured LIVE 2026-09-26): `players.points = 0` for all 567 players,
-- `players.rank IS NULL` for all of them, NO trigger and NO function wrote either column, and the only
-- reader was `get_universe_top1_points` — consumed by `calculate_expedition_resource_cap`, which therefore
-- always resolved the lowest `expedition_resource_caps` bracket (min_top1_points 0 → 40 000). So a live,
-- implemented mechanic (expedition resource finds) was silently pinned to its floor value.
--
-- OGameX evidence (HighscoreService.php + Console/Commands/Scheduler/GenerateHighscores.php @ 7c420bad):
--   * per-player score = floor(sum of asset costs / 1000) — verified verbatim in
--     `getPlayerFleetMissionScore()`: `return (int)floor($resources_spent->sum() / 1000);`
--   * ships on ACTIVE missions are counted too (`if ($mission->processed) continue;` → unprocessed missions
--     add their ship prices), which LGI mirrors by summing `fleet_movement_ships` of fleets whose status is
--     neither COMPLETED nor CANCELLED;
--   * `GenerateHighscores` materialises one row per player with `general`/`economy`/`research`/`military`.
--     LGI stores a single `points` value plus `rank` (LGI schema, no per-bucket columns) — INTENTIONAL
--     ADAPTATION: no schema change is invented here.
--   * the *per-level accumulation* (a level-L building contributing the sum of levels 1..L) is the classic
--     OGame rule and is what LGI implements; the OGameX code region that performs that loop could not be read
--     from this environment (the file is truncated by the fetch window) → recorded as an UNVERIFIED
--     EQUIVALENCE in README_RANKING.md instead of being claimed as byte-identical.
--
-- Authority and safety: the three functions are SECURITY DEFINER. Recalculation writes only `players.points`
-- / `players.rank` and is idempotent (pure function of the current assets); the client read contract exposes
-- no identity the caller could choose (`is_current_player` is derived from `auth.uid()`).
-- NO schema change, NO trigger, NO change to any certified engine function, and nothing is scheduled here:
-- the ranking is refreshed by calling `recalculate_universe_ranking(universe)` (scheduler wiring is a
-- documented GAP, not invented).
-- Certified by `supabase/tests/player_ranking_points.sql`.

create or replace function public.calculate_player_points(p_player_id uuid)
returns numeric
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
    select
        coalesce((
            select sum(bc.metal + bc.crystal + bc.deuterium)
            from public.planet_buildings pb
            join public.planets p
              on p.id = pb.planet_id
             and p.player_id = p_player_id
             and p.is_destroyed = false
            cross join lateral generate_series(1, pb.level) AS lvl
            cross join lateral public.calculate_building_cost(pb.building_id, lvl) bc
        ), 0)
        +
        coalesce((
            select sum(rc.metal + rc.crystal + rc.deuterium)
            from public.player_research pr
            cross join lateral generate_series(1, pr.level) AS lvl
            cross join lateral public.calculate_research_cost(pr.research_id, lvl) rc
            where pr.player_id = p_player_id
        ), 0)
        +
        coalesce((
            select sum(ps.quantity * (sd.base_metal + sd.base_crystal + sd.base_deuterium))
            from public.planet_ships ps
            join public.planets p on p.id = ps.planet_id and p.player_id = p_player_id
            join public.ship_definitions sd on sd.id = ps.ship_id
        ), 0)
        +
        coalesce((
            select sum(fms.quantity * (sd.base_metal + sd.base_crystal + sd.base_deuterium))
            from public.fleet_movements fm
            join public.fleet_movement_ships fms on fms.fleet_id = fm.id
            join public.ship_definitions sd on sd.id = fms.ship_id
            where fm.player_id = p_player_id
              and fm.status not in ('COMPLETED', 'CANCELLED')
        ), 0)
        +
        coalesce((
            select sum(pd.quantity * (dd.metal_cost + dd.crystal_cost + dd.deuterium_cost))
            from public.planet_defenses pd
            join public.planets p on p.id = pd.planet_id and p.player_id = p_player_id
            join public.defense_definitions dd on dd.id = pd.defense_id
        ), 0);
$function$;

comment on function public.calculate_player_points(uuid) is
$c$Raw investment of a player = completed building levels + completed research levels + planet ships +
in-transit ships + planet defences, each priced with the same certified cost helpers the engine charges with.
Read-only and side-effect free. Points are this value / 1000 (OGameX HighscoreService parity). Internal:
EXECUTE is postgres/service_role only.$c$;

create or replace function public.recalculate_player_points(p_player_id uuid)
returns bigint
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_points bigint;
begin
    if not exists (select 1 from public.players pl where pl.id = p_player_id) then
        raise exception 'PLAYER_NOT_FOUND: %', p_player_id;
    end if;

    v_points := floor(public.calculate_player_points(p_player_id) / 1000)::bigint;

    update public.players pl set points = v_points where pl.id = p_player_id;

    return v_points;
end;
$function$;

comment on function public.recalculate_player_points(uuid) is
$c$Materialises `players.points = floor(calculate_player_points(player) / 1000)` for one player
(OGameX: `floor(sum / 1000)`). Idempotent: points are a pure function of the current assets, so replaying it
never accumulates. It writes ONLY `players.points` — never resources, ships, buildings or queues.
Manual refresh surface for operators/service_role.$c$;

create or replace function public.recalculate_universe_ranking(p_universe_id uuid)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_updated integer;
begin
    if not exists (select 1 from public.universes u where u.id = p_universe_id) then
        raise exception 'UNIVERSE_NOT_FOUND: %', p_universe_id;
    end if;

    with computed as (
        select pl.id as player_id,
               floor(public.calculate_player_points(pl.id) / 1000)::bigint as points
        from public.players pl
        where pl.universe_id = p_universe_id
    ),
    ranked as (
        select c.player_id,
               c.points,
               (rank() over (order by c.points desc))::integer as rnk
        from computed c
    )
    update public.players pl
       set points = r.points,
           rank = r.rnk
      from ranked r
     where pl.id = r.player_id;

    get diagnostics v_updated = row_count;
    return v_updated;
end;
$function$;

comment on function public.recalculate_universe_ranking(uuid) is
$c$Refreshes `players.points` and `players.rank` for every player of a universe in one statement. Rank uses
SQL `rank()` over `points DESC`, so tied players share a rank (OGame highscore convention) and the result is
deterministic for a given state. Idempotent and replay-safe: no resource, ship, building, queue or fleet state
is read for writing. AI players are ranked like any other player — no exclusion rule is invented; the client
contract exposes `player_type` so a UI can filter. Scheduling is NOT part of this migration (documented GAP).
Manual refresh surface for operators/service_role.$c$;

create or replace function public.get_universe_ranking(p_universe_id uuid, p_limit integer default 100)
returns table(
    out_rank integer,
    out_player_id uuid,
    out_username text,
    out_player_type text,
    out_points bigint,
    out_is_current_player boolean
)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
    select pl.rank,
           pl.id,
           pl.username,
           pl.player_type,
           pl.points,
           (pl.user_id is not null and pl.user_id = auth.uid())
    from public.players pl
    where pl.universe_id = p_universe_id
    order by pl.rank nulls last, pl.points desc, pl.id
    limit greatest(1, least(coalesce(p_limit, 100), 500));
$function$;

comment on function public.get_universe_ranking(uuid, integer) is
$c$Client read contract for the ranking (rank, player, type, points, whether the row is the caller's player).
Reads the materialised `players.points` / `players.rank`, never recomputes them, and derives
`is_current_player` from `auth.uid()` — the caller cannot choose an identity. Limit is clamped to 1..500.$c$;

revoke all on function public.calculate_player_points(uuid) from public;
revoke all on function public.calculate_player_points(uuid) from anon;
revoke all on function public.calculate_player_points(uuid) from authenticated;
grant execute on function public.calculate_player_points(uuid) to service_role;

revoke all on function public.recalculate_player_points(uuid) from public;
revoke all on function public.recalculate_player_points(uuid) from anon;
revoke all on function public.recalculate_player_points(uuid) from authenticated;
grant execute on function public.recalculate_player_points(uuid) to service_role;

revoke all on function public.recalculate_universe_ranking(uuid) from public;
revoke all on function public.recalculate_universe_ranking(uuid) from anon;
revoke all on function public.recalculate_universe_ranking(uuid) from authenticated;
grant execute on function public.recalculate_universe_ranking(uuid) to service_role;

revoke all on function public.get_universe_ranking(uuid, integer) from public;
revoke all on function public.get_universe_ranking(uuid, integer) from anon;
grant execute on function public.get_universe_ranking(uuid, integer) to authenticated;
grant execute on function public.get_universe_ranking(uuid, integer) to service_role;

