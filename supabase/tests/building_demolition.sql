-- BUILDING DEMOLITION FIXTURE — LA GRAN IMPLOSIÓN
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
-- Contract (20260926160000_building_demolition.sql): OGameX downgrade parity —
-- cost = construction price of the removed level minus 4 % per ion_technology level,
-- duration = construction formula at the removed level, one level per queue item, level 0 allowed,
-- guards (dependents / active research / active unit order / busy queue), is_downgrade flag,
-- cancel refunds exactly the charge, and the certified upgrade path is untouched.
-- LIMITATION: single-session harness; concurrency is not executed (only the FOR UPDATE ordering is inspected).

begin;

drop table if exists t_bd;
create temp table t_bd(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_planet uuid; v_universe uuid;
    v_moon uuid; v_ai uuid; v_ai_planet uuid; v_queue uuid; v_inspect record;
    v_ok boolean; v_fail integer := 0; v_raised text;
    v_m0 numeric; v_m1 numeric; v_f0 integer; v_f1 integer;
    v_base_m numeric; v_base_c numeric; v_base_d numeric; v_expected numeric;
    v_charge numeric; v_level integer;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_planet
      from public.planets p where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET'
      order by p.created_at limit 1;

    if v_player is null or v_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet is required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* deterministic slate for the test planet */
    delete from public.building_queue where planet_id = v_planet;
    delete from public.shipyard_queue where planet_id = v_planet;
    delete from public.defense_queue where planet_id = v_planet;
    delete from public.research_queue where player_id = v_player;
    delete from public.planet_buildings where planet_id = v_planet;
    delete from public.player_research where player_id = v_player and research_id = 'ion_technology';
    update public.planets set fields_used = 5 where id = v_planet;
    update public.planet_resources
       set metal = 30000, crystal = 30000, deuterium = 30000, last_calculated_at = now()
     where planet_id = v_planet;

    /* 1. schema + ACL */
    v_ok := exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'building_queue'
                       and column_name = 'is_downgrade' and column_default = 'false')
            and exists (select 1 from pg_constraint
                         where conname = 'building_queue_target_level_check'
                           and pg_get_constraintdef(oid) like '%>= 0%')
            and not has_function_privilege('anon', 'public.start_demolition(uuid,uuid,text)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.can_start_demolition(uuid,uuid,text)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.inspect_demolition(uuid,uuid,text)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.start_demolition(uuid,uuid,text)', 'EXECUTE');
    insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '1. is_downgrade flag, target_level >= 0, no anon bypass on the demolition contract');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 2. preview: level 3, ion 0, cost = the construction price of the removed level */
    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'metal_mine', 3);
    select c.metal, c.crystal, c.deuterium into v_base_m, v_base_c, v_base_d
      from public.calculate_building_cost('metal_mine', 3) c;

    select * into v_inspect from public.can_start_demolition(v_player, v_planet, 'metal_mine');
    v_ok := v_inspect.allowed and v_inspect.current_level = 3 and v_inspect.target_level = 2
            and v_inspect.ion_technology_level = 0 and v_inspect.is_downgrade
            and v_inspect.duration_seconds > 0
            /* OGameX getObjectDowngradePrice floors every resource, ion 0 included */
            and v_inspect.cost_metal = floor(v_base_m) and v_inspect.cost_crystal = floor(v_base_c)
            and v_inspect.cost_deuterium = floor(v_base_d);
    insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. preview 3->2 charges the level price (reason=%s, metal=%s)', v_inspect.reason, v_inspect.cost_metal));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 3. execution: is_downgrade queue item + exact charge */
    update public.planet_resources set last_calculated_at = now() where planet_id = v_planet;
    select metal into v_m0 from public.planet_resources where planet_id = v_planet;

    v_queue := public.start_demolition(v_player, v_planet, 'metal_mine');

    select metal into v_m1 from public.planet_resources where planet_id = v_planet;
    v_charge := v_m0 - v_m1;

    v_ok := exists (select 1 from public.building_queue q
                     where q.id = v_queue and q.is_downgrade and q.target_level = 2 and upper(q.status) = 'BUILDING')
            and abs(v_charge - v_base_m) < 1;
    insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. start_demolition queues is_downgrade target 2 and charges %s (expected %s)', v_charge, v_base_m));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 4. completion: level 2 and one field released */
    select fields_used into v_f0 from public.planets where id = v_planet;
    update public.planet_resources set last_calculated_at = now() - interval '1 hour' where planet_id = v_planet;
    update public.building_queue
       set started_at = now() - interval '1 hour', finishes_at = now() - interval '30 minutes'
     where id = v_queue;

    v_level := public.complete_building(v_queue);
    select fields_used into v_f1 from public.planets where id = v_planet;

    v_ok := v_level = 2
            and (select coalesce(max(level), 0) from public.planet_buildings
                  where planet_id = v_planet and building_id = 'metal_mine') = 2
            and v_f1 = v_f0 - 1;
    insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. completion sets level 2 and releases a field (%s -> %s)', v_f0, v_f1));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 5. replay/idempotency: a second completion is a no-op */
    select fields_used into v_f0 from public.planets where id = v_planet;
    v_level := public.complete_building(v_queue);
    select fields_used into v_f1 from public.planets where id = v_planet;

    v_ok := v_level = 2 and v_f1 = v_f0
            and (select count(*) from public.planet_buildings
                  where planet_id = v_planet and building_id = 'metal_mine' and level = 2) = 1;
    insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '5. replay of complete_building is idempotent (no double field release)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 6. last level: 1 -> 0 is legal, and afterwards the demolition is refused */
    delete from public.building_queue where planet_id = v_planet;
    update public.planet_buildings set level = 1 where planet_id = v_planet and building_id = 'metal_mine';

    v_queue := public.start_demolition(v_player, v_planet, 'metal_mine');
    update public.planet_resources set last_calculated_at = now() - interval '1 hour' where planet_id = v_planet;
    update public.building_queue
       set started_at = now() - interval '1 hour', finishes_at = now() - interval '30 minutes'
     where id = v_queue;
    v_level := public.complete_building(v_queue);

    select * into v_inspect from public.can_start_demolition(v_player, v_planet, 'metal_mine');
    v_ok := v_level = 0
            and (select coalesce(max(level), 0) from public.planet_buildings
                  where planet_id = v_planet and building_id = 'metal_mine') = 0
            and not v_inspect.allowed and v_inspect.reason = 'DEMOLITION_LEVEL_ZERO';
    insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. 1->0 demolition allowed, level 0 row kept, then %s', v_inspect.reason));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 7. ion technology: 4 % cheaper per level */
    delete from public.building_queue where planet_id = v_planet;
    update public.planet_buildings set level = 3 where planet_id = v_planet and building_id = 'metal_mine';
    select c.metal into v_base_m from public.calculate_building_cost('metal_mine', 3) c;
    v_expected := floor(v_base_m * 0.8);

    insert into public.player_research(player_id, research_id, level) values (v_player, 'ion_technology', 5)
    on conflict (player_id, research_id) do update set level = 5;

    select * into v_inspect from public.can_start_demolition(v_player, v_planet, 'metal_mine');
    update public.planet_resources set last_calculated_at = now() where planet_id = v_planet;
    select metal into v_m0 from public.planet_resources where planet_id = v_planet;
    v_queue := public.start_demolition(v_player, v_planet, 'metal_mine');
    select metal into v_m1 from public.planet_resources where planet_id = v_planet;
    v_charge := v_m0 - v_m1;

    v_ok := v_inspect.ion_technology_level = 5 and v_inspect.cost_metal = v_expected
            and abs(v_charge - v_expected) < 1;
    insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. ion 5 keeps 80 %% of the level price (preview %s, charged %s, expected %s)',
             v_inspect.cost_metal, v_charge, v_expected));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 8. dependents block the demolition, and the moon field capacity follows the lunar base */
    delete from public.building_queue where planet_id = v_planet;
    delete from public.planets where parent_planet_id = v_planet;

    insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
        temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind, parent_planet_id, moon_diameter_km)
    select v_universe, v_player, 'DemoMoon', p.galaxy, p.system, p.position, -20, 20, 10, 0, false, false,
           'MOON', p.id, 2000
      from public.planets p where p.id = v_planet
    returning id into v_moon;

    insert into public.planet_buildings(planet_id, building_id, level)
    values (v_moon, 'lunar_base', 1), (v_moon, 'sensor_phalanx', 1);

    select * into v_inspect from public.can_start_demolition(v_player, v_moon, 'lunar_base');
    v_ok := not v_inspect.allowed and v_inspect.reason = 'DEMOLITION_BLOCKED_BY_DEPENDENTS'
            and not v_inspect.dependents_met and v_inspect.target_level = 0;
    insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8a. sensor_phalanx keeps lunar_base 1 alive (%s)', v_inspect.reason));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    delete from public.planet_buildings where planet_id = v_moon and building_id = 'sensor_phalanx';
    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at, updated_at)
    values (v_moon, 60000, 60000, 60000, 0, now(), now())
    on conflict (planet_id) do update
       set metal = 60000, crystal = 60000, deuterium = 60000, last_calculated_at = now();

    select fields_total into v_f0 from public.planets where id = v_moon;
    v_queue := public.start_demolition(v_player, v_moon, 'lunar_base');
    update public.planet_resources set last_calculated_at = now() - interval '1 hour' where planet_id = v_moon;
    update public.building_queue
       set started_at = now() - interval '1 hour', finishes_at = now() - interval '30 minutes'
     where id = v_queue;
    v_level := public.complete_building(v_queue);
    select fields_total into v_f1 from public.planets where id = v_moon;

    v_ok := v_level = 0 and v_f1 = public.calculate_moon_field_capacity(0) and v_f1 < v_f0;
    insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8b. lunar_base 0 re-syncs the moon fields (%s -> %s)', v_f0, v_f1));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 9. an active unit order blocks the downgrade of the building it requires */
    delete from public.building_queue where planet_id = v_planet;
    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'shipyard', 4)
    on conflict (planet_id, building_id) do update set level = 4;
    insert into public.shipyard_queue(planet_id, ship_id, quantity, started_at, finishes_at, status)
    values (v_planet, 'crawler', 1, now(), now() + interval '1 hour', 'BUILDING');

    select * into v_inspect from public.can_start_demolition(v_player, v_planet, 'shipyard');
    v_ok := not v_inspect.allowed and v_inspect.reason = 'DEMOLITION_BLOCKED_BY_ACTIVE_UNIT_QUEUE'
            and not v_inspect.unit_queue_idle;
    insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9a. a crawler order keeps shipyard 4 alive (%s)', v_inspect.reason));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    update public.shipyard_queue set status = 'COMPLETED' where planet_id = v_planet;
    select * into v_inspect from public.can_start_demolition(v_player, v_planet, 'shipyard');
    v_ok := v_inspect.allowed and v_inspect.target_level = 3;
    insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '9b. once the order ends the shipyard can be downgraded to 3');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 10. an active research blocks the downgrade of the building it requires */
    delete from public.building_queue where planet_id = v_planet;
    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'solar_plant', 1)
    on conflict (planet_id, building_id) do update set level = 1;
    insert into public.research_building_prerequisites(research_id, building_id, required_level)
    values ('energy_technology', 'solar_plant', 1)
    on conflict do nothing;
    insert into public.research_queue(planet_id, player_id, research_id, target_level, started_at, finishes_at, status)
    values (v_planet, v_player, 'energy_technology', 1, now(), now() + interval '1 hour', 'RESEARCHING');

    select * into v_inspect from public.can_start_demolition(v_player, v_planet, 'solar_plant');
    v_ok := not v_inspect.allowed and v_inspect.reason = 'DEMOLITION_BLOCKED_BY_ACTIVE_RESEARCH'
            and not v_inspect.research_idle;
    insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10a. an active research keeps solar_plant 1 alive (%s)', v_inspect.reason));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    update public.research_queue set status = 'CANCELLED' where player_id = v_player;
    select * into v_inspect from public.can_start_demolition(v_player, v_planet, 'solar_plant');
    v_ok := v_inspect.allowed and v_inspect.target_level = 0;
    insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10b. without the active research the demolition is legal again');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 11. conflict codes, ownership and atomicity */
    insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status)
    values (v_planet, 'metal_storage', 1, now(), now() + interval '1 hour', 'BUILDING');

    select * into v_inspect from public.can_start_demolition(v_player, v_planet, 'metal_mine');
    v_ok := not v_inspect.allowed and v_inspect.reason = 'BUILDING_QUEUE_ALREADY_ACTIVE' and not v_inspect.queue_available;
    insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11a. a busy building queue refuses the demolition (%s)', v_inspect.reason));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    delete from public.building_queue where planet_id = v_planet;
    update public.planet_resources set metal = 0, crystal = 0, deuterium = 0, last_calculated_at = now()
     where planet_id = v_planet;

    select * into v_inspect from public.can_start_demolition(v_player, v_planet, 'metal_mine');
    v_raised := null;
    begin
        perform public.start_demolition(v_player, v_planet, 'metal_mine');
    exception when others then
        v_raised := sqlerrm;
    end;

    v_ok := not v_inspect.allowed and v_inspect.reason = 'INSUFFICIENT_RESOURCES'
            and v_raised = 'INSUFFICIENT_RESOURCES'
            and (select count(*) from public.building_queue where planet_id = v_planet) = 0;
    insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11b. insufficient resources raise %s and leave no queue residue', v_raised));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select * into v_inspect from public.can_start_demolition(gen_random_uuid(), v_planet, 'metal_mine');
    v_raised := null;
    begin
        perform public.start_demolition(v_player, gen_random_uuid(), 'metal_mine');
    exception when others then
        v_raised := sqlerrm;
    end;

    v_ok := v_inspect.reason = 'PLAYER_NOT_OWNED_BY_AUTH_USER' and v_raised = 'PLANET_NOT_FOUND_OR_NOT_OWNED';
    insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11c. ownership: %s / %s', v_inspect.reason, v_raised));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 12. cancel refunds the charge exactly, and the certified upgrade path is untouched */
    update public.planet_resources set metal = 30000, crystal = 30000, deuterium = 30000,
           last_calculated_at = now() where planet_id = v_planet;
    delete from public.building_queue where planet_id = v_planet;
    delete from public.player_research where player_id = v_player and research_id = 'ion_technology';

    select metal into v_m0 from public.planet_resources where planet_id = v_planet;
    v_queue := public.start_demolition(v_player, v_planet, 'metal_mine');
    select metal into v_m1 from public.planet_resources where planet_id = v_planet;
    v_charge := v_m0 - v_m1;
    select refund_metal into v_expected from public.cancel_building(v_queue);

    v_ok := abs(v_expected - v_charge) < 1
            and exists (select 1 from public.building_queue where id = v_queue and upper(status) = 'CANCELLED');
    insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('12a. cancelling a demolition refunds the charge (%s vs %s)', v_expected, v_charge));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'metal_storage', 1)
    on conflict (planet_id, building_id) do update set level = 1;
    select fields_used into v_f0 from public.planets where id = v_planet;

    v_queue := public.start_building(v_player, v_planet, 'metal_storage');
    update public.planet_resources set last_calculated_at = now() - interval '1 hour' where planet_id = v_planet;
    update public.building_queue
       set started_at = now() - interval '1 hour', finishes_at = now() - interval '30 minutes'
     where id = v_queue;
    v_level := public.complete_building(v_queue);
    select fields_used into v_f1 from public.planets where id = v_planet;

    v_ok := v_level = 2 and v_f1 = v_f0 + 1
            and (select not is_downgrade from public.building_queue where id = v_queue)
            and (select level from public.planet_buildings where planet_id = v_planet and building_id = 'metal_storage') = 2;
    insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('12b. the certified upgrade path still builds and consumes a field (%s -> %s)', v_f0, v_f1));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 13. the service-actor contract also covers the demolition contract */
    select pl.id into v_ai
      from public.players pl
     where pl.player_type = 'AI' and pl.user_id is null
       and exists (select 1 from public.universes u where u.id = pl.universe_id and u.is_active)
       and exists (select 1 from public.planets p where p.player_id = pl.id and p.kind = 'PLANET' and not p.is_destroyed)
     limit 1;

    if v_ai is null then
        insert into t_bd(resultado, prueba) values ('INFO',
          '13. no AI player in this snapshot: the service-actor branch stays covered by ai_service_actor.sql');
    else
        select p.id into v_ai_planet from public.planets p
         where p.player_id = v_ai and p.kind = 'PLANET' and not p.is_destroyed order by p.created_at limit 1;

        perform set_config('request.jwt.claims', '{}', true);
        perform public.ai_actor_begin(v_ai);
        select * into v_inspect from public.can_start_demolition(v_ai, v_ai_planet, 'metal_mine');
        v_ok := v_inspect.reason not in ('AUTHENTICATION_REQUIRED', 'PLAYER_NOT_OWNED_BY_AUTH_USER');
        perform public.ai_actor_end();
        select * into v_inspect from public.can_start_demolition(v_ai, v_ai_planet, 'metal_mine');
        v_ok := v_ok and v_inspect.reason = 'AUTHENTICATION_REQUIRED';

        insert into t_bd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
          format('13. AI service actor accepted during ai_actor_begin, refused after end (%s)', v_inspect.reason));
        v_fail := v_fail + case when v_ok then 0 else 1 end;
    end if;

    insert into t_bd(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; concurrency is not executed. Cost/time formulas, ion factor, dependents and the level-0 rule follow OGameX (see migration header).');

    if v_fail > 0 then
        raise exception 'BUILDING DEMOLITION FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_bd order by orden;

drop table if exists t_bd;

ROLLBACK;

