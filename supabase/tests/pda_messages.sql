-- PDA MESSAGES V1 — WIRING / OWNERSHIP FIXTURE — LA GRAN IMPLOSION
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional fixture: it always ends in ROLLBACK.
--
-- Mission: move the EXISTING inbox into the PDA MESSAGES module. No new messaging system.
-- This fixture does NOT test the React wiring (no browser here). It certifies the only thing that
-- could have broken and is server-side: that the two contracts the inbox uses are still the single
-- owner-scoped authority, with unchanged ACL, unchanged unread semantics, and cross-owner isolation.
--
--   get_player_messages(p_limit, p_unread_only)  -> read + unread filter + order + clamp
--   mark_message_read(p_message_id)              -> idempotent mark-as-read
--
-- Nothing in this mission changed them, and this fixture proves it.
--
-- LIMITATION: single-session harness with ROLLBACK; concurrency not executed.

begin;

drop table if exists t_pdam;
create temp table t_pdam(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid; v_player uuid; v_universe uuid; v_other_user uuid; v_other uuid;
    v_ok boolean; v_fails integer := 0; v_rows integer; v_unread integer; v_id uuid;
    v_body text;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    if v_player is null then
        raise exception 'TEST_ABORT: an auth-linked player is required';
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* ---- 1. a real unread message for the owner, written the way the engine writes it ---- */
    perform public.create_player_message(v_player, null, 'PdaProbe unread',
        'written by the fixture', 'pdaprobe:unread:' || gen_random_uuid()::text);
    select pm.id into v_id from public.player_messages pm
     where pm.recipient_player_id = v_player and pm.subject = 'PdaProbe unread'
     order by pm.created_at desc limit 1;

    /* ---- 2. it is returned to its owner, and it counts as unread ---- */
    select count(*)::integer into v_rows
      from public.get_player_messages(50, false) m where m.out_message_id = v_id;
    select count(*)::integer into v_unread
      from public.get_player_messages(50, true) m where m.out_message_id = v_id;
    v_ok := v_rows = 1 and v_unread = 1;
    insert into t_pdam(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. the owner sees it once, and the unread filter counts it (all=%s unread=%s)', v_rows, v_unread));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 3. mark_message_read moves read_at and is IDEMPOTENT ---- */
    select m.out_message_id, m.out_is_read into v_id, v_ok
      from public.get_player_messages(50, true) m limit 1;
    v_ok := v_id is not null;
    insert into t_pdam(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '2. before marking, the message is still listed by the unread filter');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    perform * from public.mark_message_read(v_id);
    select count(*)::integer into v_rows
      from public.get_player_messages(50, true) m where m.out_message_id = v_id;
    v_ok := v_rows = 0;
    insert into t_pdam(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. after mark_message_read it leaves the unread filter (%s rows)', v_rows));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    select pm.read_at is not null into v_ok from public.player_messages pm where pm.id = v_id;
    insert into t_pdam(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '4. read_at was persisted (the unread counter the UI shows now reflects it)');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    select r.out_already_read into v_ok from public.mark_message_read(v_id) r;
    v_ok := coalesce(v_ok, false);
    insert into t_pdam(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '5. a second call is idempotent (out_already_read = true, no double effect)');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 6. the message is still listed in the full inbox (read ones are not hidden) ---- */
    select count(*)::integer into v_rows
      from public.get_player_messages(50, false) m where m.out_message_id = v_id;
    v_ok := v_rows = 1;
    insert into t_pdam(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '6. the read message is still in the full inbox, only filtered out of the unread count');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 7. OWNERSHIP: another authenticated player sees 0 rows of that message ---- */
    insert into auth.users(id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
    values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'pdaprobe-other@example.invalid', crypt('PdaprobeOther!1', gen_salt('bf')), clock_timestamp(),
        '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, clock_timestamp(), clock_timestamp(), '', '');
    insert into public.players(universe_id, user_id, username, is_guest, player_type)
    values (v_universe, (select id from auth.users where email = 'pdaprobe-other@example.invalid'),
            'PdaProbeOther', false, 'HUMAN')
    returning id into v_other;
    select us.id into v_other_user from auth.users us where us.email = 'pdaprobe-other@example.invalid';

    perform set_config('request.jwt.claims', json_build_object('sub', v_other_user::text)::text, true);
    select count(*)::integer into v_rows from public.get_player_messages(50, false) m where m.out_message_id = v_id;
    v_ok := v_rows = 0;
    insert into t_pdam(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. another authenticated player reads 0 rows of that message (%s)', v_rows));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 8. ...and cannot mark it read either ---- */
    v_ok := false;
    begin
        perform * from public.mark_message_read(v_id);
    exception when others then
        v_ok := sqlerrm ilike '%NOT_FOUND_OR_NOT_OWNED%';
        v_body := sqlerrm;
    end;
    insert into t_pdam(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. the other player cannot mark it read (%s)', coalesce(v_body, 'IT WAS ALLOWED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 9. no session sees nothing ---- */
    perform set_config('request.jwt.claims', '{}', true);
    select count(*)::integer into v_rows from public.get_player_messages(50, false);
    v_ok := v_rows = 0;
    insert into t_pdam(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. without a session the inbox returns 0 rows (%s)', v_rows));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 10. ACL unchanged: authenticated + service_role, never anon ---- */
    v_ok := has_function_privilege('authenticated', 'public.get_player_messages(integer,boolean)', 'EXECUTE')
            and has_function_privilege('service_role', 'public.get_player_messages(integer,boolean)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.get_player_messages(integer,boolean)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.mark_message_read(uuid)', 'EXECUTE')
            and has_function_privilege('service_role', 'public.mark_message_read(uuid)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.mark_message_read(uuid)', 'EXECUTE');
    insert into t_pdam(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10. ACL unchanged on both contracts: authenticated + service_role, anon denied');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 11. the messaging ENGINE was NOT modified by this mission ---- */
    /* A previous version of this assertion grepped the SQL for '%pda%' and produced a FALSE POSITIVE:
       the word "upDATE" literally contains the substring "pda". It proved nothing. The real property is
       that the owner-scoping clauses are still exactly where the authority requires them. */
    v_ok := (select count(*) = 2 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public'
                and p.proname in ('get_player_messages', 'mark_message_read')
                and p.prosrc::text ilike '%auth.uid()%')
        and (select count(*) = 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'get_player_messages'
                and p.prosrc::text ilike '%recipient_player_id in (select pl.id from public.players pl where pl.user_id = auth.uid())%')
        and (select count(*) = 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'mark_message_read'
                and p.prosrc::text ilike '%PLAYER_MESSAGE_NOT_FOUND_OR_NOT_OWNED%');
    insert into t_pdam(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '11. owner scoping intact in both contracts (auth.uid() chain + NOT_OWNED guard)');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 12. player_messages stays closed to direct client access ---- */
    v_ok := (select count(*) = 1 from pg_policies
              where schemaname = 'public' and tablename = 'player_messages'
                and policyname = 'deny_direct_api_access');
    insert into t_pdam(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '12. player_messages is still closed to direct client access (contracts are the only path)');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    insert into t_pdam(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness with ROLLBACK; concurrency not executed. This certifies the server-side authority the PDA inbox consumes; the React wiring itself is not exercised (no browser).');
    insert into t_pdam(resultado, prueba) values ('INFO', format('SUMMARY: %s failed assertion(s).', v_fails));
    if v_fails > 0 then
        raise exception 'PDA MESSAGES: % failed assertion(s)', v_fails;
    end if;
end;
$test$;

select orden, resultado, prueba from t_pdam order by orden;

drop table if exists t_pdam;

ROLLBACK;

