-- BEGINNER PROTECTION VISIBILITY CONTRACT FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional fixture: it always ends in ROLLBACK.
--
-- Contract under test (20260928210000): `get_my_attack_protection()` — the ONLY client read path for the
-- caller's OWN beginner-protection state.
--
-- Gap closed 2026-09-28: beginner protection is a real ENFORCED rule (an ATTACK against an empire inside
-- its first 24 h raises TARGET_BEGINNER_PROTECTED), but the player could not SEE it: the only place the
-- rule surfaced was the raw exception text of a failed attack, and the internal helper that answers the
-- question is `service_role` only.
--
-- The fixture proves: the contract returns MY state, never anybody else's; it never re-implements the
-- rule (it agrees with the authority the trigger uses); it is read-only; and the internal helper was
-- NOT opened in the process.
--
-- LIMITATION: single-session harness with ROLLBACK; concurrency not executed.

begin;

drop table if exists t_mbp;
create temp table t_mbp(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid; v_player uuid; v_new_player uuid; v_new_user uuid; v_far_player uuid; v_far_user uuid;
    v_universe uuid; v_ok boolean; v_fails integer := 0; v_rows integer;
    v_row record; v_authority record;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    if v_player is null then
        raise exception 'TEST_ABORT: an auth-linked player is required';
    end if;

    /* a brand-new empire inside the 24 h window, and a second auth user far outside it */
    insert into public.players(universe_id, user_id, username, is_guest, player_type, created_at)
    values (v_universe, null, 'MbpNew', false, 'HUMAN', now()) returning id into v_new_player;
    insert into public.players(universe_id, user_id, username, is_guest, player_type, created_at)
    values (v_universe, null, 'MbpOld', false, 'HUMAN', now() - interval '10 days') returning id into v_far_player;

    insert into auth.users(id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
    values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'mbpnew@example.invalid', crypt('Mbpnew!1', gen_salt('bf')), clock_timestamp(),
        '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, clock_timestamp(), clock_timestamp(), '', '')
    returning id into v_new_user;
    update public.players set user_id = v_new_user, created_at = now() - interval '1 hour' where id = v_new_player;

    /* 1. a fresh empire is PROTECTED and the window ends within 24 h */
    perform set_config('request.jwt.claims', json_build_object('sub', v_new_user)::text, true);
    select * into v_row from public.get_my_attack_protection();
    v_ok := v_row.out_protected
            and v_row.out_protected_until is not null
            and v_row.out_protected_until > now()
            and v_row.out_protected_until <= now() + interval '24 hours';
    insert into t_mbp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. a fresh empire reads PROTECTED until %s (reason %s)', v_row.out_protected_until, v_row.out_reason));
    v_fails := v_fails + case when v_ok then 0 else 1 end;


    /* 3. an empire outside the window is NOT protected */
    insert into auth.users(id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
    values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'mbpold@example.invalid', crypt('Mbpold!1', gen_salt('bf')), clock_timestamp(),
        '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, clock_timestamp(), clock_timestamp(), '', '')
    returning id into v_far_user;
    update public.players set user_id = v_far_user where id = v_far_player;
    perform set_config('request.jwt.claims', json_build_object('sub', v_far_user)::text, true);
    select * into v_row from public.get_my_attack_protection();
    v_ok := not v_row.out_protected and v_row.out_reason = 'EXPIRED';
    insert into t_mbp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. an empire outside the window is not protected (reason %s)', v_row.out_reason));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 4. OWNERSHIP: exactly ONE row — my own state — so a second player can never read a list of empires */
    perform set_config('request.jwt.claims', json_build_object('sub', v_new_user)::text, true);
    select count(*)::integer into v_rows from public.get_my_attack_protection();
    v_ok := v_rows = 1;
    insert into t_mbp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. the contract returns exactly ONE row — my own — never a list of players (%s)', v_rows));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 5. no session returns nothing at all (the panel renders nothing in that case) */
    perform set_config('request.jwt.claims', '{}', true);
    select count(*)::integer into v_rows from public.get_my_attack_protection();
    v_ok := v_rows = 0;
    insert into t_mbp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. without a session the contract returns 0 rows (%s)', v_rows));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 6. the contract takes no player selector at all */
    v_ok := (select pg_get_function_arguments(p.oid) = ''
               from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'get_my_attack_protection');
    insert into t_mbp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '6. the contract takes NO arguments: a player selector is impossible');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 7. read-only: the body cannot write */
    v_ok := not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                         where n.nspname = 'public' and p.proname = 'get_my_attack_protection'
                           and (p.prosrc::text ~* '\m(insert|update|delete|truncate)\M'));
    insert into t_mbp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '7. no write path: the body cannot insert/update/delete/truncate');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 8. ACL: authenticated + service_role, never anon; and the internal helper was NOT opened */
    v_ok := has_function_privilege('authenticated', 'public.get_my_attack_protection()', 'EXECUTE')
            and has_function_privilege('service_role', 'public.get_my_attack_protection()', 'EXECUTE')
            and not has_function_privilege('anon', 'public.get_my_attack_protection()', 'EXECUTE')
            and not has_function_privilege('authenticated', 'public.get_player_attack_protection(uuid,timestamp with time zone)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.get_player_attack_protection(uuid,timestamp with time zone)', 'EXECUTE');
    insert into t_mbp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '8. ACL: new contract authenticated+service_role/anon denied; internal helper still service_role only');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    insert into t_mbp(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness with ROLLBACK; concurrency not executed. The assertion is the CONTRACT; the panel is a read-only render of it.');
    insert into t_mbp(resultado, prueba) values ('INFO', format('SUMMARY: %s failed assertion(s).', v_fails));
    if v_fails > 0 then
        raise exception 'BEGINNER PROTECTION VISIBILITY: % failed assertion(s)', v_fails;
    end if;
end;
$test$;

select orden, resultado, prueba from t_mbp order by orden;

drop table if exists t_mbp;

ROLLBACK;

    /* 2. THE CONTRACT DOES NOT RE-IMPLEMENT THE RULE: it agrees exactly with the authority the
          ATTACK trigger calls. This is what stops the UI from ever drifting from enforcement. */
    select * into v_authority from public.get_player_attack_protection(v_new_player);
    v_ok := v_row.out_protected = v_authority.out_protected
            and v_row.out_protected_until = v_authority.out_protected_until
            and v_row.out_reason = v_authority.out_reason;
    insert into t_mbp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '2. the contract returns the SAME answer as the authority used by the ATTACK trigger');
    v_fails := v_fails + case when v_ok then 0 else 1 end;
