-- RANKING CATEGORY SCORES FIXTURE — LA GRAN IMPLOSIÓN
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
-- Contract (20260926170000_ranking_category_scores.sql), OGameX HighscoreService parity:
--   economy  = per planet floor((buildings+stations(100%) + defenses(100%) + civil ships(50%))/1000)
--              + floor(civil in transit × 50% / 1000); sensor_phalanx / jump_gate enter at 50 %
--   research = floor(Σ cumulative research cost / 1000)
--   military = per planet floor((defenses(100%) + military ships(100%) + civil ships(50%))/1000)
--              + floor((military in transit + civil in transit × 50%)/1000)
--   ship split: ship_type = 'combat' is the OGameX MilitaryShipObjects, every other type the CivilShipObjects.
-- Also asserts the per-category ranks, the category read contract and that the certified general
-- points/rank contract and `get_universe_ranking` are untouched.
-- LIMITATION: single-session harness; the periodic worker is invoked directly (no cron wait).

begin;

drop table if exists t_rc;
create temp table t_rc(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_universe uuid; v_planet uuid; v_moon uuid; v_fleet uuid;
    v_eco bigint; v_res bigint; v_mil bigint;
    v_exp_eco bigint; v_exp_res bigint; v_exp_mil bigint;
    v_ok boolean; v_fail integer := 0; v_raised text;
    v_points bigint; v_rank integer; v_rank_mil integer; v_rank_res integer;
    v_expected_rank integer; v_rows integer; v_expected_rows integer; v_top bigint; v_max bigint; v_calc integer;
    v_build numeric; v_station numeric; v_def numeric; v_civ numeric; v_mil_ships numeric; v_research numeric;
    v_tmil numeric; v_tciv numeric; v_sat numeric; v_probe numeric;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_planet from public.planets p
     where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET' order by p.created_at limit 1;

    if v_player is null or v_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet is required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* deterministic slate */
    delete from public.planet_buildings where planet_id = v_planet;
    delete from public.planet_ships where planet_id = v_planet;
    delete from public.planet_defenses where planet_id = v_planet;
    delete from public.player_research where player_id = v_player;
    delete from public.fleet_movements where player_id = v_player;
    delete from public.planets where parent_planet_id = v_planet;

    insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
        temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind, parent_planet_id, moon_diameter_km)
    select v_universe, v_player, 'RankMoon', p.galaxy, p.system, p.position, -20, 20, 10, 0, false, false,
           'MOON', p.id, 2000
      from public.planets p where p.id = v_planet
    returning id into v_moon;

    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'metal_mine', 2);
    insert into public.planet_ships(planet_id, ship_id, quantity) values
        (v_planet, 'light_fighter', 2), (v_planet, 'small_cargo', 3), (v_planet, 'espionage_probe', 1);
    insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_planet, 'rocket_launcher', 3);
    insert into public.player_research(player_id, research_id, level) values (v_player, 'energy_technology', 2);

    insert into public.planet_buildings(planet_id, building_id, level) values (v_moon, 'sensor_phalanx', 1);
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_moon, 'solar_satellite', 1);

    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at, status,
        metal, crystal, deuterium, expedition_hold_seconds, fuel_consumed)
    values (v_player, v_planet, 'TRANSPORT', now(), now() + interval '1 hour', 'OUTBOUND', 0, 0, 0, 0, 0)
    returning id into v_fleet;

    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values
        (v_fleet, 'cruiser', 1), (v_fleet, 'large_cargo', 2);

    /* expected values, re-derived from the OGameX composition with LGI primitives */
    select coalesce(sum(bc.metal + bc.crystal + bc.deuterium), 0) into v_build
      from generate_series(1, 2) l cross join lateral public.calculate_building_cost('metal_mine', l) bc;
    select coalesce(sum(bc.metal + bc.crystal + bc.deuterium), 0) into v_station
      from generate_series(1, 1) l cross join lateral public.calculate_building_cost('sensor_phalanx', l) bc;
    select coalesce(sum(rc.metal + rc.crystal + rc.deuterium), 0) into v_research
      from generate_series(1, 2) l cross join lateral public.calculate_research_cost('energy_technology', l) rc;
    select 3 * (dd.metal_cost + dd.crystal_cost + dd.deuterium_cost) into v_def
      from public.defense_definitions dd where dd.id = 'rocket_launcher';
    select 2 * (sd.base_metal + sd.base_crystal + sd.base_deuterium) into v_mil_ships
      from public.ship_definitions sd where sd.id = 'light_fighter';
    select 3 * (sd.base_metal + sd.base_crystal + sd.base_deuterium) into v_civ
      from public.ship_definitions sd where sd.id = 'small_cargo';
    select (sd.base_metal + sd.base_crystal + sd.base_deuterium) into v_probe
      from public.ship_definitions sd where sd.id = 'espionage_probe';
    select (sd.base_metal + sd.base_crystal + sd.base_deuterium) into v_sat
      from public.ship_definitions sd where sd.id = 'solar_satellite';
    select (sd.base_metal + sd.base_crystal + sd.base_deuterium) into v_tmil
      from public.ship_definitions sd where sd.id = 'cruiser';
    select 2 * (sd.base_metal + sd.base_crystal + sd.base_deuterium) into v_tciv
      from public.ship_definitions sd where sd.id = 'large_cargo';
    v_civ := v_civ + v_probe;

    v_exp_eco := floor((v_build + v_def + 0.5 * v_civ) / 1000)::bigint
                 + floor((0.5 * v_station + 0.5 * v_sat) / 1000)::bigint
                 + floor((0.5 * v_tciv) / 1000)::bigint;
    v_exp_mil := floor((v_def + v_mil_ships + 0.5 * v_civ) / 1000)::bigint
                 + floor((0.5 * v_station + 0.5 * v_sat) / 1000)::bigint
                 + floor((v_tmil + 0.5 * v_tciv) / 1000)::bigint;
    v_exp_res := floor(v_research / 1000)::bigint;

    select s.economy_points, s.research_points, s.military_points into v_eco, v_res, v_mil
      from public.calculate_player_category_scores(v_player) s;

    v_ok := v_eco = v_exp_eco and v_res = v_exp_res and v_mil = v_exp_mil;
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. buckets eco %s/%s · res %s/%s · mil %s/%s', v_eco, v_exp_eco, v_res, v_exp_res, v_mil, v_exp_mil));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 2. recalculate_player_points persists the buckets and keeps the general contract intact */
    v_points := public.recalculate_player_points(v_player);
    select e.economy_points, e.research_points, e.military_points into v_eco, v_res, v_mil
      from public.players e where e.id = v_player;

    v_ok := v_points = floor(public.calculate_player_points(v_player) / 1000)::bigint
            and v_eco = v_exp_eco and v_res = v_exp_res and v_mil = v_exp_mil;
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. recalculate_player_points: general=%s buckets=%s/%s/%s', v_points, v_eco, v_res, v_mil));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 3. per-category rank equals 1 + players with a strictly greater bucket (ties share a rank) */
    select 1 + count(*) into v_expected_rank from public.players o
     where o.universe_id = v_universe and o.id <> v_player and o.economy_points > v_exp_eco;
    select e.economy_rank into v_rank from public.players e where e.id = v_player;

    v_ok := v_rank = v_expected_rank;
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. economy rank %s (expected %s)', v_rank, v_expected_rank));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 4. category read contract: ordering by the category and parity with the certified general contract */
    select r.out_points into v_top from public.get_universe_ranking_by_category(v_universe, 'ECONOMY') r limit 1;
    select max(o.economy_points) into v_max from public.players o where o.universe_id = v_universe;
    select count(*) into v_rows from public.get_universe_ranking_by_category(v_universe, 'GENERAL', 500) r;
    select count(*) into v_expected_rows from public.players o where o.universe_id = v_universe;

    /* both read contracts cap the page (500 max), so the expected page is the smaller of the two */
    v_ok := v_top = v_max and v_rows = least(500, v_expected_rows);
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. category read contract: top=%s max=%s rows=%s/%s', v_top, v_max, v_rows, v_expected_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 5. invalid category is refused */
    v_raised := null;
    begin
        perform * from public.get_universe_ranking_by_category(v_universe, 'NOPE');
    exception when others then
        v_raised := sqlerrm;
    end;
    v_ok := v_raised like 'RANKING_CATEGORY_INVALID%';
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. invalid category refused (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 6. the scheduled worker path refreshes the buckets and every category rank */
    v_calc := public.recalculate_universe_ranking(v_universe);
    select e.economy_rank, e.research_rank, e.military_rank into v_rank, v_rank_res, v_rank_mil
      from public.players e where e.id = v_player;

    v_ok := v_calc >= 1 and v_rank = v_expected_rank and v_rank_res is not null and v_rank_mil is not null;
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. recalculate_universe_ranking ranked %s players; ranks %s/%s/%s', v_calc, v_rank, v_rank_res, v_rank_mil));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 7. the certified general contract and its read contract are untouched */
    select count(*) into v_rows from public.get_universe_ranking(v_universe, 500) r;
    v_ok := v_rows = least(500, v_expected_rows)
            and (select e.points from public.players e where e.id = v_player)
                = floor(public.calculate_player_points(v_player) / 1000)::bigint;
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. certified general ranking intact (%s rows, points %s)', v_rows,
             (select e.points from public.players e where e.id = v_player)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 8. ACL: no anon bypass, authenticated allowed */
    v_ok := not has_function_privilege('anon', 'public.get_universe_ranking_by_category(uuid,text,integer)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.calculate_player_category_scores(uuid)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.get_universe_ranking_by_category(uuid,text,integer)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.calculate_player_category_scores(uuid)', 'EXECUTE');
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '8. ACL: category contracts are authenticated/service_role only');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_rc(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; the ranking worker is called directly instead of waiting for pg_cron. Weights are the OGameX docblock values (100/50) and every component is floored per planet and per transit block.');

    if v_fail > 0 then
        raise exception 'RANKING CATEGORY FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_rc order by orden;

drop table if exists t_rc;

ROLLBACK;
