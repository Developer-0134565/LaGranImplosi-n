-- FLEET SLOTS DERIVATION FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract under test (migrations `20260926095953_add_fleet_slots_derivation_contract` +
-- `20260926121000_fleet_slots_enforcement`):
--   * max slots = 1 + computer_technology level (no officer bonus in LGI);
--   * slots in use = the player's missions whose status is neither COMPLETED nor CANCELLED;
--   * available = greatest(0, max - in_use);
--   * `get_player_fleet_slots()` has NO player parameter: the caller's players come from `auth.uid()`;
--   * read-only (fleet rows are untouched) and EXECUTE is client-read-only;
--   * the cap IS enforced on insert (BEFORE INSERT trigger) — certified separately by
--     `supabase/tests/fleet_slots_enforcement.sql`; this fixture keeps the base level high enough (6 → 7 slots)
--     to keep measuring the derivation without tripping the cap.
--
-- LIMITATION: single-session harness; concurrency is not executed.

begin;

drop table if exists t_slots;
create temp table t_slots(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid; v_player uuid; v_planet uuid;
    v_max integer; v_in_use integer; v_avail integer; v_level integer;
    v_status_before text; v_status_after text; v_status_after_count integer; v_rows integer;
    v_ok boolean; v_fail integer := 0;
    v_auth_exec boolean; v_anon_exec boolean;
begin
    select pl.id, pl.user_id into v_player, v_auth
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;

    select p.id into v_planet
      from public.planets p where p.player_id = v_player and not p.is_destroyed order by p.created_at limit 1;

    if v_player is null or v_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet is required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* Deterministic base: computer_technology = 6 (7 slots), and only two live fleets for this player. */
    insert into public.player_research(player_id, research_id, level)
    values (v_player, 'computer_technology', 6)
    on conflict (player_id, research_id) do update set level = excluded.level;

    update public.fleet_movements set status = 'COMPLETED'
     where player_id = v_player and status not in ('COMPLETED', 'CANCELLED');

    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, arrives_at, status)
    values (v_player, v_planet, 'TRANSPORT', now() + interval '1 hour', 'OUTBOUND');

    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, arrives_at, status)
    values (v_player, v_planet, 'RECYCLE', now() + interval '2 hours', 'OUTBOUND');

    /* two dead fleets must not hold a slot */
    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, arrives_at, status)
    values (v_player, v_planet, 'ESPIONAGE', now() + interval '1 hour', 'COMPLETED');

    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, arrives_at, status)
    values (v_player, v_planet, 'ESPIONAGE', now() + interval '1 hour', 'CANCELLED');

    select string_agg(fm.id::text || ':' || fm.status, ',' order by fm.id) into v_status_before
      from public.fleet_movements fm where fm.player_id = v_player;
    select count(*)::integer into v_rows from public.fleet_movements fm
     where fm.player_id = v_player and fm.status = 'CANCELLED';

    v_ok := v_rows = 1;
    insert into t_slots(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('0. fixture base: computer_technology 6, exactly %s cancelled and 2 live missions', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------------------ 1. MAX = 1 + LEVEL */
    v_max := public.calculate_player_max_fleet_slots(v_player);
    select pr.level into v_level from public.player_research pr
     where pr.player_id = v_player and pr.research_id = 'computer_technology';
    v_ok := v_max = 1 + v_level and v_max = 7;
    insert into t_slots(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. max simultaneous fleets = 1 + computer_technology %s = %s', v_level, v_max));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------- 2. IN USE COUNTS ONLY LIVE MISSIONS */
    v_in_use := public.calculate_player_fleet_slots_in_use(v_player);
    v_ok := v_in_use = 2;
    insert into t_slots(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. slots in use = %s (2 live missions; COMPLETED and CANCELLED hold none)', v_in_use));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* -------------------------------------------------- 3. CLIENT CONTRACT + IDENTITY */
    select s.out_max_slots, s.out_slots_in_use, s.out_slots_available, s.out_computer_technology_level
      into v_max, v_in_use, v_avail, v_level
      from public.get_player_fleet_slots() s
     where s.out_player_id = v_player;

    v_ok := v_max = 7 and v_in_use = 2 and v_avail = 5 and v_level = 6;
    insert into t_slots(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. get_player_fleet_slots: level %s, max %s, in use %s, available %s', v_level, v_max, v_in_use, v_avail));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------- 4. AVAILABLE NEVER GOES NEGATIVE */
    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, arrives_at, status)
    values (v_player, v_planet, 'ESPIONAGE', now() + interval '1 hour', 'OUTBOUND'),
           (v_player, v_planet, 'ESPIONAGE', now() + interval '1 hour', 'OUTBOUND'),
           (v_player, v_planet, 'ESPIONAGE', now() + interval '1 hour', 'OUTBOUND');

    select s.out_slots_available, s.out_slots_in_use into v_avail, v_in_use
      from public.get_player_fleet_slots() s where s.out_player_id = v_player;
    v_ok := v_avail = 2 and v_in_use = 5;
    insert into t_slots(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. five live missions inside seven slots: in use %s, available %s', v_in_use, v_avail));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* -------------------------------------------- 5. READ-ONLY: NO FLEET ROW MOVED */
    select count(*)::integer into v_rows from public.fleet_movements fm
     where fm.player_id = v_player and fm.status = 'OUTBOUND';
    select count(*)::integer into v_status_after_count from public.fleet_movements fm
     where fm.player_id = v_player and fm.status = 'CANCELLED';

    v_ok := v_rows = 5 and v_status_after_count = 1;
    insert into t_slots(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. the derivation wrote nothing: %s OUTBOUND and %s CANCELLED rows are untouched', v_rows, v_status_after_count));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* -------------------------------------- 6. UNAUTHENTICATED: NO ROW, NO IDENTITY */
    perform set_config('request.jwt.claims', '{}', true);

    select count(*)::integer into v_rows from public.get_player_fleet_slots() s;
    v_ok := v_rows = 0;
    insert into t_slots(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. without a session the contract returns no player row (%s)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* --------------------------------------------------------------- 7. ACL BOUNDARY */
    select has_function_privilege('authenticated', 'public.get_player_fleet_slots()', 'EXECUTE')
       and not has_function_privilege('authenticated', 'public.calculate_player_max_fleet_slots(uuid)', 'EXECUTE')
       and not has_function_privilege('authenticated', 'public.calculate_player_fleet_slots_in_use(uuid)', 'EXECUTE')
      into v_auth_exec;

    select has_function_privilege('anon', 'public.get_player_fleet_slots()', 'EXECUTE')
      into v_anon_exec;

    v_ok := v_auth_exec and not v_anon_exec;
    insert into t_slots(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. ACL: authenticated read=%s (internal calculators=%s for clients), anon=%s',
             v_auth_exec, not v_auth_exec, v_anon_exec));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_slots(resultado, prueba) values ('INFO',
      'NOTE: the fleet-slot CAP is now ENFORCED server-side on insert (trigger trg_enforce_fleet_slots); the enforcement fixture is supabase/tests/fleet_slots_enforcement.sql. LIMITATION: single-session harness; no concurrency.');

    if v_fail > 0 then
        raise exception 'FLEET SLOTS FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_slots order by orden;

drop table if exists t_slots;

ROLLBACK;

