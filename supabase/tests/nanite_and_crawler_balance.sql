-- NANITE FACTORY + CRAWLER ENERGY BALANCE FIXTURE — LA GRAN IMPLOSIÓN
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract 20260930210000_nanite_factory.sql
--   OGameX definition (1 000 000 / 500 000 / 100 000, factor 2, PLANET only,
--   prerequisites computer_technology 10 + robot_factory 10) and the 2^level divisor applied to
--   BUILDINGS, SHIPS and DEFENCES — and, per upstream getTechnologyResearchTime, NOT to research.
-- Contract 20260930211000_crawler_energy_balance.sql
--   Q13: the energy balance contract must report the crawler consumption the engine already applies.
--   Q1 is untouched: only EFFECTIVE (capped) crawlers consume.
-- LIMITATION: single-session harness; concurrency not executed.

begin;

drop table if exists t_nf;
create temp table t_nf(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_universe uuid; v_clock timestamptz; v_p uuid;
    v_ok boolean; v_fail integer := 0; v_msg text; v_reason text; v_allowed boolean;
    v_t0 numeric; v_t1 numeric; v_t2 numeric; v_t3 numeric; v_r0 numeric; v_r1 numeric;
    v_c_raw numeric; v_c_eff numeric; v_cow numeric; v_pow numeric;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select last_tick_at into v_clock from public.universe_clock where universe_id = v_universe;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    delete from public.planets where galaxy = 499 and system = 495;
    insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
        temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind)
    select v_universe, v_player, 'NanoProbe', 499, 495, 8, 10, 50, 200, 0, false, false, 'PLANET';
    select id into v_p from public.planets where galaxy = 499 and system = 495;
    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at)
    values (v_p, 100000000, 100000000, 100000000, 0, v_clock);
    insert into public.planet_buildings(planet_id, building_id, level) values
        (v_p, 'shipyard', 1), (v_p, 'metal_mine', 10), (v_p, 'crystal_mine', 10), (v_p, 'deuterium_synthesizer', 10),
        (v_p, 'solar_plant', 60);
    insert into public.player_research(player_id, research_id, level) values (v_player, 'computer_technology', 12)
      on conflict (player_id, research_id) do update set level = 12;

    -- ================================================================ 1. definition (OGameX verbatim)
    v_ok := exists (select 1 from public.building_definitions
                     where id = 'nano_factory' and base_metal = 1000000 and base_crystal = 500000
                       and base_deuterium = 100000 and cost_factor = 2 and valid_kinds = '{PLANET}')
       and (select count(*) from public.building_prerequisites
             where building_id = 'nano_factory' and prerequisite_building_id = 'robot_factory'
               and required_level = 10) = 1
       and (select count(*) from public.building_research_prerequisites
             where building_id = 'nano_factory' and research_id = 'computer_technology'
               and required_level = 10) = 1;
    insert into t_nf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '1. nano_factory definition 1M/500k/100k factor 2, {PLANET}, prereq robot_factory 10 + computer_technology 10');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================ 2. prerequisite gate
    select r.allowed, r.reason into v_allowed, v_reason from public.can_start_building(v_player, v_p, 'nano_factory') r;
    v_ok := v_allowed = false;
    insert into t_nf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. refused without robot_factory 10 / computer_technology 10 (%s)', coalesce(v_reason, '?')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================ 3. the rule: 2^level (buildings)
    v_t0 := public.calculate_nanite_factory_build_speed(v_p);
    insert into public.planet_buildings(planet_id, building_id, level) values (v_p, 'robot_factory', 10), (v_p, 'nano_factory', 3)
      on conflict (planet_id, building_id) do update set level = excluded.level;
    v_t1 := public.calculate_nanite_factory_build_speed(v_p);
    v_ok := v_t0 = 1 and v_t1 = 8;
    insert into t_nf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. calculate_nanite_factory_build_speed: no factory = %s, level 3 = %s (2^3 = 8)', v_t0, v_t1));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================ 4. buildings actually halve per level
    v_t2 := public.calculate_building_time('metal_mine', 5, v_universe, v_p);
    update public.planet_buildings set level = 4 where planet_id = v_p and building_id = 'nano_factory';
    v_t3 := public.calculate_building_time('metal_mine', 5, v_universe, v_p);
    -- 2^4 / 2^3 = 2, NOT 16: one level halves the time. Tolerance 0.01 because the time helpers
    -- round(..., 4), so the ratio of two rounded values is not bit-exact.
    v_ok := abs(v_t2 / v_t3 - 2) < 0.01;
    insert into t_nf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. building time: nanite 3 -> 4 divides it by exactly 2 (%s -> %s)', v_t2, v_t3));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================ 5. ships AND defences are affected
    update public.planet_buildings set level = 3 where planet_id = v_p and building_id = 'nano_factory';
    v_t2 := public.calculate_ship_build_time(v_p, 'light_fighter');
    v_t3 := public.calculate_defense_build_time(v_p, 'rocket_launcher');
    update public.planet_buildings set level = 4 where planet_id = v_p and building_id = 'nano_factory';
    v_t2 := v_t2 / public.calculate_ship_build_time(v_p, 'light_fighter');
    v_t3 := v_t3 / public.calculate_defense_build_time(v_p, 'rocket_launcher');
    v_ok := abs(v_t2 - 2) < 0.01 and abs(v_t3 - 2) < 0.01;
    insert into t_nf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. one more nanite level halves ship (%s x) and defence (%s x) times (OGameX getUnitConstructionTime)', v_t2, v_t3));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================ 6. RESEARCH IS NOT AFFECTED (OGameX)
    -- NOTE: the 4-arg overload returns TABLE(research_id, target_level, base_time, research_speed,
    -- final_time). The assertion reads final_time_seconds, the number the research queue uses.
    update public.planet_buildings set level = 4 where planet_id = v_p and building_id = 'nano_factory';
    select r.final_time_seconds into v_r0 from public.calculate_research_time(v_player, v_p, 'laser_technology', 3) r;
    update public.planet_buildings set level = 8 where planet_id = v_p and building_id = 'nano_factory';
    select r.final_time_seconds into v_r1 from public.calculate_research_time(v_player, v_p, 'laser_technology', 3) r;
    v_ok := v_r0 = v_r1;
    insert into t_nf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. research time is IDENTICAL with nanite 4 and nanite 8 (%s = %s): upstream getTechnologyResearchTime has no nanite term', v_r0, v_r1));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================ 7. the nanite factory is PLANET only
    insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
        temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind, parent_planet_id, moon_diameter_km)
    select v_universe, v_player, 'NanoMoon', 499, 495, 8, 10, 50, 10, 0, false, false, 'MOON', v_p, 2000;
    v_msg := null;
    begin
        insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status)
        select m.id, 'nano_factory', 1, clock_timestamp(), clock_timestamp() + interval '1 hour', 'QUEUED'
          from public.planets m where m.parent_planet_id = v_p;
    exception when others then v_msg := sqlerrm; end;
    v_ok := v_msg like 'BUILDING_NOT_AVAILABLE_FOR_KIND%';
    insert into t_nf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. it cannot be queued on a moon (OGameX valid_planet_types = [Planet]) (%s)', coalesce(v_msg, 'ACCEPTED')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================ 8. Q13 — the balance reports the crawler term
    delete from public.planet_ships where planet_id = v_p;
    v_c_eff := public.calculate_crawler_energy_consumption(v_p);
    v_ok := v_c_eff = 0;
    insert into t_nf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8a. no crawlers -> crawler consumption %s', v_c_eff));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_p, 'crawler', 40);
    v_c_eff := public.calculate_crawler_energy_consumption(v_p);
    select b.energy_consumption_per_hour into v_cow from public.calculate_planet_energy_balance(v_p) b;
    v_ok := v_c_eff = 2000 and v_cow >= 2000;
    insert into t_nf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8b. 40 effective crawlers -> helper %s and the BALANCE now reports %s (before it reported 0 of crawler consumption)', v_c_eff, v_cow));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================ 9. the cap still applies (Q1 unchanged)
    update public.planet_ships set quantity = 1000 where planet_id = v_p and ship_id = 'crawler';
    v_c_eff := public.calculate_crawler_energy_consumption(v_p);
    v_ok := v_c_eff = 240 * 50;
    insert into t_nf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. Q1 intact: 1000 crawlers stay capped at 240 effective units -> %s energy, not 1000 x 50', v_c_eff));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================ 10. production still flows through the helper
    update public.planet_ships set quantity = 40 where planet_id = v_p and ship_id = 'crawler';
    select pp.metal_per_hour into v_pow from public.calculate_planet_production(v_p) pp;
    v_ok := v_pow > 0;
    insert into t_nf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. production still flows (metal/h = %s with 40 crawlers): the fix cannot change production, only the balance', round(v_pow, 2)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================ 11. ACL of the two new helpers
    v_ok := not has_function_privilege('anon', 'public.calculate_crawler_energy_consumption(uuid)', 'EXECUTE')
       and not has_function_privilege('authenticated', 'public.calculate_crawler_energy_consumption(uuid)', 'EXECUTE')
       and has_function_privilege('service_role', 'public.calculate_crawler_energy_consumption(uuid)', 'EXECUTE')
       and not has_function_privilege('anon', 'public.calculate_nanite_factory_build_speed(uuid)', 'EXECUTE')
       and has_function_privilege('authenticated', 'public.calculate_nanite_factory_build_speed(uuid)', 'EXECUTE');
    insert into t_nf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '11. ACL: crawler consumption is service_role only; the nanite speed helper is client-readable like the robot factory one');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================ 12. no second formula
    v_ok := exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                     where n.nspname = 'public' and p.proname = 'calculate_planet_production'
                       and p.prosrc ilike '%calculate_crawler_energy_consumption%')
       and exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                     where n.nspname = 'public' and p.proname = 'calculate_planet_energy_balance'
                       and p.prosrc ilike '%calculate_crawler_energy_consumption%')
       and exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                     where n.nspname = 'public' and p.proname = 'calculate_ship_build_time'
                       and p.prosrc ilike '%calculate_nanite_factory_build_speed%')
       and exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                     where n.nspname = 'public' and p.proname = 'calculate_defense_build_time'
                       and p.prosrc ilike '%calculate_nanite_factory_build_speed%')
       and not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                        where n.nspname = 'public' and p.proname = 'calculate_research_time'
                          and p.prosrc ilike '%nanite%');
    insert into t_nf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '12. one authority: both energy callers share the crawler helper, both unit callers share the nanite helper, research has neither');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_nf(resultado, prueba) values ('INFO',
      'INFO: OGameX unit formula has NO (1 + robot_factory) factor; LGI keeps its documented divergence and 2^nanite composes with it. LGI base times come from base_build_time_seconds, not (metal + crystal)/2500: recorded divergence (Q9), not converted.');

    if v_fail > 0 then
        raise exception 'NANITE/CRAWLER FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_nf order by orden;

drop table if exists t_nf;

ROLLBACK;
