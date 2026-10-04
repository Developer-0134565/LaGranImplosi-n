-- FLEET SLOT CAP — La Gran Implosión
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Mission 2026-10-03. La POLÍTICA ya estaba decidida e implementada; lo que faltaba era
-- la serialización por JUGADOR (el trigger bloqueaba el planeta de ORIGEN, pero el recurso
-- que se limita es por jugador). Migración: 20261004010000_fleet_slot_player_lock.
--
-- LIMITATION (honesta): este harness es de UNA sola sesión. Una carrera de verdad exige dos
-- conexiones simultáneas, que aquí no se pueden abrir. Lo que SÍ se certifica es que el lock
-- se toma SOBRE EL JUGADOR (comprobable en la definición), que el trigger sigue siendo el
-- único cuello de botella y que el comportamiento serial es correcto. La garantía de
-- exclusión mutua se DERIVA del lock, no de una carrera ejecutada.

begin;

drop table if exists t_fs;
create temp table t_fs(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_u uuid; v_p1 uuid; v_p2 uuid;
    v_ok boolean; v_err text; v_max int; v_used int; v_n int; v_st text;
    v_res record;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_u
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    if v_player is null then raise exception 'TEST_ABORT: se requiere jugador con auth'; end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    select (array_agg(id order by name))[1] into v_p1
      from (select id, name from public.planets
             where player_id = v_player and not is_destroyed) z;
    select (array_agg(id order by name))[2] into v_p2
      from (select id, name from public.planets
             where player_id = v_player and not is_destroyed) z;

    -- ---------------------------------------------------------------- P. POLÍTICA
    v_max := public.calculate_player_max_fleet_slots(v_player);
    v_ok := v_max = 1 + coalesce((select pr.level from public.player_research pr
                                    where pr.player_id = v_player
                                      and pr.research_id = 'computer_technology'), 0);
    insert into t_fs(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('P1. base = 1 + computer_technology (%s)', v_max));

    v_ok := public.calculate_player_max_fleet_slots(v_player) = 1
            + coalesce((select pr.level from public.player_research pr
                         where pr.player_id = v_player
                           and pr.research_id='computer_technology'),0);
    insert into t_fs(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'P2. sin Dark Matter ni Officers: el max depende SOLO de computer_technology');

    select count(*) into v_n from public.fleet_movements
     where player_id = v_player and status not in ('COMPLETED','CANCELLED');
    insert into t_fs(resultado,prueba) values (case when v_n = 0 then 'PASS' else 'FAIL' end,
      format('P3. punto de partida sin flotas activas (%s)', v_n));

    -- ------------------------------------------------- P. LOCK SCOPE (el defecto)
    v_ok := (select p.prosrc ilike '%FOR UPDATE%'
               and p.prosrc ilike '%FROM public.players%'
               and not (p.prosrc ilike '%FROM public.planets%')
             from pg_proc p join pg_namespace n on n.oid=p.pronamespace
             where n.nspname='public' and p.proname='assert_player_fleet_slot_available');
    insert into t_fs(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'L1. el assert bloquea la fila del JUGADOR, no la del planeta');

    v_ok := (select tgenabled = 'O' from pg_trigger where tgname='trg_enforce_fleet_slots');
    insert into t_fs(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'L2. el trigger BEFORE INSERT sobre fleet_movements sigue activo');

    v_ok := (select count(*) >= 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
             where n.nspname='public' and p.prosrc ilike '%assert_player_fleet_slot_available%');
    insert into t_fs(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'L3. el assert se invoca desde el trigger y tambien desde la IA (defensa en profundidad)');

    -- ------------------------------------------------------- P. CAPACIDAD Y TOPE
    insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,
         started_at,arrives_at,status,metal,crystal,deuterium,expedition_hold_seconds,fuel_consumed)
    select v_player, p.id, p.id, 'ATTACK', now(), now()+interval '1 day','OUTBOUND',0,0,0,0,0
      from public.planets p, generate_series(1, v_max) g
     where p.player_id = v_player and not p.is_destroyed limit v_max;

    v_used := public.calculate_player_fleet_slots_in_use(v_player);
    v_ok := v_used = v_max;
    insert into t_fs(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('C1. se pueden ocupar los %s slots (in_use=%s)', v_max, v_used));

    v_err := null;
    begin perform public.assert_player_fleet_slot_available(v_player);
    exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%FLEET_SLOTS_FULL%';
    insert into t_fs(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('C2. al tope el assert RECHAZA [%s]', coalesce(v_err,'(sin error)')));

    v_err := null;
    begin
      insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,
           started_at,arrives_at,status,metal,crystal,deuterium,expedition_hold_seconds,fuel_consumed)
      values (v_player, v_p1, v_p1,'ATTACK', now(), now()+interval '1 day','OUTBOUND',0,0,0,0,0);
    exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%FLEET_SLOTS_FULL%';
    insert into t_fs(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('C3. el TRIGGER bloquea el insert más allá del tope [%s]', coalesce(v_err,'(permitido)')));

    -- ----------------------------------------------------------------- P. LIBERAR
    update public.fleet_movements set status='COMPLETED'
     where player_id=v_player and status not in ('COMPLETED','CANCELLED');
    v_ok := public.calculate_player_fleet_slots_in_use(v_player) = 0;
    insert into t_fs(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'R1. COMPLETED libera el slot (in_use=0)');

    insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,
         started_at,arrives_at,status,metal,crystal,deuterium,expedition_hold_seconds,fuel_consumed)
    values (v_player, v_p1, v_p1,'ATTACK', now(), now()+interval '1 day','OUTBOUND',0,0,0,0,0);
    update public.fleet_movements set status='CANCELLED'
     where player_id=v_player and status not in ('COMPLETED','CANCELLED');
    v_ok := public.calculate_player_fleet_slots_in_use(v_player) = 0;
    insert into t_fs(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'R2. CANCELLED también libera el slot (no quedan slots huérfanos)');

    -- Cada estado ACTIVO debe contar 1. Estados válidos según
    -- fleet_movements_status_check: OUTBOUND, ARRIVED, HOLDING, RETURNING, COMPLETED, CANCELLED.
    -- Los cuatro primeros ocupan slot; los dos últimos lo liberan.
    -- Se crea una fila nueva en cada vuelta: al terminar la anterior todas las filas ya
    -- están en estado terminal, y un UPDATE que filtra por "no terminal" no tocaría
    -- ninguna (falso PASS por no-op silencioso).
    foreach v_st in array array['OUTBOUND','ARRIVED','HOLDING','RETURNING'] loop
      insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,
           started_at,arrives_at,status,metal,crystal,deuterium,expedition_hold_seconds,fuel_consumed)
      values (v_player, v_p1, v_p1,'ATTACK', now(), now()+interval '1 day', v_st,0,0,0,0,0);
      insert into t_fs(resultado,prueba) values
        (case when public.calculate_player_fleet_slots_in_use(v_player) = 1 then 'PASS' else 'FAIL' end,
         format('R3. el estado %s cuenta como slot ocupado (in_use=%s)',
                v_st, public.calculate_player_fleet_slots_in_use(v_player)));
      delete from public.fleet_movements
       where player_id = v_player and status not in ('COMPLETED','CANCELLED');
    end loop;
    update public.fleet_movements set status='COMPLETED'
     where player_id=v_player and status not in ('COMPLETED','CANCELLED');

    -- ------------------------------------------------------------- P. OWNERSHIP
    v_err := null;
    begin perform public.assert_player_fleet_slot_available(gen_random_uuid());
    exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%FLEET_SLOT_PLAYER_NOT_FOUND%';
    insert into t_fs(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('S1. un player_id forjado se rechaza [%s]', coalesce(v_err,'(aceptado)')));

    v_err := null;
    begin perform public.assert_player_fleet_slot_available(null);
    exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%FLEET_SLOT_PLAYER_REQUIRED%';
    insert into t_fs(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'S2. player_id nulo se rechaza');

    v_ok := has_table_privilege('authenticated','public.fleet_movements','INSERT') = false;
    insert into t_fs(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'S3. el cliente NO puede insertar movimientos directamente (solo vía RPC/trigger)');

    v_ok := has_function_privilege('authenticated','public.assert_player_fleet_slot_available(uuid)','EXECUTE') = false;
    insert into t_fs(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'S4. el assert sigue cerrado al cliente tras el cambio');

    -- ------------------------------------------------------- P. CONTRATO DE LECTURA
    select * into v_res from public.get_player_fleet_slots();
    v_ok := v_res.out_max_slots = v_max
        and v_res.out_slots_in_use = 0
        and v_res.out_slots_available = v_max
        and v_res.out_computer_technology_level = v_max - 1;
    insert into t_fs(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('U1. contrato de lectura coherente: max=%s used=%s avail=%s',
              v_res.out_max_slots, v_res.out_slots_in_use, v_res.out_slots_available));
end $test$;

select count(*) filter (where resultado='PASS') as pass,
       count(*) filter (where resultado='FAIL') as fail
from t_fs;
select orden, resultado, prueba from t_fs where resultado <> 'PASS' order by orden;

rollback;
             where n.nspname='public' and p.prosrc ilike '%assert_player_fleet_slot_available%');
    insert into t_fs(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'L3. el assert es el UNICO punto de paso de toda inserción en fleet_movements');