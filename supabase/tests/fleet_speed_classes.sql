-- ============================================================================
-- FLEET MISSION SPEED CLASS TEST — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NO ES UNA MIGRACIÓN. Test transaccional: todo ocurre dentro de una transacción
-- que termina en ROLLBACK (incluido el universo de prueba), por lo que NO modifica
-- datos reales.
--
-- Cubre (fleet sweep 2026-09-18):
--   · autoridad única de clase de misión (PEACEFUL / WAR / HOLDING)
--   · matriz de clases por misión, incluida HOLDING (ACS_HOLD/HOLDING/DEFEND),
--     aunque su dispatch NO esté implementado (estado documentado como OPEN)
--   · wiring del pipeline canónico en los 3 dispatch (clasificador + E^(1/3) + helper)
--   · ausencia de fórmulas de viaje paralelas
--   · routing único de tecnología (motores) y orden de combustible
--   · cluster legado sin consumidores vivos
--
-- Las comprobaciones estructurales analizan el código SIN comentarios (t_defs.code)
-- para no confundir documentación con implementación.
--
-- Ejecutable desde el SQL Editor o mediante execute_sql (MCP). No usa framework.
-- ============================================================================

begin;

do $test$
declare
    v_probe uuid;
    v_val numeric;
    v_msg text;
    v_n int;
    v_r record;
    v_rows int;
    v_fails text := '';
begin
    create temp table t_results(orden serial, prueba text, resultado text) on commit drop;

    /* Definiciones del esquema público con el código limpio (sin comentarios) */
    create temp table t_defs as
    select p.proname,
           regexp_replace(regexp_replace(pg_get_functiondef(p.oid), '/\*.*?\*/', '', 'g'), '--[^\n]*', '', 'g') as code
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.prokind = 'f';

    /* 1) AUTORIDAD ÚNICA: sólo el clasificador lee las tres columnas de clase */
    select count(*) into v_n
    from t_defs
    where proname <> 'calculate_mission_fleet_speed_multiplier'
      and code ~ '(peaceful_fleet_speed|war_fleet_speed|holding_fleet_speed)';
    insert into t_results(prueba, resultado) values
      ('1. autoridad única: funciones (≠ clasificador) que leen columnas de clase [' || v_n || ']',
       case when v_n = 0 then 'PASS' else 'FAIL: ' || v_n || ' lectura(s) fuera del clasificador' end);

    /* Universo de prueba (transaccional): cada clase con un valor distinto */
    insert into public.universes(name, is_active, fleet_speed, peaceful_fleet_speed, war_fleet_speed, holding_fleet_speed)
    values ('TEST - fleet class probe (transactional)', false, 7, 2, 3, 5)
    returning id into v_probe;

    /* 2) MATRIZ DE CLASES: misión -> columna de clase del universo */
    for v_r in
        select * from (values
            ('TRANSPORT', 2::numeric), ('DEPLOY', 2::numeric), ('COLONIZE', 2::numeric), ('EXPEDITION', 2::numeric),
            ('ATTACK', 3::numeric), ('ESPIONAGE', 3::numeric), ('RECYCLE', 3::numeric),
            ('ACS_HOLD', 5::numeric), ('HOLDING', 5::numeric), ('DEFEND', 5::numeric),
            ('MISION_INEXISTENTE', 7::numeric)
        ) as t(mission, expected)
    loop
        v_val := public.calculate_mission_fleet_speed_multiplier(v_probe, v_r.mission);
        insert into t_results(prueba, resultado) values
          ('2. clase de ' || rpad(v_r.mission, 20) || ' -> ' || v_val || ' (esperado ' || v_r.expected || ')',
           case when v_val = v_r.expected then 'PASS' else 'FAIL' end);
    end loop;

    /* 3) CLASE INVÁLIDA: valor <= 0 -> excepción explícita */
    update public.universes set peaceful_fleet_speed = 0 where id = v_probe;
    v_msg := '';
    begin
        perform public.calculate_mission_fleet_speed_multiplier(v_probe, 'TRANSPORT');
    exception when others then v_msg := sqlerrm; end;
    insert into t_results(prueba, resultado) values
      ('3. clase inválida (0) -> ' || coalesce(nullif(v_msg, ''), '(sin error)'),
       case when v_msg like 'Invalid fleet speed for mission%' then 'PASS' else 'FAIL' end);

    /* 4) WIRING: los 3 dispatch usan clasificador + helper canónico + E^(1/3) */
    select count(*) into v_n
    from t_defs
    where proname in ('start_fleet', 'start_fleet_mixed', 'start_colonize_fleet')
      and code ~ 'calculate_mission_fleet_speed_multiplier'
      and code ~ 'calculate_fleet_travel_time'
      and code ~ 'power\(.*1\.0/3\.0';
    insert into t_results(prueba, resultado) values
      ('4. pipeline canónico en los 3 dispatch [' || v_n || '/3] (clasificador + E^(1/3) + helper de tiempo)',
       case when v_n = 3 then 'PASS' else 'FAIL: ' || v_n || ' de 3' end);

    /* 5) SIN FÓRMULAS PARALELAS: sólo el helper canónico y el de combustible usan 35000 */
    select count(*) into v_n from t_defs where code ~ '35000';
    insert into t_results(prueba, resultado) values
      ('5. fórmulas de viaje paralelas: funciones con 35000 [' || v_n || '] (esperado 2: tiempo + combustible)',
       case when v_n = 2 then 'PASS' else 'FAIL: ' || v_n end);

    /* 6) HOLD DE EXPEDICIÓN: resuelve la clase canónica y no lee la columna legada.
          Patrones que sólo existían en la versión antigua:
            SELECT u.fleet_speed ...  /  fleet_speed INTO v_fleet_speed  */
    select count(*) into v_n
    from t_defs
    where proname = 'calculate_expedition_delay_seconds'
      and code ~ 'calculate_mission_fleet_speed_multiplier'
      and code !~ 'u\.fleet_speed'
      and code !~ 'fleet_speed\s+INTO';
    insert into t_results(prueba, resultado) values
      ('6. hold/retraso de expedición resuelve la clase (sin universes.fleet_speed) [' || v_n || ']',
       case when v_n = 1 then 'PASS' else 'FAIL: ' || v_n end);

    /* 7) TECNOLOGÍA: sólo 2 funciones conocen los motores (velocidad de nave + consumo) */
    select count(*) into v_n
    from t_defs
    where code ~ 'combustion_drive' or code ~ 'impulse_drive' or code ~ 'hyperspace_drive';
    insert into t_results(prueba, resultado) values
      ('7. routing de tecnología: funciones que leen los 3 motores [' || v_n || '] (esperado 2)',
       case when v_n = 2 then 'PASS' else 'FAIL: ' || v_n end);
    select count(*) into v_n
    from t_defs
    where proname in ('calculate_player_ship_speed', 'calculate_player_ship_fuel_consumption')
      and (code ~ 'combustion_drive' or code ~ 'impulse_drive' or code ~ 'hyperspace_drive');
    insert into t_results(prueba, resultado) values
      ('7b. las 2 son velocidad de nave + consumo de nave [' || v_n || '/2]',
       case when v_n = 2 then 'PASS' else 'FAIL: ' || v_n end);

    /* 8) COMBUSTIBLE: base -> distancia/tiempo -> motor -> lifeform -> final.
          El helper de combustible usa el efecto lifeform y NO usa hyperspace como
          reducción genérica; el porcentaje aparece una sola vez (sin doble aplicación). */
    select count(*) into v_n
    from t_defs
    where proname = 'calculate_player_fleet_fuel_for_distance'
      and code ~ 'get_player_lifeform_effect'
      and code ~ 'fuel_reduction_percent'
      and code !~* 'hyperspace'
      and (length(code) - length(replace(code, 'fuel_reduction_percent', ''))) = length('fuel_reduction_percent');
    insert into t_results(prueba, resultado) values
      ('8. combustible: fuel_reduction_percent (lifeform) aplicado UNA vez y sin hyperspace [' || v_n || ']',
       case when v_n = 1 then 'PASS' else 'FAIL: ' || v_n end);

    /* 9) LEGADO SIN CONSUMIDORES VIVOS: nadie llama al cluster antiguo */
    select count(*) into v_n
    from t_defs
    where proname not in ('calculate_expedition_time', 'calculate_fleet_time', 'calculate_fleet_fuel',
                          'calculate_fleet_fuel_mixed', 'calculate_fleet_fuel_for_distance')
      and (code ~ 'calculate_expedition_time\('
        or code ~ 'calculate_fleet_time\('
        or code ~ 'calculate_fleet_fuel\('
        or code ~ 'calculate_fleet_fuel_mixed\('
        or code ~ 'calculate_fleet_fuel_for_distance\(');
    insert into t_results(prueba, resultado) values
      ('9. cluster legado sin consumidores vivos [' || v_n || '] (esperado 0)',
       case when v_n = 0 then 'PASS' else 'FAIL: ' || v_n || ' consumidor(es)' end);

    /* 10) HOLDING: preparado (clase + columna) pero NO despachable.
           Estado documentado OPEN: fleet_movements sólo admite 7 misiones (sin ACS_HOLD/HOLDING/DEFEND). */
    select count(*) into v_n
    from pg_constraint con join pg_class c on c.oid = con.conrelid join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and c.relname = 'fleet_movements' and con.conname = 'fleet_movements_mission_type_chk'
      and pg_get_constraintdef(con.oid) !~ '(ACS_HOLD|HOLDING|DEFEND)';
    insert into t_results(prueba, resultado) values
      ('10. ACS_HOLD/HOLDING/DEFEND NO despachables (CHECK de 7 misiones) [' || v_n || ']',
       case when v_n = 1 then 'PASS (estado OPEN documentado)' else 'FAIL: ' || v_n end);

    select count(*) into v_n
    from information_schema.columns
    where table_schema = 'public' and table_name = 'universes'
      and column_name = 'holding_fleet_speed' and is_nullable = 'NO';
    insert into t_results(prueba, resultado) values
      ('10b. universes.holding_fleet_speed existe y es NOT NULL [' || v_n || ']',
       case when v_n = 1 then 'PASS' else 'FAIL: ' || v_n end);

    /* ---------------------------------------------------------------- RESULTADOS */
    raise notice '----- FLEET SPEED CLASS TEST -----';
    for v_r in select orden, prueba, resultado from t_results order by orden loop
        raise notice '%  %  ->  %', rpad(v_r.orden::text, 3), v_r.resultado, v_r.prueba;
    end loop;

    select count(*), coalesce(string_agg('[' || orden || '] ' || resultado || ' :: ' || prueba, ' | ' order by orden), '')
      into v_rows, v_fails
      from t_results
     where resultado not like 'PASS%';

    if v_rows > 0 then
        raise exception 'FLEET SPEED CLASS TEST FAILED: % prueba(s) con FAIL -> %', v_rows, v_fails;
    end if;
    raise notice 'FLEET SPEED CLASS TEST: ALL PASS (transacción revertida, sin cambios reales)';
end;
$test$;

select orden, resultado, prueba from t_results order by orden;

rollback;
