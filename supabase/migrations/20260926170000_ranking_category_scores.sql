-- =====================================================================
-- RANKING CATEGORY SCORES (economy / research / military) — LGI ↔ OGameX
-- =====================================================================
-- OGameX reference (structural):
--   app/Services/HighscoreService.php :: type 1 = economy, 2 = research, 3 = military;
--       getPlayerScoreEconomy/Military/Research, getPlayerFleetMissionScore*
--   app/Services/PlanetService.php    :: getPlanetScoreEconomy() / getPlanetMilitaryScore()
--   app/Services/PlayerService.php    :: getResearchScore()
--   app/GameObjects/CivilShipObjects.php + MilitaryShipObjects.php (the ship split)
--
-- Composition adopted from the OGameX docblocks + code:
--   economy  = per planet: buildings + stations (100 %) + defenses (100 %) + civil ships (50 %);
--              plus civil ships currently in transit (50 %)
--   research = the cumulative cost of every research level the player owns
--   military = per planet: defenses (100 %) + military ships (100 %) + civil ships (50 %);
--              plus in-transit military ships (100 %) and civil ships (50 %)
-- Every component is floored to points (÷1000) per planet and per transit block, exactly like OGameX.
--
-- LGI adaptations (documented, not invented):
--   * The ship split is data-driven and matches OGameX 1:1: `ship_definitions.ship_type = 'combat'` are the
--     OGameX MilitaryShipObjects (light/heavy fighter, cruiser, battleship, battlecruiser, bomber, destroyer,
--     deathstar, reaper) and every other type (civil/transport/support) is the OGameX CivilShipObjects
--     (small/large cargo, colony ship, recycler, espionage probe, solar satellite, crawler, pathfinder).
--   * OGameX documents "50 % phalanx and jump gate" but its loop still counts them at 100 % because its moon
--     wiring is a TODO. LGI has moons, so the documented 50 % weight is applied and those two stations are
--     excluded from the 100 % building sum (the alternative would make OGameX's own docblock wrong).
--   * Research cumulative cost uses LGI `calculate_research_cost` (OGameX uses getObjectCumulativeCost).
-- =====================================================================

alter table public.players
    add column if not exists economy_points bigint not null default 0,
    add column if not exists research_points bigint not null default 0,
    add column if not exists military_points bigint not null default 0,
    add column if not exists economy_rank integer,
    add column if not exists research_rank integer,
    add column if not exists military_rank integer;

comment on column public.players.economy_points is
    'OGameX HighscoreService type 1: buildings+stations 100 %, defenses 100 %, civil ships 50 % (+ in transit 50 %).';
comment on column public.players.research_points is
    'OGameX HighscoreService type 2: cumulative research cost of every owned research level.';
comment on column public.players.military_points is
    'OGameX HighscoreService type 3: defenses 100 %, military ships 100 %, civil ships 50 % (in transit: 100/50).';

-- ---------------------------------------------------------------------
-- Bucket calculator. Pure, per player, floored per component like OGameX.
-- ---------------------------------------------------------------------
create or replace function public.calculate_player_category_scores(p_player_id uuid)
returns table(economy_points bigint, research_points bigint, military_points bigint)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
with planets_of_player as (
    select p.id
    from public.planets p
    where p.player_id = p_player_id and p.is_destroyed = false
),
building_cost as (
    select pop.id as planet_id,
           coalesce((select sum(bc.metal + bc.crystal + bc.deuterium)
                       from public.planet_buildings pb
                       cross join lateral generate_series(1, pb.level) lvl
                       cross join lateral public.calculate_building_cost(pb.building_id, lvl) bc
                      where pb.planet_id = pop.id
                        and pb.building_id not in ('sensor_phalanx', 'jump_gate')), 0) as full_cost,
           coalesce((select sum(bc.metal + bc.crystal + bc.deuterium)
                       from public.planet_buildings pb
                       cross join lateral generate_series(1, pb.level) lvl
                       cross join lateral public.calculate_building_cost(pb.building_id, lvl) bc
                      where pb.planet_id = pop.id
                        and pb.building_id in ('sensor_phalanx', 'jump_gate')), 0) as station_cost,
           coalesce((select sum(pd.quantity * (dd.metal_cost + dd.crystal_cost + dd.deuterium_cost))
                       from public.planet_defenses pd
                       join public.defense_definitions dd on dd.id = pd.defense_id
                      where pd.planet_id = pop.id), 0) as defense_cost,
           coalesce((select sum(ps.quantity * (sd.base_metal + sd.base_crystal + sd.base_deuterium))
                       from public.planet_ships ps
                       join public.ship_definitions sd on sd.id = ps.ship_id
                      where ps.planet_id = pop.id and sd.ship_type = 'combat'), 0) as military_ships,
           coalesce((select sum(ps.quantity * (sd.base_metal + sd.base_crystal + sd.base_deuterium))
                       from public.planet_ships ps
                       join public.ship_definitions sd on sd.id = ps.ship_id
                      where ps.planet_id = pop.id and coalesce(sd.ship_type, 'civil') <> 'combat'), 0) as civil_ships
    from planets_of_player pop
),
research_cost as (
    select coalesce(sum(rc.metal + rc.crystal + rc.deuterium), 0) as cost
    from public.player_research pr
    cross join lateral generate_series(1, pr.level) lvl
    cross join lateral public.calculate_research_cost(pr.research_id, lvl) rc
    where pr.player_id = p_player_id
),
transit_cost as (
    select coalesce(sum(case when sd.ship_type = 'combat'
                             then fms.quantity * (sd.base_metal + sd.base_crystal + sd.base_deuterium)
                             else 0 end), 0) as military,
           coalesce(sum(case when coalesce(sd.ship_type, 'civil') <> 'combat'
                             then fms.quantity * (sd.base_metal + sd.base_crystal + sd.base_deuterium)
                             else 0 end), 0) as civil
    from public.fleet_movements fm
    join public.fleet_movement_ships fms on fms.fleet_id = fm.id
    join public.ship_definitions sd on sd.id = fms.ship_id
    where fm.player_id = p_player_id
      and fm.status not in ('COMPLETED', 'CANCELLED')
)
select
    coalesce((select sum(floor((b.full_cost + b.defense_cost + 0.5 * b.civil_ships + 0.5 * b.station_cost) / 1000))::bigint
                from building_cost b), 0)
    + coalesce((select floor((0.5 * t.civil) / 1000)::bigint from transit_cost t), 0),
    coalesce((select floor(r.cost / 1000)::bigint from research_cost r), 0),
    coalesce((select sum(floor((b.defense_cost + b.military_ships + 0.5 * b.civil_ships + 0.5 * b.station_cost) / 1000))::bigint
                from building_cost b), 0)
    + coalesce((select floor((t.military + 0.5 * t.civil) / 1000)::bigint from transit_cost t), 0);
$function$;

-- ---------------------------------------------------------------------
-- CERTIFIED-CONTRACT PATCH 1/2 — recalculate_universe_ranking() fills the three buckets
-- and their per-category ranks. The general `points`/`rank` contract is untouched.
-- ---------------------------------------------------------------------
do $patch$
declare
    v_src text;
    v_old text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'recalculate_universe_ranking';

    if v_src is null then
        raise exception 'PATCH TARGET MISSING: recalculate_universe_ranking';
    end if;
    if position('calculate_player_category_scores' in v_src) > 0 then
        return;
    end if;

    v_old := '    with computed as (
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
     where pl.id = r.player_id;';

    v_new := '    with computed as (
        select pl.id as player_id,
               floor(public.calculate_player_points(pl.id) / 1000)::bigint as points,
               cs.economy_points,
               cs.research_points,
               cs.military_points
        from public.players pl
        cross join lateral public.calculate_player_category_scores(pl.id) cs
        where pl.universe_id = p_universe_id
    ),
    ranked as (
        select c.player_id,
               c.points,
               c.economy_points,
               c.research_points,
               c.military_points,
               (rank() over (order by c.points desc))::integer as rnk,
               (rank() over (order by c.economy_points desc))::integer as economy_rnk,
               (rank() over (order by c.research_points desc))::integer as research_rnk,
               (rank() over (order by c.military_points desc))::integer as military_rnk
        from computed c
    )
    update public.players pl
       set points = r.points,
           rank = r.rnk,
           economy_points = r.economy_points,
           research_points = r.research_points,
           military_points = r.military_points,
           economy_rank = r.economy_rnk,
           research_rank = r.research_rnk,
           military_rank = r.military_rnk
      from ranked r
     where pl.id = r.player_id;';

    if position(v_old in v_src) = 0 then
        raise exception 'PATCH ANCHOR NOT FOUND: recalculate_universe_ranking CTE block';
    end if;
    execute replace(v_src, v_old, v_new);
end;
$patch$;

-- ---------------------------------------------------------------------
-- CERTIFIED-CONTRACT PATCH 2/2 — recalculate_player_points() refreshes the buckets too
-- (the per-category ranks are recomputed for the whole universe, so they can never drift).
-- ---------------------------------------------------------------------
do $patch$
declare
    v_src text;
    v_old text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'recalculate_player_points';

    if v_src is null then
        raise exception 'PATCH TARGET MISSING: recalculate_player_points';
    end if;
    if position('calculate_player_category_scores' in v_src) > 0 then
        return;
    end if;

    v_old := '    update public.players pl set points = v_points where pl.id = p_player_id;';

    v_new := '    update public.players pl
       set points = v_points,
           economy_points = cs.economy_points,
           research_points = cs.research_points,
           military_points = cs.military_points
      from public.calculate_player_category_scores(p_player_id) cs
     where pl.id = p_player_id;

    with category_ranks as (
        select pl.id as player_id,
               (rank() over (order by pl.economy_points desc))::integer as economy_rnk,
               (rank() over (order by pl.research_points desc))::integer as research_rnk,
               (rank() over (order by pl.military_points desc))::integer as military_rnk
        from public.players pl
        where pl.universe_id = (select p2.universe_id from public.players p2 where p2.id = p_player_id)
    )
    update public.players pl
       set economy_rank = r.economy_rnk,
           research_rank = r.research_rnk,
           military_rank = r.military_rnk
      from category_ranks r
     where pl.id = r.player_id;';

    if position(v_old in v_src) = 0 then
        raise exception 'PATCH ANCHOR NOT FOUND: recalculate_player_points update';
    end if;
    execute replace(v_src, v_old, v_new);
end;
$patch$;

-- ---------------------------------------------------------------------
-- Read contract. The certified `get_universe_ranking` (general) is left untouched; this is the
-- category view the clients consume (GENERAL | ECONOMY | RESEARCH | MILITARY).
-- ---------------------------------------------------------------------
create or replace function public.get_universe_ranking_by_category(
    p_universe_id uuid,
    p_category text,
    p_limit integer default 100
)
returns table(
    out_rank integer,
    out_player_id uuid,
    out_username text,
    out_player_type text,
    out_points bigint,
    out_is_current_player boolean
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_category text := upper(coalesce(p_category, 'GENERAL'));
begin
    if v_category not in ('GENERAL', 'ECONOMY', 'RESEARCH', 'MILITARY') then
        raise exception 'RANKING_CATEGORY_INVALID: %', p_category;
    end if;

    return query
    select r.out_rank,
           r.player_id,
           r.username,
           r.player_type,
           r.points,
           (r.user_id is not null and r.user_id = auth.uid())
    from (
        select case v_category
                   when 'ECONOMY' then pl.economy_rank
                   when 'RESEARCH' then pl.research_rank
                   when 'MILITARY' then pl.military_rank
                   else pl.rank
               end as out_rank,
               pl.id as player_id,
               pl.username,
               pl.player_type,
               case v_category
                   when 'ECONOMY' then pl.economy_points
                   when 'RESEARCH' then pl.research_points
                   when 'MILITARY' then pl.military_points
                   else pl.points
               end as points,
               pl.user_id
        from public.players pl
        where pl.universe_id = p_universe_id
    ) r
    order by r.out_rank nulls last, r.points desc, r.player_id
    limit greatest(1, least(coalesce(p_limit, 100), 500));
end;
$function$;

-- ACL: least privilege, no anon bypass (the category view is a logged-in contract).
revoke all on function public.calculate_player_category_scores(uuid) from public;
revoke all on function public.get_universe_ranking_by_category(uuid, text, integer) from public;

grant execute on function public.calculate_player_category_scores(uuid) to authenticated, service_role;
grant execute on function public.get_universe_ranking_by_category(uuid, text, integer) to authenticated, service_role;
