-- ============================================================================
-- BUILDINGS LIFECYCLE TEST — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NO ES UNA MIGRACIÓN. Es un test manual transaccional: todo ocurre dentro de
-- una transacción que termina en ROLLBACK, por lo que NO modifica datos reales.
--
-- Cómo ejecutarlo: pegar el fichero completo en el SQL editor de Supabase y
-- ejecutarlo como un único script. Los resultados se muestran como NOTICE.
--
-- Cubre: coste autoritativo, recursos insuficientes, edificio inválido, inicio
-- de construcción, descuento de recursos, creación de cola, cola activa única,
-- procesado/completado, persistencia de nivel, DOBLE COMPLETADO (idempotencia y
-- protección N→N+2), guarda de nivel objetivo y producción tras subir nivel.
-- ============================================================================

begin;

do $test$
declare
    v_player uuid;
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

    /* Planeta de prueba: planeta de invitado con menos niveles de edificios. */
    select p.player_id, p.id into v_player, v_planet
    from public.planets p
    join public.players pl on pl.id = p.player_id
    where coalesce(pl.is_guest, false) = true
      and p.is_destroyed = false
    order by (select count(*) from public.planet_buildings pb where pb.planet_id = p.id), p.created_at
    limit 1;

    if v_planet is null then
        raise exception 'TEST_ABORT: no hay planeta de invitado disponible';
    end if;
    raise notice 'TEST planet=% player=% building=%', v_planet, v_player, v_building;

    /* Escenario base controlado (se revierte con el ROLLBACK final):
       recursos de sobra, solar alto (energía suficiente) y sin cola activa. */
    insert into public.planet_buildings(planet_id, building_id, level)
    values (v_planet, 'solar_plant', 20)
    on conflict (planet_id, building_id) do update set level = 20;
    insert into public.planet_buildings(planet_id, building_id, level)
    values (v_planet, v_building, 0)
    on conflict (planet_id, building_id) do update set level = 0;
    delete from public.building_queue where planet_id = v_planet;
    update public.planet_resources
       set metal = 500000, crystal = 500000, deuterium = 500000, last_calculated_at = now(), updated_at = now()
     where planet_id = v_planet;

    select coalesce(max(level), 0) into v_level
    from public.planet_buildings where planet_id = v_planet and building_id = v_building;
    v_target := v_level + 1;

    select * into v_cost from public.calculate_building_cost(v_building, v_target);

    /* 1) CONTRATO: can_start_building coincide con el coste autoritativo. */
    select (i.cost_metal = v_cost.metal and i.cost_crystal = v_cost.crystal
            and i.cost_deuterium = v_cost.deuterium and i.target_level = v_target)
      into v_ok
    from public.can_start_building(v_player, v_planet, v_building) i;
    insert into t_results(prueba, resultado) values
      ('1. can_start_building: coste y nivel objetivo coherentes',
       case when coalesce(v_ok, false) then 'PASS' else 'FAIL' end);

    /* 2) RECURSOS INSUFICIENTES: se rechaza la construcción. */
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

    /* 3) EDIFICIO INVALIDO: se rechaza. */
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

    /* 4) START + DESCUENTO + COLA (sin cola previa y con last_calculated_at = now()). */
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

    /* 5) COLA ACTIVA UNICA: un segundo inicio mientras hay cola activa se rechaza. */
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

    /* Producción ANTES de subir el nivel (nivel actual del edificio). */
    select metal_per_hour into v_prod_before from public.calculate_planet_production(v_planet);

    /* 6) PROCESADO + COMPLETADO + PERSISTENCIA DE NIVEL
       (se adelanta el finish dentro de la transacción para no esperar). */
    update public.building_queue set finishes_at = now() - interval '1 second' where id = v_queue;
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

    /* 7) DOBLE COMPLETADO: idempotente, no produce N -> N+2. */
    v_ok := (public.complete_building(v_queue) = v_target);
    select coalesce(max(level), 0) into v_level
      from public.planet_buildings where planet_id = v_planet and building_id = v_building;
    insert into t_results(prueba, resultado) values
      ('7a. doble completado -> devuelve el mismo nivel y no incrementa (protección N->N+2)',
       case when v_ok and v_level = v_target then 'PASS' else 'FAIL: nivel ' || v_level || ' (esperado ' || v_target || ')' end);

    /* 7b) GUARDA DE NIVEL OBJETIVO: una cola cuyo target != nivel+1 se rechaza. */
    insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status)
    values (v_planet, v_building, v_target + 2, now() - interval '1 minute', now() - interval '1 second', 'BUILDING')
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

    /* 8) PRODUCCION TRAS SUBIR NIVEL (motor autoritativo, con energía suficiente). */
    select metal_per_hour into v_prod_after from public.calculate_planet_production(v_planet);
    insert into t_results(prueba, resultado) values
      ('8. producción de metal tras el nivel nuevo (' || v_prod_before || ' -> ' || v_prod_after || ')',
       case when v_prod_after > v_prod_before then 'PASS' else 'FAIL' end);

    /* RESULTADOS */
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
