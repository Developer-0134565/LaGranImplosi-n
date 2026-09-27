-- FLEET SLOTS ENFORCEMENT FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
-- Contract (migration 20260926121000_fleet_slots_enforcement): every fleet_movements insert (i.e. every dispatch
-- path) is capped by 1 + computer_technology; a rejection is atomic; COMPLETED/CANCELLED release the slot; an
-- identical idempotent retry is exempt from the cap so the partial unique index can answer it; the helper is
-- internal. LIMITATION: single-session harness, real concurrency not executed.

begin;

drop table if exists t_slots_enforce;
create temp table t_slots_enforce(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_planet uuid; v_auth uuid;
    v_first uuid; v_second uuid; v_third uuid; v_later uuid;
    v_ok boolean; v_fail integer := 0; v_rows integer; v_raised text; v_unique boolean := false;
begin
    select pl.id into v_player from public.players pl
     where pl.user_id is not null order by pl.created_at, pl.id limit 1;

    select p.id into v_planet from public.planets p
     where p.player_id = v_player and not p.is_destroyed order by p.created_at limit 1;

    if v_player is null or v_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet is required';
    end if;

    /* The ownership guard on fleet_movements requires a session: impersonate the fixture player. */
    select pl.user_id into v_auth from public.players pl where pl.id = v_player;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    update public.fleet_movements set status = 'COMPLETED'
     where player_id = v_player and status not in ('COMPLETED', 'CANCELLED');

    insert into public.player_research(player_id, research_id, level)
    values (v_player, 'computer_technology', 1)
    on conflict (player_id, research_id) do update set level = excluded.level;

    /* 1. cap = 1 + level */
    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at, status)
    values (v_player, v_planet, 'TRANSPORT', clock_timestamp(), clock_timestamp() + interval '1 hour', 'OUTBOUND')
    returning id into v_first;

    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at, status)
    values (v_player, v_planet, 'TRANSPORT', clock_timestamp(), clock_timestamp() + interval '1 hour', 'OUTBOUND')
    returning id into v_second;

    v_ok := v_first is not null and v_second is not null
            and public.calculate_player_fleet_slots_in_use(v_player) = 2;
    insert into t_slots_enforce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '1. computer_technology 1 accepts exactly two live missions (1 + 1)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 2. the third is refused, atomically */
    begin
        insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at, status)
        values (v_player, v_planet, 'ESPIONAGE', clock_timestamp(), clock_timestamp() + interval '1 hour', 'OUTBOUND')
        returning id into v_third;
    exception when others then
        v_raised := sqlerrm;
    end;

    select count(*)::integer into v_rows from public.fleet_movements fm
     where fm.player_id = v_player and fm.status not in ('COMPLETED', 'CANCELLED');

    v_ok := v_raised like 'FLEET_SLOTS_FULL%' and v_rows = 2 and v_third is null;
    insert into t_slots_enforce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. third mission refused (%s), nothing written (live: %s)', coalesce(v_raised, 'no error'), v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 3. raising the research raises the cap */
    update public.player_research set level = 3
     where player_id = v_player and research_id = 'computer_technology';

    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at, status)
    values (v_player, v_planet, 'ESPIONAGE', clock_timestamp(), clock_timestamp() + interval '1 hour', 'OUTBOUND')
    returning id into v_third;

    v_ok := v_third is not null and public.calculate_player_fleet_slots_in_use(v_player) = 3
            and public.calculate_player_max_fleet_slots(v_player) = 4;
    insert into t_slots_enforce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '3. computer_technology 3 (4 slots) accepts the third mission');
    v_fail := v_fail + case when v_ok then 0 else 1 end;


    /* 4. dead missions free their slot */
    update public.fleet_movements set status = 'COMPLETED' where id = v_first;
    update public.fleet_movements set status = 'CANCELLED' where id = v_second;

    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at, status)
    values (v_player, v_planet, 'RECYCLE', clock_timestamp(), clock_timestamp() + interval '1 hour', 'OUTBOUND')
    returning id into v_later;

    v_ok := v_later is not null and public.calculate_player_fleet_slots_in_use(v_player) = 2;
    insert into t_slots_enforce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '4. COMPLETED and CANCELLED release their slot');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 5. a duplicated idempotency key is not reported as a slot error */
    update public.fleet_movements set status = 'COMPLETED' where player_id = v_player;
    update public.player_research set level = 1
     where player_id = v_player and research_id = 'computer_technology';

    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at, status, idempotency_key)
    values (v_player, v_planet, 'TRANSPORT', clock_timestamp(), clock_timestamp() + interval '1 hour', 'OUTBOUND',
            '11111111-2222-3333-4444-555555555555'::uuid)
    returning id into v_later;

    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at, status)
    values (v_player, v_planet, 'TRANSPORT', clock_timestamp(), clock_timestamp() + interval '1 hour', 'OUTBOUND');

    v_raised := null;
    begin
        insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at, status, idempotency_key)
        values (v_player, v_planet, 'TRANSPORT', clock_timestamp(), clock_timestamp() + interval '1 hour', 'OUTBOUND',
                '11111111-2222-3333-4444-555555555555'::uuid);
    exception when unique_violation then
        v_unique := true;
    when others then
        v_raised := sqlerrm;
    end;

    v_ok := v_unique and v_raised is null;
    insert into t_slots_enforce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. duplicated idempotency key exempt from the cap (unique_violation=%s, other error=%s)',
             v_unique, coalesce(v_raised, 'none')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 6. ACL */
    v_ok := not has_function_privilege('authenticated', 'public.assert_player_fleet_slot_available(uuid)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.assert_player_fleet_slot_available(uuid)', 'EXECUTE');
    insert into t_slots_enforce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '6. ACL: the slot helper is not client-executable');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_slots_enforce(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; the concurrent case (two identical dispatches at once) is not executed.');

    if v_fail > 0 then
        raise exception 'FLEET SLOTS ENFORCEMENT FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_slots_enforce order by orden;

drop table if exists t_slots_enforce;

ROLLBACK;
