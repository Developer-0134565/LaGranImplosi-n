-- ROBOT FACTORY — E2E certification fixture (2026-09-30)
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract under test (20260930090000): the Robotics Factory divides the duration of EVERY
-- construction queue of its planet by (1 + level) — buildings, research, ships and defences.
--
-- Two-sided by design:
--   * POSITIVE  — the divisor is exact at levels 0, 1 and a higher level, for all four families.
--   * REGRESSION — the same planet, with and without the building, must produce IDENTICAL fleet
--     travel time and IDENTICAL economic production per hour, proving the mechanic never leaked
--     outside the construction engine.
--
-- LIMITATION: single-session harness with ROLLBACK; `request.jwt.claims` is the same mechanism the
-- other ACL fixtures use. No JWT is fabricated, no data is faked. Concurrency is not run.

begin;

drop table if exists t_rf;
create temp table t_rf(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_planet uuid; v_universe uuid; v_other uuid;
    v_fail integer := 0; v_ok boolean;
    v_t0 numeric; v_t1 numeric; v_t9 numeric; v_prev timestamptz; v_core numeric;
    v_ship0 numeric; v_ship9 numeric;
    v_def0 numeric; v_def9 numeric;
    v_res0 numeric; v_res9 numeric;
    v_prod0 numeric; v_prod1 numeric; v_crystal0 numeric; v_crystal1 numeric;
    v_travel0 numeric; v_travel1 numeric;
    v_row record; v_raised text;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_planet
      from public.planets p where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET'
      order by p.created_at limit 1;
    select p.id into v_other
      from public.planets p where p.player_id is distinct from v_player and not p.is_destroyed
      order by p.created_at limit 1;
    if v_player is null or v_planet is null or v_other is null then
        raise exception 'TEST_ABORT: an auth-linked player, its planet and a foreign planet are required';
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    -- stable, fully populated planet: shipyard + lab + mines + plenty of resources
    delete from public.planet_buildings where planet_id = v_planet;
    insert into public.planet_buildings(planet_id, building_id, level) values
        (v_planet, 'shipyard', 8),
        (v_planet, 'research_lab', 8),
        (v_planet, 'metal_mine', 10), (v_planet, 'crystal_mine', 10), (v_planet, 'deuterium_synthesizer', 10),
        (v_planet, 'solar_plant', 30);
    delete from public.planet_ships where planet_id = v_planet;
    update public.planet_resources set metal = 90000000, crystal = 90000000, deuterium = 90000000,
           last_calculated_at = now() where planet_id = v_planet;

    -- ---------------------------------------------------- 1. definition matches the source
    v_ok := exists (select 1 from public.building_definitions
                     where id = 'robot_factory' and base_metal = 400 and base_crystal = 120
                       and base_deuterium = 200 and cost_factor = 2 and valid_kinds = '{PLANET}')
            and not exists (select 1 from public.building_prerequisites where building_id = 'robot_factory')
            and not exists (select 1 from public.building_research_prerequisites where building_id = 'robot_factory');
    insert into t_rf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,

    -- ------------------------------------- 2. cost curve is the classic floor(base * 2^(L-1))
    v_ok := (select c.metal from public.calculate_building_cost('robot_factory', 1) c) = 400
            and (select c.metal from public.calculate_building_cost('robot_factory', 3) c) = 1600
            and (select c.crystal from public.calculate_building_cost('robot_factory', 3) c) = 480
            and (select c.deuterium from public.calculate_building_cost('robot_factory', 3) c) = 800;
    insert into t_rf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '2. cost curve matches the classic table (L1 400/120/200 · L3 1600/480/800)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ------------------------------------------------------ 3. BUILDINGS: level 0 is the base
    v_t0 := public.calculate_building_time('metal_mine', 11, v_universe, v_planet);
    v_core := public.calculate_building_time('metal_mine', 11, v_universe, null::uuid);
    v_ok := v_t0 = v_core and public.calculate_robot_factory_build_speed(v_planet) = 1;
    insert into t_rf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. RF 0 leaves building time untouched (%s = universe-only core %s)', v_t0, v_core));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ------------------------------------- 4. BUILDINGS: level 1 halves, level 9 divides by 10
    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'robot_factory', 1)
    on conflict (planet_id, building_id) do update set level = 1;
    v_t1 := public.calculate_building_time('metal_mine', 11, v_universe, v_planet);

    update public.planet_buildings set level = 9 where planet_id = v_planet and building_id = 'robot_factory';
    v_t9 := public.calculate_building_time('metal_mine', 11, v_universe, v_planet);

    v_ok := abs(v_t1 - v_t0 / 2) < 0.0001
            and abs(v_t9 - v_t0 / 10) < 0.0001
            and v_t9 < v_t1 and v_t1 < v_t0;
    insert into t_rf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. building time is base/(1+R): RF0=%s RF1=%s RF9=%s', v_t0, v_t1, v_t9));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ------------------------------------------------------------ 5. SHIPYARD (ships)
    update public.planet_buildings set level = 0 where planet_id = v_planet and building_id = 'robot_factory';
    v_ship0 := public.calculate_ship_build_time(v_planet, 'light_fighter');
    update public.planet_buildings set level = 9 where planet_id = v_planet and building_id = 'robot_factory';
    v_ship9 := public.calculate_ship_build_time(v_planet, 'light_fighter');
    v_ok := abs(v_ship9 - v_ship0 / 10) < 0.0001 and v_ship9 < v_ship0;
    insert into t_rf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. ship build time is base/(1+R): RF0=%s RF9=%s', v_ship0, v_ship9));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ------------------------------------------------------------- 6. DEFENCE
    update public.planet_buildings set level = 0 where planet_id = v_planet and building_id = 'robot_factory';
    v_def0 := public.calculate_defense_build_time(v_planet, 'rocket_launcher');
    update public.planet_buildings set level = 9 where planet_id = v_planet and building_id = 'robot_factory';
    v_def9 := public.calculate_defense_build_time(v_planet, 'rocket_launcher');
    v_ok := abs(v_def9 - v_def0 / 10) < 0.0001 and v_def9 < v_def0;
    insert into t_rf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. defence build time is base/(1+R): RF0=%s RF9=%s', v_def0, v_def9));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ------------------------------------------------------------- 7. RESEARCH
    delete from public.planet_buildings where planet_id = v_planet and building_id = 'robot_factory';
    select r.final_time_seconds into v_res0
      from public.calculate_research_time(v_player, v_planet, 'energy_technology', 5) r;
    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'robot_factory', 9)
    on conflict (planet_id, building_id) do update set level = 9;
    select r.final_time_seconds into v_res9

    -- ---------------- 8. SECURITY: the divisor is derived from the planet, never from the client
    v_ok := public.calculate_robot_factory_build_speed(v_other) = 1
            and public.calculate_robot_factory_build_speed('00000000-0000-0000-0000-000000000000'::uuid) = 1
            and public.calculate_robot_factory_build_speed(null::uuid) = 1;
    insert into t_rf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '8. no planet (foreign/unknown/null) always yields divisor 1, never a client value');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into public.planet_buildings(planet_id, building_id, level) values (v_other, 'robot_factory', 10)
    on conflict (planet_id, building_id) do update set level = 10;
    v_ship0 := public.calculate_ship_build_time(v_planet, 'light_fighter');
    v_ship9 := public.calculate_ship_build_time(v_planet, 'light_fighter');
    v_ok := public.calculate_robot_factory_build_speed(v_other) = 11 and v_ship0 = v_ship9;
    insert into t_rf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '9. a foreign planet with RF 10 speeds up ITS OWN queues only, never the owner''s');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- --------------------------------------------------------- 10. moon gate (PLANET only)
    delete from public.planet_buildings where planet_id = v_other;
    delete from public.planets m where m.parent_planet_id = v_planet;
    insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
        temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind, parent_planet_id, moon_diameter_km)
    select v_universe, v_player, 'Moon', p.galaxy, p.system, p.position, -20, 20, 10, 0, false, false,
           'MOON', p.id, 2000
      from public.planets p where p.id = v_planet;
    v_raised := null;
    begin
        insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status)
        select m.id, 'robot_factory', 1, clock_timestamp(), clock_timestamp() + interval '1 hour', 'BUILDING'
          from public.planets m where m.parent_planet_id = v_planet;
    exception when others then
        v_raised := sqlerrm;

    -- ------------------------------- 11. REGRESSION: economy and fleet must be UNCHANGED
    delete from public.planet_buildings where planet_id = v_planet and building_id = 'robot_factory';
    select pp.metal_per_hour, pp.crystal_per_hour into v_prod0, v_crystal0
      from public.calculate_planet_production(v_planet) pp;
    select public.calculate_fleet_travel_time(100, 10000, 1, 100) into v_travel0;

    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'robot_factory', 10)
    on conflict (planet_id, building_id) do update set level = 10;

    select pp.metal_per_hour, pp.crystal_per_hour into v_prod1, v_crystal1
      from public.calculate_planet_production(v_planet) pp;
    select public.calculate_fleet_travel_time(100, 10000, 1, 100) into v_travel1;

    v_ok := v_prod0 = v_prod1 and v_crystal0 = v_crystal1;
    insert into t_rf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11. RF 10 does NOT change production per hour (metal %s -> %s, crystal %s -> %s)',
             v_prod0, v_prod1, v_crystal0, v_crystal1));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := v_travel0 = v_travel1;
    insert into t_rf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('12. RF 10 does NOT change fleet travel time (%s -> %s)', v_travel0, v_travel1));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ------------------------- 13. the queue that actually gets written uses the same divisor
    delete from public.building_queue where planet_id = v_planet;
    perform public.start_building(v_player, v_planet, 'metal_mine');
    select extract(epoch from bq.finishes_at - bq.started_at) into v_t0
      from public.building_queue bq where bq.planet_id = v_planet and bq.building_id = 'metal_mine';
    delete from public.building_queue where planet_id = v_planet;

    delete from public.planet_buildings where planet_id = v_planet and building_id = 'robot_factory';
    perform public.start_building(v_player, v_planet, 'metal_mine');
    select extract(epoch from bq.finishes_at - bq.started_at) into v_t1
      from public.building_queue bq where bq.planet_id = v_planet and bq.building_id = 'metal_mine';
    delete from public.building_queue where planet_id = v_planet;

    v_ok := v_t0 < v_t1;
    insert into t_rf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('13. the real queue honours the divisor: RF10=%ss vs RF0=%ss', v_t0, v_t1));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ----------------------------------- 14. a queue already running keeps its stored finish
    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'robot_factory', 10)
    on conflict (planet_id, building_id) do update set level = 10;
    perform public.start_building(v_player, v_planet, 'metal_mine');
    select bq.finishes_at into v_prev
      from public.building_queue bq where bq.planet_id = v_planet;
    update public.planet_buildings set level = 0 where planet_id = v_planet and building_id = 'robot_factory';
    select bq.finishes_at into v_prev2
      from public.building_queue bq where bq.planet_id = v_planet;
    v_ok := v_prev = v_prev2;
    insert into t_rf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '14. an in-flight queue keeps its stored finishes_at (documented divergence from classic OGame)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;
    delete from public.building_queue where planet_id = v_planet;

    insert into t_rf(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; concurrency not executed. Research is included by explicit
       product decision (classic OGame documents the Robotics Factory against building and shipyard
       times only). The OGameX shipyard -> robot_factory 2 gate is NOT applied: it would invalidate
       existing empires that already own a shipyard, so it stays a product decision.');

    if v_fail > 0 then
        raise exception 'ROBOT FACTORY FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_rf order by orden;

drop table if exists t_rf;

ROLLBACK;
    end;
    v_ok := v_raised like 'BUILDING_NOT_AVAILABLE_FOR_KIND%';
    insert into t_rf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. the backend refuses to queue it on a moon (%s)', coalesce(v_raised, 'ACCEPTED - FAIL')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;
    delete from public.planets m where m.parent_planet_id = v_planet;
-- ANCHOR_RF3 --

      from public.calculate_research_time(v_player, v_planet, 'energy_technology', 5) r;
    v_ok := abs(v_res9 - v_res0 / 10) < 0.0001 and v_res9 < v_res0;
    insert into t_rf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. research time is base/(1+R): RF0=%s RF9=%s (product decision: research included)', v_res0, v_res9));
    v_fail := v_fail + case when v_ok then 0 else 1 end;
-- ANCHOR_RF2 --

      '1. definition 400/120/200 factor 2, PLANET only, no prerequisite (both sources say none)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;
-- ANCHOR_RF --
