-- FLEET RECALL FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
-- Contract (migration 20260926122000_fleet_recall_contract): recall_fleet(p_player_id, p_fleet_id) is owner-gated,
-- atomic and replay-safe; an OUTBOUND fleet returns with a return leg equal to the time already flown; a HOLDING
-- fleet returns with the full outbound duration; the cargo and the composition are preserved exactly; the recall is
-- refused once the fleet arrived or already returns; the transition is the canonical RETURNING one and produces the
-- "Fleet returning" message. LIMITATION: single-session harness, real concurrency not executed.

begin;

drop table if exists t_recall;
create temp table t_recall(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_planet uuid; v_auth uuid; v_other uuid;
    v_fleet uuid; v_holding uuid; v_late uuid; v_now timestamptz; v_ret timestamptz;
    v_status text; v_seconds integer; v_m numeric; v_c numeric; v_d numeric; v_ships jsonb;
    v_ok boolean; v_fail integer := 0; v_raised text; v_msg integer;
begin
    select pl.id, pl.user_id into v_player, v_auth from public.players pl
     where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_planet from public.planets p
     where p.player_id = v_player and not p.is_destroyed order by p.created_at limit 1;
    select pl.id into v_other from public.players pl where pl.id <> v_player order by pl.created_at limit 1;

    if v_player is null or v_planet is null or v_other is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet and a second player are required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    insert into public.player_research(player_id, research_id, level)
    values (v_player, 'computer_technology', 5)
    on conflict (player_id, research_id) do update set level = excluded.level;

    delete from public.player_messages where recipient_player_id = v_player and dedupe_key is not null;

    /* 1. OUTBOUND recall = mirror leg, cargo and composition preserved */
    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at,
        status, metal, crystal, deuterium, destination_galaxy, destination_system, destination_position)
    values (v_player, v_planet, 'TRANSPORT', clock_timestamp() - interval '10 minutes',
        clock_timestamp() + interval '50 minutes', 'OUTBOUND', 1234, 4321, 99, 1, 1, 2)
    returning id into v_fleet;

    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity)
    values (v_fleet, 'small_cargo', 7);

    v_now := clock_timestamp();
    select r.out_status, r.out_returns_at, r.out_cargo_metal, r.out_cargo_crystal, r.out_cargo_deuterium, r.out_ships
      into v_status, v_ret, v_m, v_c, v_d, v_ships
      from public.recall_fleet(v_player, v_fleet) r;

    v_ok := v_status = 'RETURNING'
            and abs(extract(epoch from (v_ret - (v_now + interval '10 minutes')))) < 120
            and v_m = 1234 and v_c = 4321 and v_d = 99
            and v_ships = '{"small_cargo": 7}'::jsonb;
    insert into t_recall(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. recall mirrors the flown leg: status %s, cargo %s/%s/%s, ships %s', v_status, v_m, v_c, v_d, v_ships));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 2. replay cannot return the fleet twice */
    v_raised := null;
    begin
        perform public.recall_fleet(v_player, v_fleet);
    exception when others then
        v_raised := sqlerrm;
    end;

    v_ok := v_raised like 'FLEET_NOT_RECALLABLE%';
    insert into t_recall(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. a second recall is refused (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 3. the recall produced the fleet-returning message (messaging engine) */
    select count(*)::integer into v_msg from public.player_messages pm
     where pm.recipient_player_id = v_player and pm.dedupe_key = 'fleet_returning:' || v_fleet::text;
    v_ok := v_msg = 1;
    insert into t_recall(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. the fleet owner was notified with the outbox message (%s row)', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;


    /* 4. an arrived fleet cannot be recalled */
    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at, status)
    values (v_player, v_planet, 'TRANSPORT', clock_timestamp() - interval '2 hours',
        clock_timestamp() - interval '1 hour', 'OUTBOUND')
    returning id into v_late;

    v_raised := null;
    begin
        perform public.recall_fleet(v_player, v_late);
    exception when others then
        v_raised := sqlerrm;
    end;

    select fm.status into v_status from public.fleet_movements fm where fm.id = v_late;
    v_ok := v_raised like 'FLEET_RECALL_TOO_LATE%' and v_status = 'OUTBOUND';
    insert into t_recall(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. an overdue fleet is not recallable (%s, status untouched: %s)', coalesce(v_raised, 'no error'), v_status));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 5. HOLDING recall = full outbound duration */
    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at,
        status, holding_until, destination_galaxy, destination_system, destination_position)
    values (v_player, v_planet, 'ACS_HOLD', clock_timestamp() - interval '30 minutes',
        clock_timestamp() - interval '5 minutes', 'HOLDING', clock_timestamp() + interval '30 minutes', 1, 1, 2)
    returning id into v_holding;

    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity)
    values (v_holding, 'large_cargo', 3);

    v_now := clock_timestamp();
    select r.out_status, r.out_returns_at, r.out_seconds_remaining
      into v_status, v_ret, v_seconds
      from public.recall_fleet(v_player, v_holding) r;

    v_ok := v_status = 'RETURNING'
            and abs(extract(epoch from (v_ret - (v_now + interval '25 minutes')))) < 120
            and v_seconds between 1400 and 1600;
    insert into t_recall(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. a holding fleet returns with the full outbound leg (%s s remaining)', v_seconds));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 6. ownership */
    v_raised := null;
    begin
        perform public.recall_fleet(v_other, v_holding);
    exception when others then
        v_raised := sqlerrm;
    end;

    select fm.status into v_status from public.fleet_movements fm where fm.id = v_holding;
    v_ok := v_raised like 'FLEET_NOT_OWNED%' and v_status = 'RETURNING';
    insert into t_recall(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. another owner cannot recall the fleet (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 7. ACL */
    v_ok := has_function_privilege('authenticated', 'public.recall_fleet(uuid, uuid)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.recall_fleet(uuid, uuid)', 'EXECUTE');
    insert into t_recall(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '7. ACL: authenticated only, never anon');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_recall(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; the concurrent case (two recalls at once) is not executed.');

    if v_fail > 0 then
        raise exception 'FLEET RECALL FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_recall order by orden;

drop table if exists t_recall;

ROLLBACK;
