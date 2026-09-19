-- ============================================================================
-- SHIPYARD + DEFENCE LIFECYCLE TEST — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NO ES UNA MIGRACIÓN. Test manual transaccional: todo ocurre dentro de una
-- transacción que termina en ROLLBACK, por lo que NO modifica datos reales.
--
-- Cubre: authoritative can_build_* contract, start + exact resource deduction,
-- queue creation, processing, inventory persistence, second-pass no-op,
-- NULL-auth rejection and foreign-owner rejection for both entrypoints.
-- Identity: request.jwt.claims simulates the authenticated frontend session.
-- ============================================================================

begin;

do $test$
declare
  v_player uuid := '60f1043a-2fa6-416c-80db-2a83215b5404';
  v_user uuid := '100f3895-c83b-4bc5-b7b9-5c7268d1aa20';
  v_planet uuid := 'c0d77158-78ca-4631-98f2-b01d571d627c';
  v_ship text := 'solar_satellite';
  v_defense text := 'rocket_launcher';
  v_ship_contract record;
  v_defense_contract record;
  v_result record;
  v_ship_queue uuid;
  v_defense_queue uuid;
  v_status text;
  v_before_m numeric;
  v_after_m numeric;
  v_before_c numeric;
  v_after_c numeric;
  v_before_d numeric;
  v_after_d numeric;
  v_before_qty bigint;
  v_after_qty bigint;
  v_count int;
  v_ok boolean;
begin
  create temp table t_results(orden serial, prueba text, resultado text) on commit drop;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  delete from public.shipyard_queue where planet_id = v_planet;
  delete from public.defense_queue where planet_id = v_planet;

  update public.planet_resources
     set metal = 500000, crystal = 500000, deuterium = 500000,
         last_calculated_at = now(), updated_at = now()
   where planet_id = v_planet;

  select * into v_ship_contract
  from public.can_build_ship(v_player, v_planet, v_ship, 1);

  select * into v_defense_contract
  from public.can_build_defense(v_player, v_planet, v_defense, 1);

  insert into t_results(prueba, resultado) values
  ('1. can_build_ship: permitido + coste/tiempo autoritativos',
   case when v_ship_contract.allowed and v_ship_contract.reason='OK'
          and v_ship_contract.crystal_cost>0 and v_ship_contract.deuterium_cost>0
          and v_ship_contract.build_time_seconds>0 then 'PASS' else 'FAIL' end),
  ('2. can_build_defense: permitido + coste/tiempo autoritativos',
   case when v_defense_contract.allowed and v_defense_contract.reason='OK'
          and v_defense_contract.metal_cost>0 and v_defense_contract.build_time_seconds>0
        then 'PASS' else 'FAIL' end);

  perform public.process_planet_tick(v_planet);
  select metal,crystal,deuterium into v_before_m,v_before_c,v_before_d
  from public.planet_resources where planet_id=v_planet;

  select * into v_result from public.start_ship(v_player,v_planet,v_ship,1);
  v_ship_queue:=v_result.queue_id;

  select metal,crystal,deuterium into v_after_m,v_after_c,v_after_d
  from public.planet_resources where planet_id=v_planet;
  select sq.status into v_status from public.shipyard_queue sq where sq.id=v_ship_queue;

  insert into t_results(prueba,resultado) values
  ('3. start_ship: cola BUILDING + descuento exacto',
   case when v_ship_queue is not null and upper(v_status)='BUILDING'
          and v_before_m-v_after_m=v_ship_contract.metal_cost
          and v_before_c-v_after_c=v_ship_contract.crystal_cost
          and v_before_d-v_after_d=v_ship_contract.deuterium_cost
        then 'PASS' else 'FAIL' end);

  update public.shipyard_queue
     set started_at=now()-interval '1 second', finishes_at=now()
   where id=v_ship_queue;
  select * into v_result from public.process_shipyard_queue(v_planet);
  select sq.status into v_status from public.shipyard_queue sq where sq.id=v_ship_queue;
  select coalesce((select ps.quantity from public.planet_ships ps
                    where ps.planet_id=v_planet and ps.ship_id=v_ship),0)
    into v_after_qty;

  insert into t_results(prueba,resultado) values
  ('4. process_shipyard_queue: COMPLETED + inventario incrementado',
   case when upper(v_status)='COMPLETED' and v_after_qty>=1 then 'PASS' else 'FAIL' end);

  select count(*) into v_count from public.process_shipyard_queue(v_planet);
  insert into t_results(prueba,resultado) values
  ('5. segunda pasada shipyard: no reprocesa cola completada',
   case when v_count=0 then 'PASS' else 'FAIL' end);

  perform public.process_planet_tick(v_planet);
  select metal,crystal,deuterium into v_before_m,v_before_c,v_before_d
  from public.planet_resources where planet_id=v_planet;
  select coalesce((select pd.quantity from public.planet_defenses pd
                    where pd.planet_id=v_planet and pd.defense_id=v_defense),0)
    into v_before_qty;

  select * into v_result from public.start_defense(v_player,v_planet,v_defense,1);
  v_defense_queue:=v_result.queue_id;

  select metal,crystal,deuterium into v_after_m,v_after_c,v_after_d
  from public.planet_resources where planet_id=v_planet;
  select dq.status into v_status from public.defense_queue dq where dq.id=v_defense_queue;

  insert into t_results(prueba,resultado) values
  ('6. start_defense: cola BUILDING + descuento exacto',
   case when v_defense_queue is not null and upper(v_status)='BUILDING'
          and v_before_m-v_after_m=v_defense_contract.metal_cost
          and v_before_c-v_after_c=v_defense_contract.crystal_cost
          and v_before_d-v_after_d=v_defense_contract.deuterium_cost
        then 'PASS' else 'FAIL' end);

  update public.defense_queue
     set started_at=now()-interval '1 second', finishes_at=now()
   where id=v_defense_queue;
  select * into v_result from public.process_defense_queue(v_planet);
  select dq.status into v_status from public.defense_queue dq where dq.id=v_defense_queue;
  select coalesce((select pd.quantity from public.planet_defenses pd
                    where pd.planet_id=v_planet and pd.defense_id=v_defense),0)
    into v_after_qty;

  insert into t_results(prueba,resultado) values
  ('7. process_defense_queue: COMPLETED + inventario incrementado',
   case when upper(v_status)='COMPLETED' and v_after_qty=v_before_qty+1 then 'PASS' else 'FAIL' end);

  select count(*) into v_count from public.process_defense_queue(v_planet);
  insert into t_results(prueba,resultado) values
  ('8. segunda pasada defense: no reprocesa cola completada',
   case when v_count=0 then 'PASS' else 'FAIL' end);

  perform set_config('request.jwt.claims','{}',true);
  v_ok:=false;
  begin
    perform public.start_ship(v_player,v_planet,v_ship,1);
  exception when others then
    v_ok:=sqlerrm like 'Authentication required%';
  end;
  insert into t_results(prueba,resultado) values
  ('9. start_ship sin autenticación: rechazado',
   case when v_ok then 'PASS' else 'FAIL' end);

  v_ok:=false;
  begin
    perform public.start_defense(v_player,v_planet,v_defense,1);
  exception when others then
    v_ok:=sqlerrm like 'Authentication required%';
  end;
  insert into t_results(prueba,resultado) values
  ('10. start_defense sin autenticación: rechazado',
   case when v_ok then 'PASS' else 'FAIL' end);

  perform set_config('request.jwt.claims',
    json_build_object('sub',gen_random_uuid()::text,'role','authenticated')::text,true);

  v_ok:=false;
  begin
    perform public.start_ship(v_player,v_planet,v_ship,1);
  exception when others then
    v_ok:=sqlerrm like 'Player does not belong to authenticated user%';
  end;
  insert into t_results(prueba,resultado) values
  ('11. start_ship con usuario ajeno: ownership rechazado',
   case when v_ok then 'PASS' else 'FAIL' end);

  v_ok:=false;
  begin
    perform public.start_defense(v_player,v_planet,v_defense,1);
  exception when others then
    v_ok:=sqlerrm like 'Player does not belong to authenticated user%';
  end;
  insert into t_results(prueba,resultado) values
  ('12. start_defense con usuario ajeno: ownership rechazado',
   case when v_ok then 'PASS' else 'FAIL' end);

  if exists(select 1 from t_results where resultado<>'PASS') then
    raise exception 'SHIPYARD_DEFENSE TEST FAILED';
  end if;
end;
$test$;

select orden,prueba,resultado from t_results order by orden;

rollback;
