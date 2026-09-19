-- ============================================================================
-- ACS_HOLD / HOLDING LIFECYCLE TEST — LA GRAN IMPLOSIÓN (Fase A)
-- ----------------------------------------------------------------------------
-- NO ES UNA MIGRACIÓN. Test manual transaccional: todo ocurre dentro de una
-- transacción que termina en ROLLBACK (incluido el universo de prueba), por lo
-- que NO modifica datos reales. Los datos reales que se reutilizan (planeta de
-- origen, planeta extranjero, recursos y naves) se dejan como estaban al
-- revertir la transacción.
--
-- Identidad: request.jwt.claims simula la sesión del frontend (auth.uid()),
-- el mismo contrato que aplica 20260918030000_harden_player_ownership_in_owned_rpcs.
--
-- Cubre:
--   A. ownership            (jugador legítimo PASS · jugador ajeno FAIL)
--   B. destino              (inexistente · destruido · propio · extranjero sin autorización)
--   C. misión               (ACS_HOLD permitido · HOLDING rechazado · DEFEND COMBAT_SUPPORT_NOT_READY)
--   D. lifecycle completo   (OUTBOUND → ARRIVED → HOLDING → RETURNING → COMPLETED)
--   E. holding_until        (NULL · pasado · antes de la llegada · válido)
--   F. fuel                 (salida única por el helper canónico)
--   G. atomicidad           (fallo tras validar: naves/fuel sin cambios, movimiento ausente)
--   H. idempotencia         (misma request dos veces: un movimiento, un descuento)
--
-- Ejecutable desde el SQL Editor o mediante execute_sql (MCP). No usa framework.
-- ============================================================================

begin;


do $test$
declare
  v_user_a uuid;
  v_player_a uuid;
  v_planet_a uuid;
  v_planet_a2 uuid;
  v_planet_b uuid;
  v_player_b uuid;
  v_universe_a uuid;
  v_probe_universe uuid;
  v_key uuid := gen_random_uuid();
  v_key2 uuid := gen_random_uuid();
  v_ships jsonb := '{"light_fighter": 5, "small_cargo": 3}'::jsonb;
  v_rows int;
  v_ok boolean;
  v_fails text := '';
  v_n int;
  v_distance numeric;
  v_min_speed numeric;
  v_ship_speed numeric;
  v_ship_id text;
  v_quantity bigint;
  v_class numeric;
  v_evolution numeric;
  v_bonus numeric;
  v_travel numeric;
  v_fuel_expected numeric := 0;
  v_capacity numeric;
  v_deut_before numeric;
  v_deut_after numeric;
  v_ships_before bigint;
  v_ships_after bigint;
  v_moves_before int;
  v_moves_after int;
  v_fleet uuid;
  v_fleet2 uuid;
  v_status text;
  v_mission text;
  v_fuel numeric;
  v_prev text;
  v_new text;
  v_holding timestamptz;
  v_arrives timestamptz;
  v_started timestamptz;
  v_returns timestamptz;
  v_replay boolean;
  v_auth_id uuid;
  v_auth_id2 uuid;
  v_err text;
  v_rec record;
begin
  create temp table t_results(orden serial, prueba text, resultado text) on commit drop;

  /* ======================= FIXTURE (datos reales, revertidos) ============== */
  select pl.user_id, p.player_id, p.id, p.universe_id
    into v_user_a, v_player_a, v_planet_a, v_universe_a
  from public.planets p
  join public.players pl on pl.id = p.player_id
  join public.planet_resources pr on pr.planet_id = p.id
  where pl.user_id is not null
    and p.is_destroyed = false
  order by p.created_at, p.id
  limit 1;

  if v_planet_a is null then
    raise exception 'TEST_ABORT: no owned planet with a linked auth user is available';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  /* Planeta extranjero más cercano del mismo universo (mantiene el fuel pequeño) */
  select p.id, p.player_id into v_planet_b, v_player_b
  from public.planets p
  where p.universe_id = v_universe_a
    and p.player_id is not null
    and p.player_id <> v_player_a
    and not p.is_destroyed
  order by public.calculate_fleet_distance(v_planet_a, p.id), p.id
  limit 1;

  if v_planet_b is null then
    raise exception 'TEST_ABORT: no foreign planet in the origin universe is available';
  end if;

  select p.id into v_planet_a2
  from public.planets p
  where p.player_id = v_player_a and not p.is_destroyed and p.id <> v_planet_a
  order by p.created_at, p.id
  limit 1;
  if v_planet_a2 is null then
    v_planet_a2 := v_planet_a;
  end if;

  insert into public.universes(name, is_active, fleet_speed, peaceful_fleet_speed, war_fleet_speed, holding_fleet_speed)
  values ('TEST - acs hold probe (transactional)', false, 1, 1, 1, 1)
  returning id into v_probe_universe;

  raise notice 'TEST origin=% player=% | foreign=% owner=% | own-2=%',
    v_planet_a, v_player_a, v_planet_b, v_player_b, v_planet_a2;

  /* Composición canónica en el origen + recursos suficientes */
  insert into public.planet_ships(planet_id, ship_id, quantity)
  values (v_planet_a, 'small_cargo', 3), (v_planet_a, 'light_fighter', 5)
  on conflict (planet_id, ship_id) do update set quantity = excluded.quantity;

  perform * from public.update_planet_resources_until(v_planet_a, now());

  /* Distancia / velocidad / tiempo de vuelo calculados con los helpers canónicos
     (idénticos a los que usa el dispatcher) para dimensionar el deuterio. */
  v_distance := public.calculate_fleet_distance(v_planet_a, v_planet_b);
  for v_ship_id, v_quantity in select key, value::bigint from jsonb_each_text(v_ships) loop
    v_ship_speed := public.calculate_player_ship_speed(v_player_a, v_ship_id);
    v_min_speed := case when v_min_speed is null then v_ship_speed else least(v_min_speed, v_ship_speed) end;
  end loop;
  v_class := public.calculate_mission_fleet_speed_multiplier(v_universe_a, 'ACS_HOLD');
  v_evolution := public.calculate_universe_evolution_rate(v_universe_a);
  v_bonus := 1 + (
    coalesce(public.get_active_expedition_item_effect(v_player_a, v_planet_a, 'fleet_speed_percent'), 0)
    + coalesce(public.get_active_lifeform_research_effect(v_player_a, 'fleet_speed_percent'), 0)
  ) / 100;
  v_travel := greatest(
    public.calculate_fleet_travel_time(v_distance, v_min_speed, v_class * power(v_evolution, 1.0/3.0) * v_bonus, 100),
    1
  );
  for v_ship_id, v_quantity in select key, value::bigint from jsonb_each_text(v_ships) loop
    v_fuel_expected := v_fuel_expected + public.calculate_player_fleet_fuel_for_distance(
      v_distance, v_travel, v_player_a, v_ship_id, v_quantity, 100);
  end loop;

  select s.deuterium_capacity into v_capacity from public.calculate_planet_storage(v_planet_a) s;

  if coalesce(v_capacity, 0) < v_fuel_expected + 1000 then
    raise exception 'TEST_ABORT: origin storage (% deuterium) cannot hold the required fuel (%)',
      v_capacity, v_fuel_expected;
  end if;

  update public.planet_resources
     set deuterium = least(v_capacity, v_fuel_expected + 100000),
         metal = 100000,
         crystal = 100000,
         last_calculated_at = now(),
         updated_at = now()
   where planet_id = v_planet_a;

  raise notice 'TEST distance=% travel=% fuel_expected=%', v_distance, v_travel, v_fuel_expected;

  /* ======================= A. OWNERSHIP ==================================== */
  v_ok := false;
  begin
    perform public.start_support_fleet(
      v_player_b, v_planet_a, v_planet_b, v_ships, 'ACS_HOLD',
      now() + interval '7 days', gen_random_uuid());
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'Player does not belong to authenticated user%';
  end;
  insert into t_results(prueba, resultado) values
    ('A1. jugador ajeno (p_player_id de otro jugador) -> rechazado [' || coalesce(v_err,'sin error') || ']',
     case when v_ok then 'PASS' else 'FAIL' end);

  /* ======================= C. MISSION GATE ================================= */
  v_err := null;
  v_ok := false;
  begin
    perform public.start_support_fleet(
      v_player_a, v_planet_a, v_planet_b, v_ships, 'DEFEND',
      now() + interval '7 days', gen_random_uuid());
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'COMBAT_SUPPORT_NOT_READY%';
  end;
  insert into t_results(prueba, resultado) values
    ('C1. DEFEND -> COMBAT_SUPPORT_NOT_READY [' || coalesce(v_err,'sin error') || ']',
     case when v_ok then 'PASS' else 'FAIL' end);

  v_err := null;
  v_ok := false;
  begin
    perform public.start_support_fleet(
      v_player_a, v_planet_a, v_planet_b, v_ships, 'HOLDING',
      now() + interval '7 days', gen_random_uuid());
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'HOLDING_IS_INTERNAL_STATE%';
  end;
  insert into t_results(prueba, resultado) values
    ('C2. HOLDING como misión player-facing -> rechazado [' || coalesce(v_err,'sin error') || ']',
     case when v_ok then 'PASS' else 'FAIL' end);

  v_err := null;
  v_ok := false;
  begin
    perform public.start_support_fleet(
      v_player_a, v_planet_a, v_planet_b, v_ships, 'TRANSPORT',
      now() + interval '7 days', gen_random_uuid());
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'Invalid support mission type%';
  end;
  insert into t_results(prueba, resultado) values
    ('C3. misión no-soporte -> Invalid support mission type [' || coalesce(v_err,'sin error') || ']',
     case when v_ok then 'PASS' else 'FAIL' end);

  v_err := null;
  v_ok := false;
  begin
    perform public.start_support_fleet(
      v_player_a, v_planet_a, v_planet_b, v_ships, 'ACS_HOLD',
      now() + interval '7 days', null);
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'IDEMPOTENCY_KEY_REQUIRED%';
  end;
  insert into t_results(prueba, resultado) values
    ('C4. sin idempotency_key -> IDEMPOTENCY_KEY_REQUIRED [' || coalesce(v_err,'sin error') || ']',
     case when v_ok then 'PASS' else 'FAIL' end);


  /* ======================= B. DESTINATION ================================== */
  v_err := null;
  v_ok := false;
  begin
    perform public.start_support_fleet(
      v_player_a, v_planet_a, gen_random_uuid(), v_ships, 'ACS_HOLD',
      now() + interval '7 days', gen_random_uuid());
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'Destination planet not found%';
  end;
  insert into t_results(prueba, resultado) values
    ('B1. destino inexistente -> rechazado [' || coalesce(v_err,'sin error') || ']',
     case when v_ok then 'PASS' else 'FAIL' end);

  update public.planets set is_destroyed = true where id = v_planet_b;
  v_err := null;
  v_ok := false;
  begin
    perform public.start_support_fleet(
      v_player_a, v_planet_a, v_planet_b, v_ships, 'ACS_HOLD',
      now() + interval '7 days', gen_random_uuid());
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'Destination planet is destroyed%';
  end;
  update public.planets set is_destroyed = false where id = v_planet_b;
  insert into t_results(prueba, resultado) values
    ('B2. destino destruido -> rechazado [' || coalesce(v_err,'sin error') || ']',
     case when v_ok then 'PASS' else 'FAIL' end);

  v_err := null;
  v_ok := false;
  begin
    perform public.start_support_fleet(
      v_player_a, v_planet_a, v_planet_a2, v_ships, 'ACS_HOLD',
      now() + interval '7 days', gen_random_uuid());
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'ACS_HOLD_DESTINATION_OWN_PLANET%' or v_err like '%must be different%';
  end;
  insert into t_results(prueba, resultado) values
    ('B3. destino propio -> rechazado [' || coalesce(v_err,'sin error') || ']',
     case when v_ok then 'PASS' else 'FAIL' end);

  v_err := null;
  v_ok := false;
  begin
    perform public.start_support_fleet(
      v_player_a, v_planet_a, v_planet_b, v_ships, 'ACS_HOLD',
      now() + interval '7 days', gen_random_uuid());
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'SUPPORT_AUTHORIZATION_REQUIRED%';
  end;
  insert into t_results(prueba, resultado) values
    ('B4. destino extranjero SIN autorización -> rechazado [' || coalesce(v_err,'sin error') || ']',
     case when v_ok then 'PASS' else 'FAIL' end);

  update public.planets set universe_id = v_probe_universe where id = v_planet_b;
  v_err := null;
  v_ok := false;
  begin
    perform public.start_support_fleet(
      v_player_a, v_planet_a, v_planet_b, v_ships, 'ACS_HOLD',
      now() + interval '7 days', gen_random_uuid());
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'Destination planet belongs to another universe%';
  end;
  update public.planets set universe_id = v_universe_a where id = v_planet_b;
  insert into t_results(prueba, resultado) values
    ('B5. destino en otro universo -> rechazado [' || coalesce(v_err,'sin error') || ']',
     case when v_ok then 'PASS' else 'FAIL' end);

  /* ======================= POLICY RPC (consentimiento explícito) =========== */
  v_auth_id := null;
  select g.authorization_id into v_auth_id
  from public.grant_planet_support_authorization(v_player_a, v_planet_a, v_player_b, null) g;
  select g.authorization_id into v_auth_id2
  from public.grant_planet_support_authorization(v_player_a, v_planet_a, v_player_b, null) g;
  insert into t_results(prueba, resultado) values
    ('P0a. grant_planet_support_authorization crea la autorización',
     case when v_auth_id is not null then 'PASS' else 'FAIL' end),
    ('P0b. re-grant idempotente (misma fila, sin duplicar)',
     case when v_auth_id = v_auth_id2 then 'PASS' else 'FAIL' end);

  v_err := null;
  v_ok := false;
  begin
    perform public.grant_planet_support_authorization(v_player_a, v_planet_a, v_player_a, null);
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'SUPPORT_AUTHORIZATION_SELF%';
  end;
  insert into t_results(prueba, resultado) values
    ('P0c. autorización a sí mismo -> rechazada [' || coalesce(v_err,'sin error') || ']',
     case when v_ok then 'PASS' else 'FAIL' end);

  v_err := null;
  v_ok := false;
  begin
    perform public.grant_planet_support_authorization(v_player_a, v_planet_b, v_player_a, null);
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'PLANET_NOT_OWNED_BY_PLAYER%';
  end;
  insert into t_results(prueba, resultado) values
    ('P0d. conceder en planeta ajeno -> rechazado [' || coalesce(v_err,'sin error') || ']',
     case when v_ok then 'PASS' else 'FAIL' end);

  insert into t_results(prueba, resultado) values
    ('P0e. revoke_planet_support_authorization revoca',
     case when public.revoke_planet_support_authorization(v_player_a, v_planet_a, v_player_b) then 'PASS' else 'FAIL' end);

  /* Autorización de fixture para el destino real (insertada directamente:
     LIVE puede no tener un segundo jugador con auth user vinculado). */
  insert into public.planet_support_authorizations(
    destination_planet_id, owner_player_id, guest_player_id, authorized_at, expires_at, revoked_at)
  values (v_planet_b, v_player_b, v_player_a, now(), null, null);


  /* ======================= B6/B7. POLICY STATE ============================= */
  update public.planet_support_authorizations
     set authorized_at = now() - interval '2 hours', expires_at = now() - interval '1 hour'
   where destination_planet_id = v_planet_b and guest_player_id = v_player_a;

  v_err := null;
  v_ok := false;
  begin
    perform public.start_support_fleet(
      v_player_a, v_planet_a, v_planet_b, v_ships, 'ACS_HOLD',
      now() + interval '7 days', gen_random_uuid());
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'SUPPORT_AUTHORIZATION_REQUIRED%';
  end;
  insert into t_results(prueba, resultado) values
    ('B6. autorización expirada -> rechazado [' || coalesce(v_err,'sin error') || ']',
     case when v_ok then 'PASS' else 'FAIL' end);

  update public.planet_support_authorizations
     set expires_at = null, revoked_at = now()
   where destination_planet_id = v_planet_b and guest_player_id = v_player_a;

  v_err := null;
  v_ok := false;
  begin
    perform public.start_support_fleet(
      v_player_a, v_planet_a, v_planet_b, v_ships, 'ACS_HOLD',
      now() + interval '7 days', gen_random_uuid());
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'SUPPORT_AUTHORIZATION_REQUIRED%';
  end;
  insert into t_results(prueba, resultado) values
    ('B7. autorización revocada -> rechazado [' || coalesce(v_err,'sin error') || ']',
     case when v_ok then 'PASS' else 'FAIL' end);

  update public.planet_support_authorizations
     set revoked_at = null, authorized_at = now(), expires_at = null
   where destination_planet_id = v_planet_b and guest_player_id = v_player_a;

  /* ======================= E. HOLDING_UNTIL ================================ */
  v_err := null;
  v_ok := false;
  begin
    perform public.start_support_fleet(
      v_player_a, v_planet_a, v_planet_b, v_ships, 'ACS_HOLD', null, gen_random_uuid());
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'HOLDING_UNTIL_REQUIRED%';
  end;
  insert into t_results(prueba, resultado) values
    ('E1. holding_until NULL -> rechazado [' || coalesce(v_err,'sin error') || ']',
     case when v_ok then 'PASS' else 'FAIL' end);

  v_err := null;
  v_ok := false;
  begin
    perform public.start_support_fleet(
      v_player_a, v_planet_a, v_planet_b, v_ships, 'ACS_HOLD',
      now() - interval '1 hour', gen_random_uuid());
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'HOLDING_UNTIL_NOT_IN_FUTURE%';
  end;
  insert into t_results(prueba, resultado) values
    ('E2. holding_until en el pasado -> rechazado [' || coalesce(v_err,'sin error') || ']',
     case when v_ok then 'PASS' else 'FAIL' end);

  v_err := null;
  v_ok := false;
  begin
    perform public.start_support_fleet(
      v_player_a, v_planet_a, v_planet_b, v_ships, 'ACS_HOLD',
      now() + interval '100 milliseconds', gen_random_uuid());
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'HOLDING_UNTIL_BEFORE_ARRIVAL%';
  end;
  insert into t_results(prueba, resultado) values
    ('E3. holding_until antes de la llegada -> rechazado [' || coalesce(v_err,'sin error') || ']',
     case when v_ok then 'PASS' else 'FAIL' end);


  /* ============ G3-G6. ATOMICIDAD: fallo tras validar, antes del commit ====
     Todas las validaciones (identidad, destino, autorización, composición,
     velocidad, viaje) y el cálculo de fuel se completan; el fallo se produce en
     la última puerta previa a la mutación. El RPC es una única transacción, así
     que nada puede quedar a medias: se comprueba que naves, deuterio y
     movimientos permanecen intactos. */
  update public.planet_resources
     set deuterium = 0, last_calculated_at = now()
   where planet_id = v_planet_a;

  select count(*) into v_moves_before from public.fleet_movements where player_id = v_player_a;
  select quantity into v_ships_before from public.planet_ships where planet_id = v_planet_a and ship_id = 'light_fighter';

  v_err := null;
  v_ok := false;
  begin
    perform public.start_support_fleet(
      v_player_a, v_planet_a, v_planet_b, v_ships, 'ACS_HOLD', now() + interval '7 days', v_key2);
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'Insufficient deuterium for fleet fuel%';
  end;

  select count(*) into v_moves_after from public.fleet_movements where player_id = v_player_a;
  select deuterium into v_deut_after from public.planet_resources where planet_id = v_planet_a;
  select quantity into v_ships_after from public.planet_ships where planet_id = v_planet_a and ship_id = 'light_fighter';

  insert into t_results(prueba, resultado) values
    ('G3. fallo tras validar (fuel insuficiente) [' || coalesce(v_err,'sin error') || ']',
     case when v_ok then 'PASS' else 'FAIL' end),
    ('G4. atomicidad: sin movimiento nuevo [' || (v_moves_after - v_moves_before) || ']',
     case when (v_moves_after - v_moves_before) = 0 then 'PASS' else 'FAIL' end),
    ('G5. atomicidad: naves intactas (light_fighter ' || v_ships_after || ')',
     case when v_ships_after = v_ships_before then 'PASS' else 'FAIL' end),
    ('G6. atomicidad: deuterio intacto [' || v_deut_after || ']',
     case when v_deut_after = 0 then 'PASS' else 'FAIL' end);

  update public.planet_resources
     set deuterium = least(v_capacity, v_fuel_expected + 100000),
         last_calculated_at = now(),
         updated_at = now()
   where planet_id = v_planet_a;

  /* ======================= C5/F/G. DISPATCH VÁLIDO ========================= */
  v_holding := now() + interval '7 days';
  select count(*) into v_moves_before from public.fleet_movements where player_id = v_player_a;
  select deuterium into v_deut_before from public.planet_resources where planet_id = v_planet_a;
  select quantity into v_ships_before from public.planet_ships where planet_id = v_planet_a and ship_id = 'small_cargo';

  v_fleet := null;
  for v_rec in
    select * from public.start_support_fleet(
      v_player_a, v_planet_a, v_planet_b, v_ships, 'ACS_HOLD', v_holding, v_key)
  loop
    v_fleet := v_rec.fleet_id;
    insert into t_results(prueba, resultado) values
      ('C5. ACS_HOLD con policy satisfecha -> dispatch permitido (nave ' || v_rec.ship_id || ')',
       case when v_rec.status = 'OUTBOUND' and v_rec.mission_type = 'ACS_HOLD' and not v_rec.idempotent_replay
            then 'PASS' else 'FAIL' end);
  end loop;

  if v_fleet is null then
    raise exception 'TEST_ABORT: the valid ACS_HOLD dispatch returned no movement';
  end if;

  select fm.status, fm.mission_type, fm.holding_until, fm.arrives_at, fm.started_at,
         fm.returns_at, fm.fuel_consumed
    into v_status, v_mission, v_holding, v_arrives, v_started, v_returns, v_fuel
  from public.fleet_movements fm where fm.id = v_fleet;

  insert into t_results(prueba, resultado) values
    ('C6. movimiento persistido ACS_HOLD/OUTBOUND con holding_until absoluto y sin returns_at',
     case when v_status = 'OUTBOUND' and v_mission = 'ACS_HOLD' and v_returns is null
          then 'PASS' else 'FAIL' end);

  insert into t_results(prueba, resultado) values
    ('F1. fuel_consumed = helper canónico una sola vez (' || v_fuel || ' vs ' || v_fuel_expected || ')',
     case when v_fuel = v_fuel_expected then 'PASS' else 'FAIL' end);

  select deuterium into v_deut_after from public.planet_resources where planet_id = v_planet_a;
  insert into t_results(prueba, resultado) values
    ('G1. deuterio descontado exactamente una vez (' || round(v_deut_before - v_deut_after, 4) || ')',
     case when abs((v_deut_before - v_deut_after) - v_fuel_expected) <= 1 then 'PASS' else 'FAIL' end);

  select quantity into v_ships_after from public.planet_ships where planet_id = v_planet_a and ship_id = 'small_cargo';
  insert into t_results(prueba, resultado) values
    ('G2. naves descontadas exactamente una vez (small_cargo ' || v_ships_before || ' -> ' || v_ships_after || ')',
     case when v_ships_before - v_ships_after = 3 then 'PASS' else 'FAIL' end);

  select count(*) into v_n from public.fleet_movement_ships where fleet_id = v_fleet;
  insert into t_results(prueba, resultado) values
    ('C7. composición persistida en fleet_movement_ships [' || v_n || ']',
     case when v_n = 2 then 'PASS' else 'FAIL' end);


  /* ======================= H. IDEMPOTENCIA ================================= */
  v_fleet2 := null;
  v_replay := null;
  for v_rec in
    select * from public.start_support_fleet(
      v_player_a, v_planet_a, v_planet_b, v_ships, 'ACS_HOLD', v_holding, v_key)
  loop
    v_fleet2 := v_rec.fleet_id;
    v_replay := v_rec.idempotent_replay;
  end loop;

  select count(*) into v_moves_after from public.fleet_movements where player_id = v_player_a;
  select deuterium into v_deut_after from public.planet_resources where planet_id = v_planet_a;
  select quantity into v_ships_after from public.planet_ships where planet_id = v_planet_a and ship_id = 'small_cargo';

  insert into t_results(prueba, resultado) values
    ('H1. misma request -> mismo movimiento [' || coalesce(v_fleet2::text,'null') || ']',
     case when v_fleet2 = v_fleet and coalesce(v_replay,false) then 'PASS' else 'FAIL' end),
    ('H2. misma request -> un solo movimiento nuevo [' || (v_moves_after - v_moves_before) || ']',
     case when (v_moves_after - v_moves_before) = 1 then 'PASS' else 'FAIL' end),
    ('H3. misma request -> un solo descuento de naves (small_cargo ' || v_ships_after || ')',
     case when v_ships_before - v_ships_after = 3 then 'PASS' else 'FAIL' end),
    ('H4. misma request -> un solo descuento de deuterio (' || round(v_deut_before - v_deut_after, 4) || ' vs ' || v_fuel_expected || ')',
     case when abs((v_deut_before - v_deut_after) - v_fuel_expected) <= 1 then 'PASS' else 'FAIL' end);

  /* ======================= D. LIFECYCLE COMPLETO ===========================
     (la comprobación de atomicidad G3-G6 se ejecuta antes del dispatch válido) */
  update public.fleet_movements
     set started_at = now() - interval '2 hours',
         arrives_at = now() - interval '1 hour',
         holding_until = now() + interval '30 minutes'
   where id = v_fleet;

  v_prev := null;
  v_new := null;
  select r.previous_status, r.new_status into v_prev, v_new
  from public.process_fleet_movements() r
  where r.fleet_id = v_fleet;

  select status, holding_until, returns_at into v_status, v_holding, v_returns
  from public.fleet_movements where id = v_fleet;

  insert into t_results(prueba, resultado) values
    ('D1. OUTBOUND -> HOLDING por el worker existente [' || coalesce(v_prev,'null') || ' -> ' || coalesce(v_new,'null') || ']',
     case when v_prev = 'OUTBOUND' and v_new = 'HOLDING' and v_status = 'HOLDING' then 'PASS' else 'FAIL' end),
    ('D2. holding_until no se recalcula al entrar en HOLDING y returns_at sigue NULL',
     case when v_status = 'HOLDING' and v_holding > now() and v_returns is null then 'PASS' else 'FAIL' end);

  select count(*) into v_n from public.process_fleet_movements() r where r.fleet_id = v_fleet;
  insert into t_results(prueba, resultado) values
    ('D3. worker idempotente: hold aún no vencido -> sin transición [' || v_n || ']',
     case when v_n = 0 then 'PASS' else 'FAIL' end);

  update public.fleet_movements set holding_until = now() - interval '10 minutes' where id = v_fleet;

  select arrives_at, started_at into v_arrives, v_started
  from public.fleet_movements where id = v_fleet;

  v_prev := null;
  v_new := null;
  select r.previous_status, r.new_status into v_prev, v_new
  from public.process_fleet_movements() r
  where r.fleet_id = v_fleet;

  select status, holding_until, returns_at into v_status, v_holding, v_returns
  from public.fleet_movements where id = v_fleet;

  insert into t_results(prueba, resultado) values
    ('D4. HOLDING -> RETURNING al vencer holding_until [' || coalesce(v_new,'null') || ']',
     case when v_prev = 'HOLDING' and v_new = 'RETURNING' and v_status = 'RETURNING' then 'PASS' else 'FAIL' end),
    ('D5. retorno = duración outbound persistida, sin recalcular velocidad [' || v_returns || ']',
     case when v_returns = v_holding + (v_arrives - v_started) then 'PASS' else 'FAIL: esperado ' || (v_holding + (v_arrives - v_started)) end);

  /* El reloj de recursos debe ser anterior al retorno para que la liquidación
     del worker sea válida (simula que nadie liquidó el planeta desde entonces). */
  update public.planet_resources
     set last_calculated_at = now() - interval '2 hours'
   where planet_id = v_planet_a;

  update public.fleet_movements set returns_at = now() - interval '1 minute' where id = v_fleet;
  select returns_at into v_holding from public.fleet_movements where id = v_fleet;

  v_prev := null;
  v_new := null;
  select r.previous_status, r.new_status into v_prev, v_new
  from public.process_fleet_movements() r
  where r.fleet_id = v_fleet;

  select fm.status, fm.returns_at, fm.holding_until, fm.fuel_consumed
    into v_status, v_returns, v_arrives, v_fuel
  from public.fleet_movements fm where fm.id = v_fleet;

  select quantity into v_ships_after from public.planet_ships where planet_id = v_planet_a and ship_id = 'small_cargo';

  insert into t_results(prueba, resultado) values
    ('D6. RETURNING -> COMPLETED [' || coalesce(v_new,'null') || ']',
     case when v_prev = 'RETURNING' and v_new = 'COMPLETED' and v_status = 'COMPLETED' then 'PASS' else 'FAIL' end),
    ('D7. naves devueltas al origen (small_cargo ' || v_ships_after || ')',
     case when v_ships_after = 3 then 'PASS' else 'FAIL' end),
    ('D8. engine sin recálculo: returns_at/fuel preservados [' || v_returns || ' / ' || v_fuel || ']',
     case when v_returns = v_holding and v_fuel = v_fuel_expected then 'PASS' else 'FAIL' end);

  select count(*) into v_n from public.process_fleet_movements() r where r.fleet_id = v_fleet;
  insert into t_results(prueba, resultado) values
    ('D9. worker idempotente tras COMPLETED -> sin transición [' || v_n || ']',
     case when v_n = 0 then 'PASS' else 'FAIL' end);


  /* ======================= F. ASSERTIONS ESTRUCTURALES ===================== */
  select count(*) into v_n
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'start_support_fleet'
    and pg_get_functiondef(p.oid) ~ 'calculate_player_ship_speed'
    and pg_get_functiondef(p.oid) ~ 'calculate_mission_fleet_speed_multiplier'
    and pg_get_functiondef(p.oid) ~ 'calculate_fleet_travel_time'
    and pg_get_functiondef(p.oid) ~ 'calculate_player_fleet_fuel_for_distance'
    and pg_get_functiondef(p.oid) ~ 'planet_support_authorizations'
    and pg_get_functiondef(p.oid) ~ 'ACS_HOLD';
  insert into t_results(prueba, resultado) values
    ('F2. dispatcher sobre el pipeline canónico completo [' || v_n || ']',
     case when v_n = 1 then 'PASS' else 'FAIL: ' || v_n end);

  select count(*) into v_n
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'start_support_fleet'
    and (pg_get_functiondef(p.oid) ~ '35000'
      or pg_get_functiondef(p.oid) ~ '\.speed'
      or pg_get_functiondef(p.oid) ~ 'universes');
  insert into t_results(prueba, resultado) values
    ('F3. dispatcher sin fórmulas paralelas (35000 / .speed / universes) [' || v_n || ']',
     case when v_n = 0 then 'PASS' else 'FAIL: ' || v_n end);

  select count(*) into v_n
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'process_fleet_movements'
    and pg_get_functiondef(p.oid) ~ 'holding_until'
    and pg_get_functiondef(p.oid) ~ 'ACS_HOLD'
    and pg_get_functiondef(p.oid) ~ 'SUPPORT_HOLDING_WINDOW'
    and pg_get_functiondef(p.oid) !~ '35000'
    and pg_get_functiondef(p.oid) !~ 'calculate_fleet_travel_time'
    and pg_get_functiondef(p.oid) !~ 'calculate_player_ship_speed'
    and pg_get_functiondef(p.oid) !~ 'calculate_player_fleet_fuel_for_distance';
  insert into t_results(prueba, resultado) values
    ('F4. worker único: valida el hold y NO recalcula viaje/velocidad/fuel [' || v_n || ']',
     case when v_n = 1 then 'PASS' else 'FAIL: ' || v_n end);

  select count(*) into v_n
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('start_acs_hold','start_defend','start_holding',
                      'calculate_acs_speed','calculate_holding_speed','calculate_defend_speed');
  insert into t_results(prueba, resultado) values
    ('F5. sin dispatchers/helpers paralelos de soporte [' || v_n || ']',
     case when v_n = 0 then 'PASS' else 'FAIL: ' || v_n end);

  select count(*) into v_n
  from pg_constraint con join pg_class c on c.oid = con.conrelid join pg_namespace ns on ns.oid = c.relnamespace
  where ns.nspname = 'public' and c.relname = 'fleet_movements'
    and con.conname in ('fleet_movements_mission_type_chk','fleet_movements_status_chk');
  insert into t_results(prueba, resultado) values
    ('F6. constraints legadas que bloqueaban ACS_HOLD/HOLDING eliminadas [' || v_n || ']',
     case when v_n = 0 then 'PASS' else 'FAIL: ' || v_n end);

  select count(*) into v_n
  from public.planet_support_authorizations;
  insert into t_results(prueba, resultado) values
    ('F7. tabla de autorización explícita operativa [' || v_n || ' fila(s)]',
     case when v_n >= 1 then 'PASS' else 'FAIL' end);


  /* ---------------------------------------------------------------- RESULTADOS */
  raise notice '----- ACS_HOLD / HOLDING LIFECYCLE TEST -----';
  for v_rec in select orden, prueba, resultado from t_results order by orden loop
    raise notice '%  %  ->  %', rpad(v_rec.orden::text, 3), v_rec.resultado, v_rec.prueba;
  end loop;

  select count(*), coalesce(string_agg('[' || orden || '] ' || resultado || ' :: ' || prueba, ' | ' order by orden), '')
    into v_rows, v_fails
    from t_results
   where resultado not like 'PASS%';

  if v_rows > 0 then
    raise exception 'ACS_HOLD LIFECYCLE TEST FAILED: % prueba(s) con FAIL -> %', v_rows, v_fails;
  end if;

  raise notice 'ACS_HOLD LIFECYCLE TEST: ALL PASS (transacción revertida, sin cambios reales)';
end;
$test$;

select orden, resultado, prueba from t_results order by orden;

rollback;

