-- PLAYER RANKING / POINTS FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract under test (migration 20260926091604_add_player_ranking_contract):
--   * `calculate_player_points(player)` = Σ(completed building levels) + Σ(completed research levels)
--     + planet ships + in-transit ships + planet defences, priced with the certified cost helpers;
--   * `recalculate_player_points(player)` materialises floor(raw / 1000) (OGameX HighscoreService parity);
--   * `recalculate_universe_ranking(universe)` materialises points + SQL `rank()` for the whole universe,
--     idempotently, and must not touch anything but `players.points` / `players.rank`;
--   * `get_universe_ranking(universe, limit)` is the client read contract; `is_current_player` is derived
--     from `auth.uid()` (never from a client-supplied id) and the limit is clamped to 1..500;
--   * EXECUTE: recalculation = service_role only; read contract = authenticated/service_role.
--
-- LIMITATION: single-session harness; concurrency is not executed. No fleet row exists in this universe, so
-- the in-transit term is asserted structurally and is part of the independent expectation expression.

begin;

drop table if exists t_rank;
create temp table t_rank(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid;
    v_player uuid;
    v_universe uuid;
    v_p1 uuid; v_p2 uuid; v_p3 uuid;
    v_planet1 uuid; v_planet2 uuid; v_planet3 uuid;
    v_raw numeric; v_expected numeric; v_points bigint;
    v_rank1 integer; v_rank2 integer; v_rank3 integer;
    v_top1 numeric; v_cap numeric; v_cap_expected numeric;
    v_before text; v_after text; v_after2 text;
    v_ok boolean; v_fail integer := 0;
    v_blocked boolean; v_err text;
    v_auth_exec boolean; v_anon_exec boolean;
    v_rows integer; v_flagged integer; v_unranked integer; v_structural boolean;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl
     where pl.user_id is not null
     order by pl.created_at, pl.id
     limit 1;

    if v_player is null then
        raise exception 'TEST_ABORT: an auth-linked player is required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* ---------------------------------------------- synthetic players (rolled back) */
    insert into public.players(universe_id, username, player_type)
    values (v_universe, 'FIXTURE_RANK_1', 'AI') returning id into v_p1;
    insert into public.players(universe_id, username, player_type)
    values (v_universe, 'FIXTURE_RANK_2', 'AI') returning id into v_p2;
    insert into public.players(universe_id, username, player_type)
    values (v_universe, 'FIXTURE_RANK_3', 'AI') returning id into v_p3;

    insert into public.planets(universe_id, player_id, name, galaxy, system, position)
    values (v_universe, v_p1, 'FIX_RANK_1', 1, 499, 14) returning id into v_planet1;
    insert into public.planets(universe_id, player_id, name, galaxy, system, position)
    values (v_universe, v_p2, 'FIX_RANK_2', 1, 499, 15) returning id into v_planet2;
    insert into public.planets(universe_id, player_id, name, galaxy, system, position)
    values (v_universe, v_p3, 'FIX_RANK_3', 1, 499, 16) returning id into v_planet3;

    insert into public.planet_buildings(planet_id, building_id, level)
    values (v_planet1, 'metal_mine', 3)
    on conflict (planet_id, building_id) do update set level = excluded.level;

    insert into public.player_research(player_id, research_id, level)
    values (v_p2, 'energy_technology', 20)
    on conflict (player_id, research_id) do update set level = excluded.level;

    /* ------------------------------------------------------------------ 1. RAW: BUILDINGS */
    select public.calculate_player_points(v_p1) into v_raw;

    select sum((bd.base_metal + bd.base_crystal + bd.base_deuterium) * power(bd.cost_factor, gs.i - 1))
      into v_expected
      from public.building_definitions bd
      cross join generate_series(1, 3) gs(i)
     where bd.id = 'metal_mine';

    v_ok := v_raw = v_expected;
    insert into t_rank(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. metal_mine level 3 raw investment = %s (expected %s, cumulative levels 1..3)', v_raw, v_expected));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* -------------------------------------------------- 2. POINTS = floor(raw / 1000) */
    select public.recalculate_player_points(v_p1) into v_points;
    v_ok := v_points = floor(v_expected / 1000)::bigint
        and (select pl.points from public.players pl where pl.id = v_p1) = v_points;
    insert into t_rank(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. recalculate_player_points materialises floor(%s/1000) = %s', v_expected, v_points));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------------ 3. RAW: RESEARCH LEVELS */
    select public.calculate_player_points(v_p2) into v_raw;

    select sum((rd.base_metal + rd.base_crystal + rd.base_deuterium) * power(rd.cost_factor, gs.i - 1))
      into v_expected
      from public.research_definitions rd
      cross join generate_series(1, 20) gs(i)
     where rd.id = 'energy_technology';

    select public.recalculate_player_points(v_p2) into v_points;
    v_ok := v_raw = v_expected
        and v_points = floor(v_expected / 1000)::bigint
        and v_points > 1000;
    insert into t_rank(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. energy_technology level 20: raw %s -> %s points', v_raw, v_points));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------------ 4. NO ASSETS => ZERO */
    v_ok := public.recalculate_player_points(v_p3) = 0
        and public.calculate_player_points(v_p3) = 0;
    insert into t_rank(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '4. a player with no assets scores 0 points');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* -------------------- 5. THE REAL PLAYER: INDEPENDENT RECOMPUTATION OF EVERY COMPONENT */
    select
        coalesce((select sum(bc.metal + bc.crystal + bc.deuterium)
                    from public.planet_buildings pb
                    join public.planets p on p.id = pb.planet_id and p.player_id = v_player
                   cross join lateral generate_series(1, pb.level) gs(i)
                   cross join lateral public.calculate_building_cost(pb.building_id, gs.i) bc), 0)
      + coalesce((select sum(rc.metal + rc.crystal + rc.deuterium)
                    from public.player_research pr
                   cross join lateral generate_series(1, pr.level) gs(i)
                   cross join lateral public.calculate_research_cost(pr.research_id, gs.i) rc
                   where pr.player_id = v_player), 0)
      + coalesce((select sum(ps.quantity * (sd.base_metal + sd.base_crystal + sd.base_deuterium))
                    from public.planet_ships ps
                    join public.planets p on p.id = ps.planet_id and p.player_id = v_player
                    join public.ship_definitions sd on sd.id = ps.ship_id), 0)
      + coalesce((select sum(fms.quantity * (sd.base_metal + sd.base_crystal + sd.base_deuterium))
                    from public.fleet_movements fm
                    join public.fleet_movement_ships fms on fms.fleet_id = fm.id
                    join public.ship_definitions sd on sd.id = fms.ship_id
                   where fm.player_id = v_player
                     and fm.status not in ('COMPLETED','CANCELLED')), 0)
      + coalesce((select sum(pd.quantity * (dd.metal_cost + dd.crystal_cost + dd.deuterium_cost))
                    from public.planet_defenses pd
                    join public.planets p on p.id = pd.planet_id and p.player_id = v_player
                    join public.defense_definitions dd on dd.id = pd.defense_id), 0)
      into v_expected;

    v_ok := public.calculate_player_points(v_player) = v_expected;
    insert into t_rank(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. authenticated player investment matches the component-by-component recomputation (%s)', v_expected));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select prosrc ~ 'fleet_movement_ships' into v_structural
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'calculate_player_points';
    v_ok := v_structural;
    insert into t_rank(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '5b. the in-transit ship term is part of calculate_player_points (this universe has no fleet row)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* --------------------------- 6. UNIVERSE RECALCULATION: POINTS, RANKS AND THE TOP-1 READER */
    select md5(string_agg(pl.id::text || ':' || pl.points || ':' || coalesce(pl.rank::text, '-'),
                          ',' order by pl.id))
      into v_before
      from public.players pl where pl.universe_id = v_universe;

    select public.recalculate_universe_ranking(v_universe) into v_rows;

    select pl.rank into v_rank1 from public.players pl where pl.id = v_p1;
    select pl.rank into v_rank2 from public.players pl where pl.id = v_p2;
    select pl.rank into v_rank3 from public.players pl where pl.id = v_p3;
    select count(*)::integer into v_unranked from public.players pl
     where pl.universe_id = v_universe and pl.rank is null;

    v_ok := v_rank2 = 1 and v_rank1 = v_rank3 and v_rank1 > v_rank2 and v_unranked = 0;
    insert into t_rank(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. ranks: top scores %s (rank %s), tied zero-point players share rank %s, %s unranked',
             (select pl.points from public.players pl where pl.id = v_p2), v_rank2, v_rank1, v_unranked));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select public.get_universe_top1_points(v_universe) into v_top1;
    select public.calculate_expedition_resource_cap(v_universe) into v_cap;
    select erc.max_resource_find into v_cap_expected
      from public.expedition_resource_caps erc
     where v_top1 >= erc.min_top1_points
       and (erc.max_top1_points is null or v_top1 < erc.max_top1_points)
     order by erc.min_top1_points desc limit 1;

    v_ok := v_top1 = (select pl.points from public.players pl where pl.id = v_p2)
        and v_cap = v_cap_expected
        and v_cap > 40000;
    insert into t_rank(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. live consumer: top1 = %s raises the expedition resource cap to %s (was 40000 with points=0)', v_top1, v_cap));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------ 8. IDEMPOTENCY / REPLAY SAFETY */
    select md5(string_agg(pl.id::text || ':' || pl.points || ':' || coalesce(pl.rank::text, '-'),
                          ',' order by pl.id))
      into v_after
      from public.players pl where pl.universe_id = v_universe;

    select public.recalculate_universe_ranking(v_universe) into v_rows;

    select md5(string_agg(pl.id::text || ':' || pl.points || ':' || coalesce(pl.rank::text, '-'),
                          ',' order by pl.id))
      into v_after2
      from public.players pl where pl.universe_id = v_universe;

    v_ok := v_after = v_after2 and v_before <> v_after;
    insert into t_rank(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. materialised once and stable on replay (%s players updated; digest %s -> %s -> %s)',
             v_rows, v_before, v_after, v_after2));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------- 9. CONSERVATION: NOTHING BUT points/rank IS TOUCHED */
    select md5(
             (select coalesce(sum(pr.metal + pr.crystal + pr.deuterium), 0)::text from public.planet_resources pr)
          || '|' || (select count(*)::text from public.planet_buildings)
          || '|' || (select coalesce(sum(ps.quantity), 0)::text from public.planet_ships ps)
          || '|' || (select count(*)::text from public.player_research)
          || '|' || (select coalesce(sum(pd.quantity), 0)::text from public.planet_defenses pd))
      into v_after;

    select public.recalculate_universe_ranking(v_universe) into v_rows;

    select md5(
             (select coalesce(sum(pr.metal + pr.crystal + pr.deuterium), 0)::text from public.planet_resources pr)
          || '|' || (select count(*)::text from public.planet_buildings)
          || '|' || (select coalesce(sum(ps.quantity), 0)::text from public.planet_ships ps)
          || '|' || (select count(*)::text from public.player_research)
          || '|' || (select coalesce(sum(pd.quantity), 0)::text from public.planet_defenses pd))
      into v_after2;

    v_ok := v_after = v_after2;
    insert into t_rank(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. recalculation conserved every asset (resources+ship quantity+research+building+defence digest %s)', v_after));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------- 10. REJECTIONS LEAVE NO MUTATION */
    select md5(string_agg(pl.id::text || ':' || pl.points || ':' || coalesce(pl.rank::text, '-'),
                          ',' order by pl.id))
      into v_before
      from public.players pl where pl.universe_id = v_universe;

    v_blocked := false; v_err := null;
    begin
        perform public.recalculate_player_points(gen_random_uuid());
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;
    v_ok := v_blocked and v_err like 'PLAYER_NOT_FOUND%';
    insert into t_rank(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10a. unknown player rejected [%s / %s]', v_blocked, v_err));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_blocked := false; v_err := null;
    begin
        perform public.recalculate_universe_ranking(gen_random_uuid());
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;
    v_ok := v_blocked and v_err like 'UNIVERSE_NOT_FOUND%';
    insert into t_rank(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10b. unknown universe rejected [%s / %s]', v_blocked, v_err));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select md5(string_agg(pl.id::text || ':' || pl.points || ':' || coalesce(pl.rank::text, '-'),
                          ',' order by pl.id))
      into v_after
      from public.players pl where pl.universe_id = v_universe;

    v_ok := v_after = v_before;
    insert into t_rank(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10c. both rejections left points/ranks untouched');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------- 11. READ CONTRACT + IDENTITY + CLAMP */
    select count(*)::integer into v_rows
      from public.get_universe_ranking(v_universe, 3) r;
    v_ok := v_rows = 3;
    insert into t_rank(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11a. read contract honours the limit (asked 3, got %s)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*)::integer into v_rows from public.get_universe_ranking(v_universe, 0) r;
    select count(*)::integer into v_flagged
      from public.get_universe_ranking(v_universe, 100000) r
     where r.out_is_current_player;
    v_ok := v_rows = 1 and v_flagged = 1;
    insert into t_rank(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11b. limit clamped (0 -> %s row) and exactly %s row flagged as the caller''s player', v_rows, v_flagged));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    perform set_config('request.jwt.claims', '{}', true);

    select count(*)::integer into v_flagged
      from public.get_universe_ranking(v_universe, 100000) r
     where r.out_is_current_player;

    v_ok := v_flagged = 0;
    insert into t_rank(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11c. with no session the contract flags no player as current (%s rows)', v_flagged));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* ---------------------------------------------------------- 12. ACL BOUNDARY */
    select has_function_privilege('authenticated', 'public.get_universe_ranking(uuid,integer)', 'EXECUTE')
       and not has_function_privilege('authenticated', 'public.recalculate_universe_ranking(uuid)', 'EXECUTE')
       and not has_function_privilege('authenticated', 'public.recalculate_player_points(uuid)', 'EXECUTE')
       and not has_function_privilege('authenticated', 'public.calculate_player_points(uuid)', 'EXECUTE')
      into v_auth_exec;

    select has_function_privilege('anon', 'public.get_universe_ranking(uuid,integer)', 'EXECUTE')
        or has_function_privilege('anon', 'public.recalculate_universe_ranking(uuid)', 'EXECUTE')
      into v_anon_exec;

    select has_function_privilege('service_role', 'public.recalculate_universe_ranking(uuid)', 'EXECUTE')
      into v_structural;

    v_ok := v_auth_exec and not v_anon_exec and v_structural;
    insert into t_rank(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('12. ACL: client reads only (authenticated read=%s, client recalc=%s, service_role recalc=%s)',
             v_auth_exec, v_anon_exec, v_structural));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_rank(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; concurrency is not executed. No fleet row exists in this universe, so the in-transit term is asserted structurally (5b) and inside the expectation expression (5).');

    if v_fail > 0 then
        raise exception 'PLAYER RANKING FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_rank order by orden;

drop table if exists t_rank;

ROLLBACK;




