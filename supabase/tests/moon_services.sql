-- MOON SERVICES FIXTURE (Sensor Phalanx + Jump Gate) — LA GRAN IMPLOSIÓN
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
-- Contract (20260926130400 / 20260926130500): phalanx ownership/range/cost/rejections, jump gate ownership/kind/
-- cooldown/transferability. LIMITATION: single-session harness; concurrency not executed.

begin;

drop table if exists t_svc;
create temp table t_svc(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_planet uuid; v_universe uuid; v_other uuid;
    v_galax integer; v_sys integer; v_pos integer;
    v_planet2 uuid; v_source uuid; v_target uuid; v_fleet uuid;
    v_deut_before numeric; v_deut_after numeric; v_rows integer; v_ships jsonb;
    v_ok boolean; v_fail integer := 0; v_raised text; v_cooldown integer; v_until timestamptz; v_qty bigint;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id, p.galaxy, p.system, p.position into v_planet, v_galax, v_sys, v_pos
      from public.planets p where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET'
      order by p.created_at limit 1;
    select pl.id into v_other from public.players pl where pl.id <> v_player order by pl.created_at limit 1;

    if v_player is null or v_planet is null or v_other is null then
        raise exception 'TEST_ABORT';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    delete from public.planets m where m.parent_planet_id = v_planet;

    insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
        temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind)
    values (v_universe, v_player, 'Second Planet', v_galax, v_sys + 200, 5, -10, 30, 100, 1, false, false, 'PLANET')
    returning id into v_planet2;

    insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
        temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind, parent_planet_id, moon_diameter_km)
    values (v_universe, v_player, 'Source Moon', v_galax, v_sys, v_pos, -20, 20, 10, 2, false, false,
            'MOON', v_planet, 2000)
    returning id into v_source;
    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at)
    values (v_source, 0, 0, 50000, 0, clock_timestamp()) on conflict (planet_id) do nothing;
    insert into public.planet_buildings(planet_id, building_id, level)
    values (v_source, 'sensor_phalanx', 2), (v_source, 'jump_gate', 1)
    on conflict (planet_id, building_id) do update set level = excluded.level;
    insert into public.planet_ships(planet_id, ship_id, quantity)
    values (v_source, 'light_fighter', 5), (v_source, 'solar_satellite', 2)
    on conflict (planet_id, ship_id) do update set quantity = excluded.quantity;

    insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
        temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind, parent_planet_id, moon_diameter_km)
    values (v_universe, v_player, 'Target Moon', v_galax, v_sys + 200, 5, -20, 20, 10, 1, false, false,
            'MOON', v_planet2, 2000)
    returning id into v_target;
    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at)
    values (v_target, 0, 0, 0, 0, clock_timestamp()) on conflict (planet_id) do nothing;
    insert into public.planet_buildings(planet_id, building_id, level) values (v_target, 'jump_gate', 1)
    on conflict (planet_id, building_id) do update set level = 1;

    v_raised := null;
    begin
        perform public.scan_with_phalanx(v_other, v_source, v_galax, v_sys);
    exception when others then
        v_raised := sqlerrm;
    end;
    v_ok := v_raised like 'PHALANX_MOON_NOT_OWNED%';
    insert into t_svc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. phalanx ownership (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_raised := null;
    begin
        perform public.scan_with_phalanx(v_player, v_source, v_galax, v_sys + 4);
    exception when others then
        v_raised := sqlerrm;
    end;
    v_ok := v_raised like 'PHALANX_TARGET_OUT_OF_RANGE%';
    insert into t_svc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. phalanx range (level 2 = 3 systems) (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_raised := null;
    begin
        perform public.scan_with_phalanx(v_player, v_source, v_galax + 1, v_sys);
    exception when others then
        v_raised := sqlerrm;
    end;
    v_ok := v_raised like 'PHALANX_TARGET_OUT_OF_GALAXY%';
    insert into t_svc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. phalanx never crosses galaxies (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at, status,
        destination_galaxy, destination_system, destination_position)
    values (v_player, v_planet, 'ATTACK', clock_timestamp(), clock_timestamp() + interval '2 hours', 'OUTBOUND',
            v_galax, v_sys + 1, v_pos)
    returning id into v_fleet;

    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'light_fighter', 3);

    select pr.deuterium into v_deut_before from public.planet_resources pr where pr.planet_id = v_source;

    select count(*)::integer, coalesce(max(t.out_ships::text)::jsonb, '{}'::jsonb)
      into v_rows, v_ships
      from public.scan_with_phalanx(v_player, v_source, v_galax, v_sys + 1) t;

    select pr.deuterium into v_deut_after from public.planet_resources pr where pr.planet_id = v_source;

    v_ok := v_rows = 1 and v_deut_before - v_deut_after = 5000 and v_ships = '{"light_fighter": 3}'::jsonb;
    insert into t_svc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. scan costs 5 000 deuterium and reports the incoming fleet (%s rows, %s -> %s, %s)',
             v_rows, v_deut_before, v_deut_after, v_ships));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    update public.planet_resources set deuterium = 10 where planet_id = v_source;
    v_raised := null;
    begin
        perform public.scan_with_phalanx(v_player, v_source, v_galax, v_sys);
    exception when others then
        v_raised := sqlerrm;
    end;
    v_ok := v_raised like 'PHALANX_INSUFFICIENT_DEUTERIUM%';
    insert into t_svc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. a scan without deuterium is refused (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* jump gate */
    v_raised := null;
    begin
        perform public.execute_jump_gate(v_player, v_source, v_target,
            '{"crawler": 1}'::jsonb);
    exception when others then
        v_raised := sqlerrm;
    end;
    v_ok := v_raised like 'JUMP_GATE_SHIP_NOT_TRANSFERABLE%' or v_raised like 'JUMP_GATE_UNKNOWN_SHIP%';
    insert into t_svc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. stationary ships cannot jump (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_raised := null;
    begin
        perform public.execute_jump_gate(v_player, v_source, v_target, '{"battleship": 1}'::jsonb);
    exception when others then
        v_raised := sqlerrm;
    end;
    v_ok := v_raised like 'JUMP_GATE_SHIPS_UNAVAILABLE%';
    insert into t_svc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. ships the source moon does not own are refused (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_raised := null;
    begin
        perform public.execute_jump_gate(v_other, v_source, v_target, '{"light_fighter": 1}'::jsonb);
    exception when others then
        v_raised := sqlerrm;
    end;
    v_ok := v_raised like 'JUMP_GATE_MOON_NOT_OWNED%';
    insert into t_svc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. jump gate ownership (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select t.out_cooldown_seconds, t.out_cooldown_until
      into v_cooldown, v_until
      from public.execute_jump_gate(v_player, v_source, v_target, '{"light_fighter": 4}'::jsonb) t;

    select coalesce(sum(quantity), 0) into v_qty from public.planet_ships where planet_id = v_source and ship_id = 'light_fighter';

    v_ok := v_cooldown > 0
            and abs(extract(epoch from (v_until - (clock_timestamp() + v_cooldown * interval '1 second')))) < 120
            and v_qty = 1
            and (select coalesce(quantity, 0) from public.planet_ships where planet_id = v_target and ship_id = 'light_fighter') = 4
            and (select jump_gate_cooldown_until from public.planets where id = v_source) = v_until;
    insert into t_svc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. jump moves 4 fighters, keeps 1 at the source and starts a %s s cooldown', v_cooldown));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_raised := null;
    begin
        perform public.execute_jump_gate(v_player, v_source, v_target, '{"light_fighter": 1}'::jsonb);
    exception when others then
        v_raised := sqlerrm;
    end;
    v_ok := v_raised like 'JUMP_GATE_ON_COOLDOWN%';
    insert into t_svc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. the cooldown refuses a second jump (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := has_function_privilege('authenticated', 'public.scan_with_phalanx(uuid, uuid, integer, integer)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.execute_jump_gate(uuid, uuid, uuid, jsonb)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.scan_with_phalanx(uuid, uuid, integer, integer)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.execute_jump_gate(uuid, uuid, uuid, jsonb)', 'EXECUTE');
    insert into t_svc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '11. ACL: both contracts are client-callable by authenticated users only');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_svc(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; concurrency not executed.');

    if v_fail > 0 then
        raise exception 'MOON SERVICES FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_svc order by orden;

drop table if exists t_svc;

ROLLBACK;

