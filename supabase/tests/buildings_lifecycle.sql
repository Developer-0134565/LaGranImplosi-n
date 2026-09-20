-- ============================================================================
-- BUILDINGS LIFECYCLE TEST — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NO ES UNA MIGRACIÓN. Es un test manual transaccional: todo ocurre dentro de
-- una transacción que termina en ROLLBACK, por lo que NO modifica datos reales.
--
-- Identidad: el test fija `request.jwt.claims` para simular la sesión ANÓNIMA del
-- frontend (auth.uid() = players.user_id), el mismo contrato que aplica la migración
-- 20260918030000_harden_player_ownership_in_owned_rpcs.sql.
-- ============================================================================

begin;

do $test$
declare
    v_player uuid;
    v_user uuid;
    v_planet uuid;
    v_building text := 'metal_mine';
    v_level int;
    v_target int;
    v_cost record;
    v_queue uuid;
    v_status text;
    v_before_metal numeric;
    v_after_metal numeric;
    v_prod_before numeric;
    v_prod_after numeric;
    v_ok boolean;
begin
    create temp table t_results(orden serial, prueba text, resultado text) on commit drop;

    select p.player_id, p.id, pl.user_id into v_player, v_planet, v_user
    from public.planets p
    join public.players pl on pl.id = p.player_id
    where pl.player_type = 'HUMAN'
      and pl.user_id is not null
      and pl.username not like 'DevPlayer%'
      and p.is_destroyed = false
    order by (select count(*) from public.planet_buildings pb where pb.planet_id = p.id), p.created_at
    limit 1;

    if v_planet is null then
        raise exception 'TEST_ABORT: no hay un jugador HUMANO (email/password) con planeta propio; provisiona un imperio (provision_player) antes de ejecutar esta suite';
    end if;
    raise notice 'TEST planet=% player=% user=% building=%', v_planet, v_player, v_user, v_building;

    /* Identidad de sesión simulada (equivale a la sesión ANÓNIMA del frontend:
       auth.uid() = players.user_id). Sin esto, las RPC endurecidas rechazan la operación. */
    perform set_config('request.jwt.claims', json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

    insert into public.planet_buildings(planet_id, building_id, level)
    values (v_planet, 'solar_plant', 20)
    on conflict (planet_id, building_id) do update set level = 20;
    insert into public.planet_buildings(planet_id, building_id, level)
    values (v_planet, v_building, 0)
    on conflict (planet_id, building_id) do update set level = 0;
    delete from public.building_queue where planet_id = v_planet;
    update public.planet_resources
       set metal = 500000, crystal = 500000, deuterium = 500000,
           last_calculated_at = now(), updated_at = now()
     where planet_id = v_planet;

    select coalesce(max(level), 0) into v_level
    from public.planet_buildings where planet_id = v_planet and building_id = v_building;
    v_target := v_level + 1;

    select * into v_cost from public.calculate_building_cost(v_building, v_target);

    select (i.cost_metal = v_cost.metal and i.cost_crystal = v_cost.crystal
            and i.cost_deuterium = v_cost.deuterium and i.target_level = v_target)
      into v_ok
    from public.can_start_building(v_player, v_planet, v_building) i;
    insert into t_results(prueba, resultado) values
      ('1. can_start_building: coste y nivel objetivo coherentes',
       case when coalesce(v_ok, false) then 'PASS' else 'FAIL' end);

    update public.planet_resources set metal = 0, crystal = 0, deuterium = 0 where planet_id = v_planet;
    v_ok := false;
    begin
        perform public.start_building(v_player, v_planet, v_building);
    exception when others then
        v_ok := sqlerrm like 'INSUFFICIENT_RESOURCES%';
        if not v_ok then raise; end if;
    end;
    insert into t_results(prueba, resultado) values
      ('2. recursos insuficientes -> rechazado (INSUFFICIENT_RESOURCES)',
       case when v_ok then 'PASS' else 'FAIL' end);

    update public.planet_resources set metal = 500000, crystal = 500000, deuterium = 500000 where planet_id = v_planet;
    v_ok := false;
    begin
        perform public.start_building(v_player, v_planet, 'no_such_building');
    exception when others then
        v_ok := sqlerrm like 'BUILDING_NOT_FOUND%';
        if not v_ok then raise; end if;
    end;
    insert into t_results(prueba, resultado) values
      ('3. edificio invalido -> rechazado (BUILDING_NOT_FOUND)',
       case when v_ok then 'PASS' else 'FAIL' end);

    /* Sincronizamos recursos antes de medir el descuento: start_building también
       liquida el tick pendiente, por lo que medir antes introduciría producción
       histórica en la diferencia del coste. */
    perform * from public.process_planet_tick(v_planet);
    select metal into v_before_metal from public.planet_resources where planet_id = v_planet;
    v_queue := public.start_building(v_player, v_planet, v_building);
    select metal into v_after_metal from public.planet_resources where planet_id = v_planet;
    insert into t_results(prueba, resultado) values
      ('4a. start_building devuelve id de cola',
       case when v_queue is not null then 'PASS' else 'FAIL' end);
    insert into t_results(prueba, resultado) values
      ('4b. descuento exacto del coste (' || v_cost.metal || ' metal)',
       case when v_before_metal - v_after_metal = v_cost.metal then 'PASS' else 'FAIL: ' || (v_before_metal - v_after_metal) end);
    select status, target_level into v_status, v_target from public.building_queue where id = v_queue;
    insert into t_results(prueba, resultado) values
      ('4c. cola creada en BUILDING con nivel objetivo correcto',
       case when upper(v_status) = 'BUILDING' and v_target = v_level + 1 then 'PASS' else 'FAIL' end);

    v_ok := false;
    begin
        perform public.start_building(v_player, v_planet, 'crystal_mine');
    exception when others then
        v_ok := sqlerrm like 'BUILDING_QUEUE_ALREADY_ACTIVE%';
        if not v_ok then raise; end if;
    end;
    insert into t_results(prueba, resultado) values
      ('5. segundo start con cola activa -> rechazado (BUILDING_QUEUE_ALREADY_ACTIVE)',
       case when v_ok then 'PASS' else 'FAIL' end);

    select metal_per_hour into v_prod_before from public.calculate_planet_production(v_planet);

    /* Adelantamos la cola de forma válida respecto al CHECK finishes_at > started_at. */
    update public.building_queue
       set started_at = now() - interval '1 second',
           finishes_at = now()
     where id = v_queue;
    perform * from public.process_building_queue_for_planet(v_planet);
    select status into v_status from public.building_queue where id = v_queue;
    select coalesce(max(level), 0) into v_level
      from public.planet_buildings where planet_id = v_planet and building_id = v_building;
    insert into t_results(prueba, resultado) values
      ('6a. cola procesada -> status COMPLETED',
       case when upper(v_status) = 'COMPLETED' then 'PASS' else 'FAIL' end);
    insert into t_results(prueba, resultado) values
      ('6b. nivel persistido en planet_buildings = nivel objetivo',
       case when v_level = v_target then 'PASS' else 'FAIL: nivel ' || v_level || ' (esperado ' || v_target || ')' end);

    v_ok := (public.complete_building(v_queue) = v_target);
    select coalesce(max(level), 0) into v_level
      from public.planet_buildings where planet_id = v_planet and building_id = v_building;
    insert into t_results(prueba, resultado) values
      ('7a. doble completado -> devuelve el mismo nivel y no incrementa (protección N->N+2)',
       case when v_ok and v_level = v_target then 'PASS' else 'FAIL: nivel ' || v_level || ' (esperado ' || v_target || ')' end);

    insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status)
    values (v_planet, v_building, v_target + 2, now() - interval '1 minute', now(), 'BUILDING')
    returning id into v_queue;
    v_ok := false;
    begin
        perform public.complete_building(v_queue);
    exception when others then
        v_ok := sqlerrm like 'BUILDING_LEVEL_MISMATCH%';
        if not v_ok then raise; end if;
    end;
    insert into t_results(prueba, resultado) values
      ('7b. cola con nivel objetivo inconsistente -> rechazada (BUILDING_LEVEL_MISMATCH)',
       case when v_ok then 'PASS' else 'FAIL' end);

    select metal_per_hour into v_prod_after from public.calculate_planet_production(v_planet);
    insert into t_results(prueba, resultado) values
      ('8. producción de metal tras el nivel nuevo (' || v_prod_before || ' -> ' || v_prod_after || ')',
       case when v_prod_after > v_prod_before then 'PASS' else 'FAIL' end);

    /* 9) OWNERSHIP: una sesión que NO es dueña del player debe ser rechazada
       (no basta con conocer el UUID del jugador). */
    perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
    v_ok := false;
    begin
        perform public.start_building(v_player, v_planet, v_building);
    exception when others then
        v_ok := sqlerrm like 'Player does not belong to authenticated user%';
        if not v_ok then raise; end if;
    end;
    insert into t_results(prueba, resultado) values
      ('9. sesión ajena no puede operar sobre el player (ownership)',
       case when v_ok then 'PASS' else 'FAIL' end);
    perform set_config('request.jwt.claims', json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

    raise notice '----- BUILDINGS LIFECYCLE TEST -----';
    for v_status, v_building in
        select resultado, prueba from t_results order by orden
    loop
        raise notice '%  %', v_status, v_building;
    end loop;

    select count(*) into v_level from t_results where resultado <> 'PASS';
    if v_level > 0 then
        raise exception 'BUILDINGS TEST FAILED: % prueba(s) con FAIL', v_level;
    end if;
    raise notice 'BUILDINGS LIFECYCLE TEST: ALL PASS (transacción revertida, sin cambios reales)';
end;
$test$;

rollback;
