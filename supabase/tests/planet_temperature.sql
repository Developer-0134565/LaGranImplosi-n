-- PLANET TEMPERATURE SYSTEM FIXTURE — LA GRAN IMPLOSIÓN
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
-- Contract (20260930160000 + 20260930161000): the position→temperature model, the 40-degree range, the
-- deuterium temperature factor 1.44 - 0.004*T_avg (OGameX BuildingObjects.php:86), the solar satellite
-- energy floor((T_max + 140)/6) (OGameX CivilShipObjects.php:171), the backfill, the totality of
-- planet_temperature(), and the ACL/ownership posture.
-- LIMITATION: single-session harness; concurrency not executed.

begin;

drop table if exists t_temp;
create temp table t_temp(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_universe uuid;
    v_hot uuid; v_mid uuid; v_cold uuid; v_foreign uuid;
    v_tmin integer; v_tmax integer; v_tavg integer;
    v_deut_hot numeric; v_deut_mid numeric; v_deut_cold numeric;
    v_en_hot numeric; v_en_mid numeric; v_en_cold numeric; v_en_hot0 numeric;
    v_ok boolean; v_fail integer := 0; v_rows integer; v_count integer; i integer;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    if v_player is null or v_universe is null then
        raise exception 'TEST_ABORT: an auth-linked player is required';
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    -- ---------------------------------------------------------------- 1. the position model
    v_ok := true;
    foreach i in array array[1,5,8,10,15] loop
        select t.temperature_min, t.temperature_max, t.temperature_average
          into v_tmin, v_tmax, v_tavg
          from public.planet_temperature_for_position(i) t;
        if v_tmax - v_tmin <> 40 or v_tavg <> v_tmax - 20 then v_ok := false; end if;
    end loop;
    select t.temperature_min, t.temperature_max into v_tmin, v_tmax from public.planet_temperature_for_position(1) t;
    v_ok := v_ok and v_tmin = 200 and v_tmax = 240;
    select t.temperature_min, t.temperature_max into v_tmin, v_tmax from public.planet_temperature_for_position(8) t;
    v_ok := v_ok and v_tmin = 10 and v_tmax = 50;
    select t.temperature_min, t.temperature_max into v_tmin, v_tmax from public.planet_temperature_for_position(15) t;
    v_ok := v_ok and v_tmin = -150 and v_tmax = -110;
    insert into t_temp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '1. position model: pos 1 = 200/240, pos 8 = 10/50, pos 15 = -150/-110, always a 40-degree range, avg = max - 20');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ---------------------------------------------------------------- 2. upstream quirks preserved
    select t.temperature_max into v_tmax from public.planet_temperature_for_position(12) t;
    v_ok := v_tmax = 10;
    select t.temperature_max into v_tmax from public.planet_temperature_for_position(13) t;
    v_ok := v_ok and v_tmax = -30;
    insert into t_temp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '2. the irregular 12->13 step of the OGameX table (10 then -30) is preserved verbatim, not smoothed');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ---------------------------------------------------------------- 3. out-of-range position
    select t.temperature_min, t.temperature_max, t.temperature_average
      into v_tmin, v_tmax, v_tavg from public.planet_temperature_for_position(0) t;
    v_ok := v_tmin = -20 and v_tmax = 20 and v_tavg = 0;
    insert into t_temp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. out-of-range position falls back to the OGameX [0,40] band (got %s/%s avg %s)', v_tmin, v_tmax, v_tavg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ---------------------------------------------------------------- 4. backfill on the real universe
    select count(*) into v_count from public.planets
     where temperature_min is null or temperature_max is null;
    select count(*) into v_rows
      from public.planets p join public.planet_temperature_for_position(p.position) m on true
     where p.temperature_min <> m.temperature_min
        or p.temperature_max <> m.temperature_max
        or p.temperature_max - p.temperature_min <> 40;
    v_ok := v_count = 0 and v_rows = 0;
    insert into t_temp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. backfill complete: %s planets without temperature, %s disagreeing with the model or the range', v_count, v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ---------------------------------------------------------------- 5. totality of planet_temperature()
    select count(*) into v_rows from public.planet_temperature(gen_random_uuid());
    v_ok := v_rows = 1
       and not exists (select 1 from public.planet_temperature(gen_random_uuid()) t
                        where t.temperature_min is null or t.temperature_max is null or t.temperature_average is null);
    select count(*) into v_rows from public.planet_temperature(null);
    v_ok := v_ok and v_rows = 1;
    insert into t_temp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '5. planet_temperature() is total: a random UUID and a NULL UUID both return exactly one non-NULL row');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- three identical probe planets, one per temperature zone (1 = hottest, 8 = mid, 15 = coldest)
    delete from public.planets where galaxy = 499 and system = 498 and position in (1, 8, 15);
    insert into public.planets(universe_id, player_id, name, galaxy, system, position,
        temperature_min, temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind)
    select v_universe, v_player, format('TempProbe P%s', pos), 499, 498, pos,
           t.temperature_min, t.temperature_max, 200, 0, false, false, 'PLANET'
      from unnest(array[1,8,15]) as g(pos)
      cross join lateral public.planet_temperature_for_position(g.pos) t;
    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at)
    select id, 1000000, 1000000, 1000000, 0, clock_timestamp() from public.planets
     where galaxy = 499 and system = 498 and position in (1, 8, 15);

    -- identical buildings everywhere; NO crawler, NO fusion plant: the temperature is then the ONLY variable
    insert into public.planet_buildings(planet_id, building_id, level)
    select id, 'metal_mine', 10 from public.planets where galaxy = 499 and system = 498 and position in (1,8,15)
    union all select id, 'crystal_mine', 10 from public.planets where galaxy = 499 and system = 498 and position in (1,8,15)
    union all select id, 'deuterium_synthesizer', 10 from public.planets where galaxy = 499 and system = 498 and position in (1,8,15)
    union all select id, 'solar_plant', 60 from public.planets where galaxy = 499 and system = 498 and position in (1,8,15);

    select id into v_hot from public.planets where galaxy = 499 and system = 498 and position = 1;
    select id into v_mid from public.planets where galaxy = 499 and system = 498 and position = 8;
    select id into v_cold from public.planets where galaxy = 499 and system = 498 and position = 15;

    -- ---------------------------------------------------------------- 6. deuterium: cold > medium > hot
    select pp.deuterium_per_hour into v_deut_hot from public.calculate_planet_production(v_hot) pp;
    select pp.deuterium_per_hour into v_deut_mid from public.calculate_planet_production(v_mid) pp;
    select pp.deuterium_per_hour into v_deut_cold from public.calculate_planet_production(v_cold) pp;
    v_ok := v_deut_cold > v_deut_mid and v_deut_mid > v_deut_hot;
    insert into t_temp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. deuterium cold(%s) > medium(%s) > hot(%s) at the same synthesizer level', v_deut_cold, v_deut_mid, v_deut_hot));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- exact ratio: with no crawler and no fusion, deuterium = 10*L*1.1^L * factor * rates, so the ratio
    -- between two planets equals the ratio of the temperature factors 0.56 / 1.32 / 1.96
    v_ok := abs(v_deut_hot / v_deut_mid - (0.56 / 1.32)) < 0.0000001
       and abs(v_deut_cold / v_deut_mid - (1.96 / 1.32)) < 0.0000001;
    insert into t_temp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. the deuterium ratio equals the exact OGameX factor ratio (hot/mid %s vs 0.424242, cold/mid %s vs 1.484848)',
             round(v_deut_hot / v_deut_mid, 6), round(v_deut_cold / v_deut_mid, 6)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ---------------------------------------------------------------- 8. solar satellites
    select pp.energy_per_hour into v_en_hot0 from public.calculate_planet_production(v_hot) pp;
    insert into public.planet_ships(planet_id, ship_id, quantity)
    values (v_hot, 'solar_satellite', 10), (v_mid, 'solar_satellite', 10), (v_cold, 'solar_satellite', 10);
    select pp.energy_per_hour into v_en_hot from public.calculate_planet_production(v_hot) pp;
    select pp.energy_per_hour into v_en_mid from public.calculate_planet_production(v_mid) pp;
    select pp.energy_per_hour into v_en_cold from public.calculate_planet_production(v_cold) pp;

    v_ok := v_en_hot > v_en_mid and v_en_mid > v_en_cold;
    insert into t_temp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. 10 satellites: hot(%s) > medium(%s) > cold(%s) energy', v_en_hot, v_en_mid, v_en_cold));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- exact: floor((T_max+140)/6) per satellite -> pos1 63, pos8 31, pos15 5
    v_ok := v_en_hot - v_en_hot0 = 630 and v_en_mid - v_en_hot0 = 310 and v_en_cold - v_en_hot0 = 50;
    insert into t_temp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. exact satellite energy floor((T_max+140)/6): hot +%s, mid +%s, cold +%s (expected 630/310/50)',
             v_en_hot - v_en_hot0, v_en_mid - v_en_hot0, v_en_cold - v_en_hot0));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ---------------------------------------------------------------- 10. only deuterium depends on the temperature
    select (select pp.metal_per_hour from public.calculate_planet_production(v_hot) pp)
         = (select pp.metal_per_hour from public.calculate_planet_production(v_mid) pp)
      and (select pp.crystal_per_hour from public.calculate_planet_production(v_hot) pp)
        = (select pp.crystal_per_hour from public.calculate_planet_production(v_mid) pp)
      and (select pp.deuterium_per_hour from public.calculate_planet_production(v_hot) pp)
        <> (select pp.deuterium_per_hour from public.calculate_planet_production(v_mid) pp) into v_ok;
    insert into t_temp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10. deuterium depends on the temperature and metal/crystal do not (same level, different zone)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ---------------------------------------------------------------- 11. integrity of the read
    select p.position, r.metal, r.crystal, r.deuterium into v_count, v_deut_hot, v_deut_mid, v_deut_cold
      from public.planets p join public.planet_resources r on r.planet_id = p.id where p.id = v_mid;
    v_ok := v_count = 8 and v_deut_hot = 1000000 and v_deut_mid = 1000000 and v_deut_cold = 1000000;
    select count(*) into v_rows from public.planet_buildings where planet_id = v_mid;
    v_ok := v_ok and v_rows = 4;
    select count(*) into v_rows from public.fleet_movements where origin_planet_id = v_mid;
    v_ok := v_ok and v_rows = 0;
    insert into t_temp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11. reading the production touches nothing: position, resources, 4 buildings and 0 fleets intact (fleets %s)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ---------------------------------------------------------------- 12. security / ownership
    v_ok := not has_function_privilege('anon', 'public.planet_temperature(uuid)', 'EXECUTE')
       and not has_function_privilege('authenticated', 'public.planet_temperature(uuid)', 'EXECUTE')
       and not has_function_privilege('anon', 'public.planet_temperature_for_position(integer)', 'EXECUTE')
       and not has_function_privilege('authenticated', 'public.planet_temperature_for_position(integer)', 'EXECUTE')
       and has_function_privilege('service_role', 'public.planet_temperature(uuid)', 'EXECUTE');
    insert into t_temp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '12. the temperature helpers are not client-callable (no anon/authenticated EXECUTE) and are service_role');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- a foreign planet leaks nothing through the own-planet economy contract, with and without session
    select p.id into v_foreign from public.planets p
     where p.id <> v_mid and p.player_id <> v_player and not p.is_destroyed limit 1;
    select count(*) into v_rows from public.get_planet_economy_overview(v_foreign);
    v_ok := v_rows = 0;
    perform set_config('request.jwt.claims', '{}', true);
    select count(*) into v_rows from public.get_planet_economy_overview(v_mid);
    v_ok := v_ok and v_rows = 0;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    insert into t_temp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '13. foreign planet with a session and own planet without a session both return zero rows (fail closed)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_temp(resultado, prueba) values ('INFO',
      'INFO: the per-row random draw of the OGameX table is replaced by the band midpoint (recorded INTENTIONAL LGI DIFFERENCE 1); the 40-degree range and both formulas are upstream.');

    if v_fail > 0 then
        raise exception 'PLANET TEMPERATURE FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_temp order by orden;

drop table if exists t_temp;

ROLLBACK;


