-- ============================================================================
-- FLEET SUPPORT AUTHORIZATION CHAIN — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Rollback-safe transactional fixture (BEGIN … ROLLBACK).
--
-- Purpose (closes the gap left by the 2026-09-22 ACS blocker):
--   prove the AUTHORIZATION -> DISPATCH chain end to end through the REAL RPCs,
--   not through a directly inserted fixture row:
--
--     without authorization  -> start_support_fleet raises SUPPORT_AUTHORIZATION_REQUIRED
--     grant_planet_support_authorization (as the destination owner)
--       -> an authorization row exists for (destination planet, guest player)
--       -> start_support_fleet ACCEPTS the ACS_HOLD mission
--       -> an OUTBOUND support movement + its ship composition exist
--     revoke_planet_support_authorization (as the destination owner)
--       -> start_support_fleet is rejected again
--
-- Identity: LIVE has exactly one player with an auth user (DevPlayer), so the
-- destination owner borrows that user for the grant/revoke calls only. The borrow
-- is applied and reverted inside the transaction (players.user_id has a unique
-- partial index) and the whole fixture is rolled back anyway.
--
-- No permanent residue: fleets, fleet ships, authorizations, ships and resources
-- are created inside the transaction and undone by ROLLBACK.
-- ============================================================================

begin;

drop table if exists t_support_chain_results;
create temp table t_support_chain_results(orden serial, resultado text, prueba text);

do $test$
declare
  v_guest uuid; v_user uuid; v_origin uuid; v_universe uuid;
  v_dest uuid; v_dest_owner uuid;
  v_ship text := 'light_fighter'; v_qty bigint := 3;
  v_key uuid := gen_random_uuid();
  v_auth record; v_auth2 record;
  v_rows bigint; v_fleet uuid; v_mission text; v_status text; v_holding timestamptz;
  v_ships_rows bigint; v_deut_before numeric; v_deut_after numeric;
  v_revoked boolean;
  v_ok boolean; v_fail integer := 0; v_lines text := ''; v_err text; v_raised boolean;
begin
  begin
    /* ---------------- fixture resolution (LIVE, read-only) ---------------- */
    select pl.id, pl.user_id, p.id, p.universe_id
      into v_guest, v_user, v_origin, v_universe
    from public.planets p
    join public.players pl on pl.id = p.player_id
    join public.planet_resources pr on pr.planet_id = p.id
    where pl.user_id is not null and p.is_destroyed = false
    order by p.created_at, p.id
    limit 1;

    if v_origin is null then
      raise exception 'CHAIN_ABORT: no player with an auth user and an owned planet';
    end if;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

    /* foreign destination in the same universe, owned by another player */
    select p.id, p.player_id into v_dest, v_dest_owner
    from public.planets p
    where p.universe_id = v_universe
      and p.player_id is not null
      and p.player_id <> v_guest
      and not p.is_destroyed
    order by public.calculate_fleet_distance(v_origin, p.id), p.id
    limit 1;

    if v_dest is null then
      raise exception 'CHAIN_ABORT: no foreign destination planet available';
    end if;

    /* deterministic origin composition + fuel so the dispatch can be measured */
    insert into public.planet_ships(planet_id, ship_id, quantity)
    values (v_origin, v_ship, v_qty)
    on conflict (planet_id, ship_id) do update set quantity = v_qty;

    update public.planet_resources
       set deuterium = greatest(deuterium, 500000),
           metal = greatest(metal, 500000),
           crystal = greatest(crystal, 500000),
           last_calculated_at = now(),
           updated_at = now()
     where planet_id = v_origin;

    /* ---- A) WITHOUT authorization -> rejected ---------------------------- */
    v_raised := false; v_err := null;
    begin
      perform public.start_support_fleet(
        v_guest, v_origin, v_dest, jsonb_build_object(v_ship, 1), 'ACS_HOLD',
        now() + interval '2 hours', v_key);
    exception when others then
      v_raised := true; v_err := sqlerrm;
    end;

    v_ok := v_raised and v_err like 'SUPPORT_AUTHORIZATION_REQUIRED%';
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || 'A1 no authorization -> SUPPORT_AUTHORIZATION_REQUIRED [' || coalesce(v_err,'no error') || ']' || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*) into v_rows from public.planet_support_authorizations;
    v_ok := v_rows = 0;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('A2 no authorization row exists yet (%s)', v_rows) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- B) GRANT through the RPC as the destination owner --------------- */
    update public.players set user_id = null where id = v_guest;
    update public.players set user_id = v_user where id = v_dest_owner;

    select * into v_auth
    from public.grant_planet_support_authorization(v_dest_owner, v_dest, v_guest, null);

    select * into v_auth2
    from public.grant_planet_support_authorization(v_dest_owner, v_dest, v_guest, null);

    update public.players set user_id = null where id = v_dest_owner;
    update public.players set user_id = v_user where id = v_guest;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

    v_ok := v_auth.authorization_id is not null
            and v_auth.destination_planet_id = v_dest
            and v_auth.owner_player_id = v_dest_owner
            and v_auth.guest_player_id = v_guest;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || 'B1 grant_planet_support_authorization creates the authorization' || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := v_auth2.authorization_id is not distinct from v_auth.authorization_id;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || 'B2 re-grant is idempotent (same row)' || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*) into v_rows from public.planet_support_authorizations
     where destination_planet_id = v_dest and guest_player_id = v_guest and revoked_at is null;
    v_ok := v_rows = 1;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('B3 exactly one live authorization row (%s)', v_rows) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- C) the SAME dispatch is now AUTHORIZED -------------------------- */
    select pr.deuterium into v_deut_before from public.planet_resources pr where pr.planet_id = v_origin;

    select f.fleet_id into v_fleet
    from public.start_support_fleet(
      v_guest, v_origin, v_dest, jsonb_build_object(v_ship, 1), 'ACS_HOLD',
      now() + interval '2 hours', v_key) f
    limit 1;

    v_ok := v_fleet is not null;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || 'C1 start_support_fleet accepted ACS_HOLD with a granted authorization' || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select fm.mission_type, fm.status, fm.holding_until
      into v_mission, v_status, v_holding
    from public.fleet_movements fm where fm.id = v_fleet;

    v_ok := v_mission = 'ACS_HOLD' and v_status = 'OUTBOUND'
            and v_holding is not null and v_holding > now();
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('C2 movement persisted (mission=%s status=%s)', v_mission, v_status) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*) into v_ships_rows from public.fleet_movement_ships fms where fms.fleet_id = v_fleet;
    v_ok := v_ships_rows >= 1;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('C3 ship composition persisted (%s rows)', v_ships_rows) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select pr.deuterium into v_deut_after from public.planet_resources pr where pr.planet_id = v_origin;
    v_ok := v_deut_after < v_deut_before;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('C4 fuel charged on the canonical path (%s -> %s)', v_deut_before, v_deut_after) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- D) REVOKE through the RPC -> rejected again --------------------- */
    update public.players set user_id = null where id = v_guest;
    update public.players set user_id = v_user where id = v_dest_owner;

    v_revoked := public.revoke_planet_support_authorization(v_dest_owner, v_dest, v_guest);

    update public.players set user_id = null where id = v_dest_owner;
    update public.players set user_id = v_user where id = v_guest;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

    v_ok := v_revoked is true;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || 'D1 revoke_planet_support_authorization revoked the authorization' || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*) into v_rows from public.planet_support_authorizations
     where destination_planet_id = v_dest and guest_player_id = v_guest and revoked_at is null;
    v_ok := v_rows = 0;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('D2 no live authorization remains (%s)', v_rows) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_raised := false; v_err := null;
    begin
      perform public.start_support_fleet(
        v_guest, v_origin, v_dest, jsonb_build_object(v_ship, 1), 'ACS_HOLD',
        now() + interval '2 hours', gen_random_uuid());
    exception when others then
      v_raised := true; v_err := sqlerrm;
    end;

    v_ok := v_raised and v_err like 'SUPPORT_AUTHORIZATION_REQUIRED%';
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || 'D3 revoked authorization -> SUPPORT_AUTHORIZATION_REQUIRED again' || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- E) identity intact after the borrows ---------------------------- */
    select count(*) into v_rows from public.players where user_id is not null;
    v_ok := v_rows = 1;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('E1 exactly one player holds the auth user (%s)', v_rows) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    raise exception 'SUPPORT_CHAIN_FIXTURE_ROLLBACK';
  exception
    when others then
      if sqlerrm <> 'SUPPORT_CHAIN_FIXTURE_ROLLBACK' then
        v_fail := v_fail + 1;
        v_lines := v_lines || 'FAIL|99 unexpected error: ' || sqlerrm || E'\n';
      end if;
  end;

  perform set_config('request.jwt.claims', '{}', false);

  insert into t_support_chain_results(resultado, prueba)
  select split_part(line, '|', 1), split_part(line, '|', 2)
  from unnest(string_to_array(v_lines, E'\n')) as line
  where line <> '';

  if v_fail > 0 then
    raise exception 'SUPPORT AUTHORIZATION CHAIN FIXTURE: % failed assertion(s) -> %',
      v_fail, replace(v_lines, E'\n', '');
  end if;

  raise notice 'SUPPORT AUTHORIZATION CHAIN FIXTURE: all assertions passed (fixture rolled back)';
end
$test$;

select orden, resultado, prueba from t_support_chain_results order by orden;

drop table if exists t_support_chain_results;

rollback;
