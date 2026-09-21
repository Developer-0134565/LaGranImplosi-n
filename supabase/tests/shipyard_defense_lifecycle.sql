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
-- 2026-09-21: el fixture se resuelve desde LIVE (los UUIDs fijos ya no existían) y se
-- añaden las aserciones 13-15, que reproducen el rol CLIENTE real para Defense
-- (contrato can_build_defense + cierre del processor público).
-- ============================================================================

begin;

do $test$
declare
  v_player uuid;
  v_user uuid;
  v_planet uuid;
  v_other_player uuid;
  v_ship text := 'solar_satellite';
  v_defense text := 'rocket_launcher';
  v_client_allowed boolean;
  v_client_reason text;
  v_client_err text;
  v_foreign_allowed boolean;
  v_foreign_reason text;
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

  /* FIXTURE (2026-09-21): se resuelve el jugador HUMANO REAL de LIVE en lugar de los
     UUIDs fijos, que dejaron de existir y hacían la suite inejecutable. Mismo selector
     que la suite de Research: se prefiere cualquier HUMANO distinto de DevPlayer y, si
     no existe, se acepta DevPlayer (el único HUMANO de LIVE tras 20260921073405). */
  select pl.id, pl.user_id, p.id
    into v_player, v_user, v_planet
  from public.planets p
  join public.players pl on pl.id = p.player_id
  where pl.player_type = 'HUMAN'
    and pl.user_id is not null
    and p.is_destroyed = false
  order by (pl.username like 'DevPlayer%'), p.created_at, p.id
  limit 1;

  if v_planet is null then
    raise exception 'TEST_ABORT: no hay un jugador HUMANO con planeta propio';
  end if;

  select p2.id into v_other_player
  from public.players p2 where p2.id <> v_player limit 1;

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

  /* ---------------- 13-15) DEFENSA · CONTRATO CLIENTE REAL (2026-09-21)
     Los bloques 1-12 se ejecutan como owner; estos tres reproducen el rol CLIENTE real
     (SET LOCAL ROLE authenticated, que es lo que decide ACL/RLS) para los dos defectos
     cerrados por 20260921161247 (processor público) y 20260921161304 (contrato
     availability INVOKER roto). No sustituyen ninguna aserción previa. */
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  v_client_allowed := null; v_client_reason := null; v_client_err := '';
  begin
    execute 'set local role authenticated';
    select r.allowed, r.reason into v_client_allowed, v_client_reason
      from public.can_build_defense(v_player, v_planet, v_defense, 1) r;
    execute 'reset role';
  exception when others then
    v_client_err := sqlerrm;
    begin execute 'reset role'; exception when others then null; end;
  end;
  insert into t_results(prueba,resultado) values
  ('13. can_build_defense ejecutable por el rol cliente REAL [' || coalesce(v_client_reason,'null') || ']',
   case when v_client_err = '' and v_client_allowed is true and v_client_reason = 'OK' then 'PASS'
        else 'FAIL: ' || coalesce(nullif(v_client_err,''), 'allowed=' || coalesce(v_client_allowed::text,'null') || ' motivo=' || coalesce(v_client_reason,'null')) end);

  v_foreign_allowed := null; v_foreign_reason := null; v_client_err := '';
  begin
    execute 'set local role authenticated';
    select r.allowed, r.reason into v_foreign_allowed, v_foreign_reason
      from public.can_build_defense(v_other_player, v_planet, v_defense, 1) r;
    execute 'reset role';
  exception when others then
    v_client_err := sqlerrm;
    begin execute 'reset role'; exception when others then null; end;
  end;
  insert into t_results(prueba,resultado) values
  ('14. can_build_defense no es oráculo ajeno [' || coalesce(v_foreign_reason,'null') || ']',
   case when v_client_err = '' and v_foreign_allowed is false and v_foreign_reason = 'PLAYER_NOT_OWNED' then 'PASS'
        else 'FAIL: ' || coalesce(nullif(v_client_err,''), coalesce(v_foreign_reason,'(sin motivo)')) end);

  insert into t_results(prueba,resultado) values
  ('15. process_defense_queue_until cerrado al cliente (postgres/service_role only)',
   case when not has_function_privilege('authenticated','public.process_defense_queue_until(uuid,timestamp with time zone)','EXECUTE')
             and not has_function_privilege('anon','public.process_defense_queue_until(uuid,timestamp with time zone)','EXECUTE')
             and has_function_privilege('service_role','public.process_defense_queue_until(uuid,timestamp with time zone)','EXECUTE')
        then 'PASS' else 'FAIL' end);

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  if exists(select 1 from t_results where resultado<>'PASS') then
    raise exception 'SHIPYARD_DEFENSE TEST FAILED';
  end if;
end;
$test$;

select orden,prueba,resultado from t_results order by orden;

rollback;
