-- MOON DESTRUCTION MISSION FIXTURE — LA GRAN IMPLOSIÓN
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
-- Contract (20260926190000_moon_destruction_mission.sql), OGameX MoonDestructionMission parity:
--   mission_type MOON_DESTRUCTION accepted by the CHECK, classified as a WAR mission (FleetSpeedType::war),
--   dispatched through the certified start_fleet_mixed, resolved by resolve_attack_arrival and routed by
--   process_fleet_movements; the destruction roll stays in the certified hook settle_moon_destruction_for_battle.
-- LIMITATION: single-session harness; the roll is random, so the outcome is asserted structurally (attempt row
-- plus chance/roll/destroyed consistency) and the global worker is asserted statically.

begin;

drop table if exists t_md;
create temp table t_md(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_universe uuid; v_origin uuid; v_ai uuid; v_ai_planet uuid; v_moon uuid;
    v_own_moon uuid; v_fleet uuid; v_attack_fleet uuid; v_md_secs numeric; v_atk_secs numeric;
    v_speed numeric; v_war_speed numeric; v_ok boolean; v_fail integer := 0;
    v_e1 text; v_e2 text; v_e3 text; v_battles_before integer; v_battles_after integer;
    v_attempt record; v_expected_chance numeric; v_status text; v_src text; v_i integer; v_galaxy integer;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_origin from public.planets p
     where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET' order by p.created_at limit 1;

    select pl.id into v_ai from public.players pl
     where pl.player_type = 'AI' and pl.id <> v_player order by pl.created_at limit 1;

    if v_player is null or v_origin is null or v_ai is null then
        raise exception 'TEST_ABORT: an auth-linked player, its planet and an AI player are required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    delete from public.fleet_movements where player_id = v_player;
    delete from public.planet_buildings where planet_id = v_origin;
    delete from public.planets where parent_planet_id = v_origin;
    insert into public.planet_buildings(planet_id, building_id, level) values
        (v_origin, 'shipyard', 12), (v_origin, 'metal_storage', 10), (v_origin, 'crystal_storage', 10),
        (v_origin, 'deuterium_tank', 10);
    insert into public.player_research(player_id, research_id, level) values
        (v_player, 'hyperspace_technology', 6), (v_player, 'hyperspace_drive', 7), (v_player, 'graviton_technology', 1),
        (v_player, 'computer_technology', 3)
    on conflict (player_id, research_id) do update set level = excluded.level;
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_origin, 'deathstar', 2)
    on conflict (planet_id, ship_id) do update set quantity = 2;
    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at, updated_at)
    values (v_origin, 50000000, 50000000, 50000000, 0, now(), now())
    on conflict (planet_id) do update
       set metal = 50000000, crystal = 50000000, deuterium = 50000000, last_calculated_at = now();

    /* foreign target: an AI planet in the same system (minimum fuel) plus its moon */
    v_galaxy := coalesce((select max(p.galaxy) from public.planets p), 1);
    v_ai_planet := null;
    for v_i in 1..40 loop
        begin
            insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
                temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind)
            values (v_universe, v_ai, 'MdTarget' || v_i, v_galaxy, 470 + ((v_i - 1) % 20), 1 + ((v_i - 1) / 20),
                    -20, 20, 10, 0, false, false, 'PLANET')
            returning id into v_ai_planet;
            exit;
        exception when unique_violation then
            v_ai_planet := null;
        end;
    end loop;

    if v_ai_planet is null then
        raise exception 'TEST_ABORT: no free position in the origin system for the foreign target';
    end if;

    insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
        temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind, parent_planet_id, moon_diameter_km)
    select v_universe, v_ai, 'MdTargetMoon', p.galaxy, p.system, p.position, -20, 20, 10, 0, false, false,
           'MOON', p.id, 5000
      from public.planets p where p.id = v_ai_planet
    returning id into v_moon;

    insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_moon, 'rocket_launcher', 2);
    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at, updated_at)
    values (v_moon, 0, 0, 0, 0, now(), now())
    on conflict (planet_id) do nothing;

    insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
        temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind, parent_planet_id, moon_diameter_km)
    select v_universe, v_player, 'MdOwnMoon', p.galaxy, p.system, p.position, -20, 20, 10, 0, false, false,
           'MOON', p.id, 5000
      from public.planets p where p.id = v_origin
    returning id into v_own_moon;

    /* 1. OGameX isMissionPossible equivalents */
    v_e1 := null; v_e2 := null; v_e3 := null;
    begin
        perform public.start_moon_destruction(v_player, v_origin, v_moon, jsonb_build_object('cruiser', 1));
    exception when others then v_e1 := sqlerrm; end;
    begin
        perform public.start_moon_destruction(v_player, v_origin, v_ai_planet, jsonb_build_object('deathstar', 1));
    exception when others then v_e2 := sqlerrm; end;
    begin
        perform public.start_moon_destruction(v_player, v_origin, v_own_moon, jsonb_build_object('deathstar', 1));
    exception when others then v_e3 := sqlerrm; end;

    v_ok := v_e1 like 'MOON_DESTRUCTION_DEATHSTAR_REQUIRED%'
            and v_e2 like 'MOON_DESTRUCTION_TARGET_NOT_A_MOON%'
            and v_e3 like 'MOON_DESTRUCTION_TARGET_OWN%';
    insert into t_md(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. deathstar required (%s), moon required (%s), foreign owner required (%s)',
             coalesce(v_e1,'accepted'), coalesce(v_e2,'accepted'), coalesce(v_e3,'accepted')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 2. happy dispatch through the certified dispatcher */
    v_fleet := public.start_moon_destruction(v_player, v_origin, v_moon, jsonb_build_object('deathstar', 1));
    v_ok := exists (select 1 from public.fleet_movements fm
                     where fm.id = v_fleet and fm.mission_type = 'MOON_DESTRUCTION' and fm.status = 'OUTBOUND'
                       and fm.destination_planet_id = v_moon
                       and fm.destination_galaxy = (select p.galaxy from public.planets p where p.id = v_moon)
                       and fm.destination_system = (select p.system from public.planets p where p.id = v_moon)
                       and fm.destination_position = (select p.position from public.planets p where p.id = v_moon));
    insert into t_md(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. dispatched MOON_DESTRUCTION fleet to the target moon (%s)', coalesce(v_fleet::text, 'null')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 3. war speed class + duration parity with an equivalent ATTACK dispatch */
    select u.war_fleet_speed into v_war_speed from public.universes u where u.id = v_universe;
    v_speed := public.calculate_mission_fleet_speed_multiplier(v_universe, 'MOON_DESTRUCTION');
    v_attack_fleet := (select fm.fleet_id
                         from public.start_fleet_mixed(v_player, v_origin, v_moon,
                                  jsonb_build_object('deathstar', 1), 'ATTACK') fm limit 1);
    select extract(epoch from (fm.arrives_at - fm.started_at)) into v_md_secs
      from public.fleet_movements fm where fm.id = v_fleet;
    select extract(epoch from (fm.arrives_at - fm.started_at)) into v_atk_secs
      from public.fleet_movements fm where fm.id = v_attack_fleet;

    v_ok := v_speed = v_war_speed and abs(v_md_secs - v_atk_secs) < 1;
    insert into t_md(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. war speed class (%s/%s) and duration parity with ATTACK (%s vs %s s)',
             v_speed, v_war_speed, v_md_secs, v_atk_secs));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 4. worker routing is in place (static contract: the global worker cannot be run safely from a fixture) */
    select pg_get_functiondef(p.oid) into v_src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'process_fleet_movements';
    v_ok := v_src like '%MOON_DESTRUCTION%' and v_src like '%resolve_attack_arrival%';
    insert into t_md(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '4. process_fleet_movements routes MOON_DESTRUCTION to the certified attack resolver');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 5. resolution: combat + the certified destruction hook (no duplicated rules) */
    select count(*) into v_battles_before from public.combat_battles;
    update public.fleet_movements set status = 'ARRIVED' where id = v_fleet;

    v_e1 := null;
    begin
        perform public.resolve_attack_arrival(v_fleet);
    exception when others then v_e1 := sqlerrm; end;

    select count(*) into v_battles_after from public.combat_battles;
    select fm.status into v_status from public.fleet_movements fm where fm.id = v_fleet;
    select * into v_attempt from public.moon_destruction_attempts a
     where a.moon_id = v_moon order by a.created_at desc limit 1;

    v_expected_chance := least(100, greatest(0, (100 - sqrt(5000)) * sqrt(1)));
    v_ok := v_e1 is null and v_battles_after = v_battles_before + 1 and v_attempt.battle_id is not null
            and v_attempt.deathstars >= 1
            and abs(v_attempt.success_chance - v_expected_chance) < 1
            and v_attempt.destroyed = (v_attempt.roll <= v_attempt.success_chance)
            and v_status <> 'OUTBOUND';
    insert into t_md(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. resolution: battles %s→%s, chance %s (OGameX %s), roll %s, destroyed %s, fleet %s%s',
             v_battles_before, v_battles_after, v_attempt.success_chance, v_expected_chance, v_attempt.roll,
             v_attempt.destroyed, v_status, coalesce(' [' || v_e1 || ']', '')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 6. ACL: no anon bypass */
    v_ok := not has_function_privilege('anon', 'public.start_moon_destruction(uuid,uuid,uuid,jsonb)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.start_moon_destruction(uuid,uuid,uuid,jsonb)', 'EXECUTE');
    insert into t_md(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '6. ACL: start_moon_destruction is authenticated/service_role only');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_md(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness (no concurrency, global worker asserted statically). The destruction roll is random: the fixture asserts the OGameX chance formula and the chance/roll/destroyed consistency instead of a fixed outcome.');

    if v_fail > 0 then
        raise exception 'MOON DESTRUCTION FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_md order by orden;

drop table if exists t_md;

ROLLBACK;
