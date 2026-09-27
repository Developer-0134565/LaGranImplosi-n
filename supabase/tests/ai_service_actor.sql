-- ACTIVE AI SERVICE-ACTOR FIXTURE — LA GRAN IMPLOSIÓN
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
-- Contract (20260926150000 / 20260926150100): an AI player can act through the SAME authoritative dispatchers when a
-- service context declares it explicitly; a human session, an anonymous caller, an undeclared service call and a
-- different-player declaration all keep failing. LIMITATION: single-session harness.

begin;

drop table if exists t_ai;
create temp table t_ai(orden serial, resultado text, prueba text);

do $test$
declare
    v_human uuid; v_human_planet uuid; v_human_auth uuid; v_universe uuid;
    v_ai uuid; v_ai_planet uuid; v_ai2 uuid; v_ai2_planet uuid;
    v_ok boolean; v_fail integer := 0; v_raised text; v_rows integer;
    v_metal_before numeric; v_metal_after numeric;
begin
    select pl.id, pl.user_id, pl.universe_id into v_human, v_human_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_human_planet
      from public.planets p where p.player_id = v_human and not p.is_destroyed and p.kind = 'PLANET'
      order by p.created_at limit 1;

    select pl.id, p.id into v_ai, v_ai_planet
      from public.players pl
      join public.planets p on p.player_id = pl.id and not p.is_destroyed and p.kind = 'PLANET'
     where pl.player_type = 'AI' and pl.user_id is null and pl.universe_id = v_universe
     order by p.created_at limit 1;

    select pl.id, p.id into v_ai2, v_ai2_planet
      from public.players pl
      join public.planets p on p.player_id = pl.id and not p.is_destroyed and p.kind = 'PLANET'
     where pl.player_type = 'AI' and pl.user_id is null and pl.universe_id = v_universe and pl.id <> v_ai
     order by p.created_at limit 1;

    if v_human is null or v_ai is null or v_ai2 is null then
        raise exception 'TEST_ABORT: a human player and two AI players of the active universe are required';
    end if;

    /* neutralise fleet-slot and ownership noise for the AI players */
    insert into public.player_research(player_id, research_id, level)
    select x.id, 'computer_technology', 60 from (values (v_ai), (v_ai2)) as x(id)
    on conflict (player_id, research_id) do update set level = 60;

    update public.fleet_movements set status = 'COMPLETED'
     where player_id in (v_ai, v_ai2) and status not in ('COMPLETED', 'CANCELLED');

    delete from public.building_queue where planet_id in (v_ai_planet, v_ai2_planet);
    update public.planet_resources set metal = 1000000, crystal = 1000000, deuterium = 1000000,
           last_calculated_at = now() where planet_id in (v_ai_planet, v_ai2_planet);

    /* 1. the AI context must be declared explicitly */
    v_raised := null;
    begin
        perform public.start_building(v_ai, v_ai_planet, 'metal_mine');
    exception when others then
        v_raised := sqlerrm;
    end;

    v_ok := v_raised like '%Authentication required%';
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. an undeclared service call for an AI player is refused (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 2. only AI players can be declared */
    v_raised := null;
    begin
        perform public.ai_actor_begin(v_human);
    exception when others then
        v_raised := sqlerrm;
    end;

    v_ok := v_raised like 'AI_ACTOR_TARGET_NOT_AI%';
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. a human player cannot be declared as an AI actor (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 3. declared AI actor: the authoritative dispatcher runs for real */
    perform public.ai_actor_begin(v_ai);

    select pr.metal into v_metal_before from public.planet_resources pr where pr.planet_id = v_ai_planet;

    perform public.start_building(v_ai, v_ai_planet, 'metal_mine');

    select pr.metal into v_metal_after from public.planet_resources pr where pr.planet_id = v_ai_planet;
    select count(*)::integer into v_rows from public.building_queue q
     where q.planet_id = v_ai_planet and q.building_id = 'metal_mine';

    v_ok := v_rows = 1 and v_metal_after < v_metal_before;
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. the declared AI actor built through start_building (%s queue row, metal %s -> %s)',
             v_rows, v_metal_before, v_metal_after));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 4. the declaration is bound to one player */
    v_raised := null;
    begin
        perform public.start_building(v_ai2, v_ai2_planet, 'metal_mine');
    exception when others then
        v_raised := sqlerrm;
    end;

    v_ok := v_raised like '%Authentication required%';
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. the declared actor cannot act for another AI player (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 5. the AI context also satisfies the write-access trigger for fleet movements */
    v_raised := null;
    begin
        insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at, status,
            destination_galaxy, destination_system, destination_position)
        select v_ai, v_ai_planet, 'TRANSPORT', clock_timestamp(), clock_timestamp() + interval '1 hour', 'OUTBOUND',
               p.galaxy, p.system, p.position
          from public.planets p where p.id = v_ai_planet;
    exception when others then
        v_raised := sqlerrm;
    end;

    v_ok := v_raised is null;
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. the write-access trigger accepts a declared AI actor for fleet_movements (%s)',
             coalesce(v_raised, 'accepted')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 6. ending the context closes the door again */
    perform public.ai_actor_end();

    v_raised := null;
    begin
        insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at, status)
        values (v_ai, v_ai_planet, 'TRANSPORT', clock_timestamp(), clock_timestamp() + interval '1 hour', 'OUTBOUND');
    exception when others then
        v_raised := sqlerrm;
    end;

    v_ok := v_raised like 'AUTHENTICATION_REQUIRED%' or v_raised like '%Authentication required%';
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. after ai_actor_end the same write is refused again (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 7. a human session can never act as an AI player */
    perform set_config('request.jwt.claims', json_build_object('sub', v_human_auth)::text, true);

    v_raised := null;
    begin
        perform public.start_building(v_ai, v_ai_planet, 'metal_mine');
    exception when others then
        v_raised := sqlerrm;
    end;

    v_ok := v_raised is not null and v_raised not like 'AI_ACTOR%';
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. an authenticated human cannot act for an AI player (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 8. ... and still plays normally for its own player (no regression) */
    v_raised := null;
    begin
        perform public.start_building(v_human, v_human_planet, 'metal_mine');
    exception when others then
        v_raised := sqlerrm;
    end;

    select count(*)::integer into v_rows from public.building_queue q
     where q.planet_id = v_human_planet and q.building_id = 'metal_mine';

    v_ok := v_raised is null or v_raised like '%PLANET_FIELDS_FULL%' or v_raised like '%BUILDING_QUEUE%'
            or v_raised like '%Insufficient%' or v_rows >= 1;
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. a human session keeps its normal authority (%s)', coalesce(v_raised, 'accepted')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    perform set_config('request.jwt.claims', '{}', true);

    /* 9. ACL: the AI contract is service-role only */
    v_ok := has_function_privilege('service_role', 'public.ai_actor_begin(uuid)', 'EXECUTE')
            and not has_function_privilege('authenticated', 'public.ai_actor_begin(uuid)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.ai_actor_begin(uuid)', 'EXECUTE')
            and not has_function_privilege('authenticated', 'public.is_ai_actor_target(uuid)', 'EXECUTE')
            and not has_function_privilege('authenticated', 'public.ai_actor_end()', 'EXECUTE');
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '9. ACL: ai_actor_begin/end and is_ai_actor_target are service-role only');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_ai(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; no concurrent AI worker runs. Active behaviour POLICY (which action an AI picks and when) is a product decision, not implemented here: only the execution contract is.');

    if v_fail > 0 then
        raise exception 'AI SERVICE ACTOR FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_ai order by orden;

drop table if exists t_ai;

ROLLBACK;

