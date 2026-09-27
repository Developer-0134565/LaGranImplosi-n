-- BUILDING PRODUCTION-DELTA HELPER FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract under test (migration 20260926082127_fix_building_production_delta_contract_and_acl):
--   * `calculate_building_production_delta` no longer raises. Before the fix it selected the non-existent
--     columns `r.economy_rate` / `r.production_rate` of `calculate_universe_rates()`, so EVERY call failed
--     with "column r.economy_rate does not exist";
--   * levels come from `planet_buildings` (current = max level, target = current + 1);
--   * mine deltas are the gross difference × universe economy × universe production;
--   * the solar-plant energy delta is the raw difference and is NOT rate scaled;
--   * a building that does not directly produce resources raises, and so does a missing/destroyed planet;
--   * EXECUTE is `postgres`/`service_role` only: the anon/authenticated surface was structurally unusable
--     (SECURITY INVOKER reading `universes`, which has no client SELECT grant).
--
-- LIMITATION: single-session harness; no concurrency is executed.

begin;

drop table if exists t_bpd;
create temp table t_bpd(orden serial, resultado text, prueba text);

do $test$
declare
    v_planet uuid;
    v_universe uuid;
    v_other uuid;
    v_econ numeric;
    v_prod numeric;
    v_d record;
    v_b text;
    v_raised boolean;
    v_err text;
    v_clean boolean := true;
    v_client boolean;
    v_service boolean;
    v_ok boolean;
    v_fail integer := 0;
begin
    select p.id, p.universe_id into v_planet, v_universe
      from public.planets p where not p.is_destroyed
     order by p.created_at, p.id limit 1;

    select p.id into v_other
      from public.planets p where p.id <> v_planet
     order by p.created_at, p.id limit 1;

    if v_planet is null or v_other is null then
        raise exception 'TEST_ABORT: two planets are required';
    end if;

    /* Rates != 1 make the rate-scaled vs raw assertions meaningful (all of it is rolled back). */
    update public.universes set economy_speed = 2, production_speed = 3 where id = v_universe;
    select r.economy, r.production into v_econ, v_prod
      from public.calculate_universe_rates(v_universe) r;

    delete from public.planet_buildings where planet_id = v_planet;
    insert into public.planet_buildings(planet_id, building_id, level)
    values (v_planet, 'metal_mine', 3), (v_planet, 'crystal_mine', 3),
           (v_planet, 'deuterium_synthesizer', 3), (v_planet, 'solar_plant', 3)
    on conflict (planet_id, building_id) do update set level = excluded.level;

    /* 1. METAL MINE */
    select * into v_d from public.calculate_building_production_delta(v_planet, 'metal_mine');
    v_ok := v_d.current_level = 3 and v_d.target_level = 4
        and v_d.metal_delta_per_hour = (30 * 4 * power(1.1, 4) - 30 * 3 * power(1.1, 3)) * v_econ * v_prod
        and v_d.crystal_delta_per_hour = 0 and v_d.deuterium_delta_per_hour = 0 and v_d.energy_delta_per_hour = 0;
    insert into t_bpd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. metal_mine 3->4: %s (rates %s x %s), other axes zero', v_d.metal_delta_per_hour, v_econ, v_prod));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 2. CRYSTAL MINE */
    select * into v_d from public.calculate_building_production_delta(v_planet, 'crystal_mine');
    v_ok := v_d.crystal_delta_per_hour = (20 * 4 * power(1.1, 4) - 20 * 3 * power(1.1, 3)) * v_econ * v_prod
        and v_d.metal_delta_per_hour = 0 and v_d.deuterium_delta_per_hour = 0 and v_d.energy_delta_per_hour = 0;
    insert into t_bpd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. crystal_mine 3->4: %s', v_d.crystal_delta_per_hour));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 3. DEUTERIUM SYNTHESIZER */
    select * into v_d from public.calculate_building_production_delta(v_planet, 'deuterium_synthesizer');
    v_ok := v_d.deuterium_delta_per_hour = (10 * 4 * power(1.1, 4) - 10 * 3 * power(1.1, 3)) * v_econ * v_prod
        and v_d.metal_delta_per_hour = 0 and v_d.crystal_delta_per_hour = 0 and v_d.energy_delta_per_hour = 0;
    insert into t_bpd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. deuterium_synthesizer 3->4: %s', v_d.deuterium_delta_per_hour));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 4. SOLAR PLANT: ENERGY IS NOT RATE SCALED */
    select * into v_d from public.calculate_building_production_delta(v_planet, 'solar_plant');
    v_ok := v_d.energy_delta_per_hour = (20 * 4 * power(1.1, 4) - 20 * 3 * power(1.1, 3))
        and v_d.energy_delta_per_hour <> (20 * 4 * power(1.1, 4) - 20 * 3 * power(1.1, 3)) * v_econ * v_prod
        and v_d.metal_delta_per_hour = 0 and v_d.crystal_delta_per_hour = 0 and v_d.deuterium_delta_per_hour = 0;
    insert into t_bpd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. solar_plant energy delta %s = raw (not x %s)', v_d.energy_delta_per_hour, v_econ * v_prod));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 5. REGRESSION: ALL FOUR RESOURCE BUILDINGS CALL CLEANLY (the pre-fix failure) */
    foreach v_b in array array['metal_mine', 'crystal_mine', 'deuterium_synthesizer', 'solar_plant']
    loop
        v_raised := false; v_err := null;
        begin
            perform * from public.calculate_building_production_delta(v_planet, v_b);
        exception when others then v_raised := true; v_err := sqlerrm;
        end;
        if v_raised then v_clean := false; end if;
    end loop;
    insert into t_bpd(resultado, prueba) values (case when v_clean then 'PASS' else 'FAIL' end,
      format('5. no resource building raises any more [last error: %s]', coalesce(v_err, 'none')));
    v_fail := v_fail + case when v_clean then 0 else 1 end;

    /* 6. LEVEL 0 -> 1 IS THE BASE PRODUCTION */
    delete from public.planet_buildings where planet_id = v_planet and building_id = 'metal_mine';
    select * into v_d from public.calculate_building_production_delta(v_planet, 'metal_mine');
    v_ok := v_d.current_level = 0 and v_d.target_level = 1
        and v_d.metal_delta_per_hour = (30 * 1 * power(1.1, 1)) * v_econ * v_prod;
    insert into t_bpd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. level 0->1: %s with levels %s->%s', v_d.metal_delta_per_hour, v_d.current_level, v_d.target_level));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 7. NON-PRODUCING BUILDING REFUSED */
    v_raised := false; v_err := null;
    begin
        perform * from public.calculate_building_production_delta(v_planet, 'shipyard');
    exception when others then v_raised := true; v_err := sqlerrm;
    end;
    v_ok := v_raised and v_err like 'Building shipyard does not directly produce resources%';
    insert into t_bpd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. non-producing building refused [%s / %s]', v_raised, v_err));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 8. DESTROYED PLANET REFUSED */
    update public.planets set is_destroyed = true where id = v_other;
    v_raised := false; v_err := null;
    begin
        perform * from public.calculate_building_production_delta(v_other, 'metal_mine');
    exception when others then v_raised := true; v_err := sqlerrm;
    end;
    v_ok := v_raised and v_err like '%does not exist or is destroyed%';
    insert into t_bpd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. destroyed planet refused [%s / %s]', v_raised, v_err));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 9. ACL: CLIENT SURFACE CLOSED, SERVICE ROLE KEEPS EXECUTE */
    select has_function_privilege('authenticated', 'public.calculate_building_production_delta(uuid,text)', 'EXECUTE')
        or has_function_privilege('anon', 'public.calculate_building_production_delta(uuid,text)', 'EXECUTE')
      into v_client;
    select has_function_privilege('service_role', 'public.calculate_building_production_delta(uuid,text)', 'EXECUTE')
      into v_service;
    v_ok := not v_client and v_service;
    insert into t_bpd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. ACL: client EXECUTE = %s, service_role = %s', v_client, v_service));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 10. THE PRODUCTION AUTHORITY IS UNTOUCHED: full level vs next-level delta */
    insert into public.planet_buildings(planet_id, building_id, level)
    values (v_planet, 'metal_mine', 3), (v_planet, 'solar_plant', 3)
    on conflict (planet_id, building_id) do update set level = excluded.level;

    v_ok := (select pp.metal_per_hour from public.calculate_planet_production(v_planet) pp)
         >= (select d.metal_delta_per_hour from public.calculate_building_production_delta(v_planet, 'metal_mine') d);
    insert into t_bpd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10. calculate_planet_production stays the authority (full level) while the helper reports the next-level delta');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_bpd(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; concurrency is not executed.');

    if v_fail > 0 then
        raise exception 'BUILDING PRODUCTION DELTA FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_bpd order by orden;

drop table if exists t_bpd;

ROLLBACK;

