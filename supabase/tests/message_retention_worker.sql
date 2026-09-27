-- MESSAGE / ESPIONAGE RETENTION FIXTURE — LA GRAN IMPLOSIÓN
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
-- Contract (20260926200000_message_retention_worker.sql), OGameX DeleteOldMessages parity:
--   default window 7 days (the OGameX RETENTION_DAYS constant), deletion strictly by created_at in batches
--   of 1000, both inbox documents (player_messages + espionage_reports), idempotent, service-role only,
--   scheduled daily by pg_cron.
-- LIMITATION: single-session harness; cron is asserted statically (the job exists with a daily cadence).

begin;

drop table if exists t_rt;
create temp table t_rt(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_planet uuid;
    v_ok boolean; v_fail integer := 0; v_raised text;
    v_msgs bigint; v_reps bigint; v_msgs_left bigint; v_reps_left bigint; v_args text; v_reports_seeded boolean;

begin
    select pl.id, pl.user_id into v_player, v_auth
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_planet from public.planets p
     where p.player_id = v_player and not p.is_destroyed order by p.created_at limit 1;

    if v_player is null then
        raise exception 'TEST_ABORT: an auth-linked player is required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    delete from public.player_messages where recipient_player_id = v_player or sender_player_id = v_player;
    delete from public.espionage_reports where player_id = v_player;

    select pg_get_function_arguments(p.oid) into v_args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'run_message_retention_worker';
    v_ok := v_args like '%DEFAULT 7%' and v_args like '%DEFAULT 1000%';
    insert into t_rt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. OGameX defaults kept (7 days / batch 1000): %s', v_args));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into public.player_messages(recipient_player_id, subject, body, created_at) values
        (v_player, 'old1', 'b', now() - interval '8 days'),
        (v_player, 'old2', 'b', now() - interval '9 days'),
        (v_player, 'old3', 'b', now() - interval '30 days'),
        (v_player, 'recent1', 'b', now() - interval '2 days'),
        (v_player, 'recent2', 'b', now());

    /* espionage_reports.fleet_id is NOT NULL with a foreign key: the report path is seeded only when the
       player owns a fleet to reference, otherwise the purge is still evaluated (0 rows). */
    v_reports_seeded := false;
    begin
        insert into public.espionage_reports(player_id, target_planet_id, espionage_level, target_espionage_level,
            metal, crystal, deuterium, energy, fleet, defenses, counter_espionage_chance, counter_espionage_triggered,
            probes_sent, probes_lost, fleet_id, created_at)
        select v_player, v_planet, 1, 0, 0, 0, 0, 0, '{}'::jsonb, '{}'::jsonb, 0, false, 1, 0, fm.id, now() - interval '8 days'
          from public.fleet_movements fm where fm.player_id = v_player limit 1;
        v_reports_seeded := found;
    exception when others then
        v_reports_seeded := false;
    end;

    select out_messages_deleted, out_reports_deleted into v_msgs, v_reps
      from public.run_message_retention_worker();
    select count(*) into v_msgs_left from public.player_messages where recipient_player_id = v_player;
    select count(*) into v_reps_left from public.espionage_reports where player_id = v_player;
    v_ok := v_msgs = 3 and v_msgs_left = 2 and ((v_reports_seeded and v_reps = 1 and v_reps_left = 1) or (not v_reports_seeded and v_reps = 0 and v_reps_left = 0));
    insert into t_rt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. old expire, recent survive (msgs %s kept %s; reports %s kept %s)', v_msgs, v_msgs_left, v_reps, v_reps_left));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select out_messages_deleted, out_reports_deleted into v_msgs, v_reps
      from public.run_message_retention_worker();
    v_ok := v_msgs = 0 and v_reps = 0;
    insert into t_rt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2b. second run is a no-op (msgs %s, reports %s)', v_msgs, v_reps));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into public.player_messages(recipient_player_id, subject, body, created_at)
    values (v_player, 'window8', 'b', now() - interval '8 days');
    select public.purge_old_player_messages(30, 1000) into v_msgs;
    select count(*) into v_msgs_left from public.player_messages
     where recipient_player_id = v_player and subject = 'window8';
    v_ok := v_msgs = 0 and v_msgs_left = 1;
    insert into t_rt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. the window is honoured: 30 days keeps 8-day-old rows (deleted %s, kept %s)', v_msgs, v_msgs_left));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into public.player_messages(recipient_player_id, subject, body, created_at)
    select v_player, 'bulk' || g, 'b', now() - interval '10 days' from generate_series(1, 1500) g;
    select public.purge_old_player_messages(7, 1000) into v_msgs;
    select count(*) into v_msgs_left from public.player_messages where recipient_player_id = v_player;
    v_ok := v_msgs = 1501 and v_msgs_left = 2;
    insert into t_rt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. batched purge of 1501 old rows (deleted %s, remaining %s)', v_msgs, v_msgs_left));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_raised := null;
    begin
        perform public.purge_old_player_messages(0, 1000);
    exception when others then v_raised := sqlerrm; end;
    v_ok := v_raised like 'RETENTION_WINDOW_INVALID%';
    insert into t_rt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. window 0 refused (%s)', coalesce(v_raised, 'accepted')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := has_function_privilege('service_role', 'public.run_message_retention_worker(integer,integer)', 'EXECUTE')
            and not has_function_privilege('authenticated', 'public.run_message_retention_worker(integer,integer)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.purge_old_player_messages(integer,integer)', 'EXECUTE')
            and not has_function_privilege('authenticated', 'public.purge_old_espionage_reports(integer,integer)', 'EXECUTE');
    insert into t_rt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '6. ACL: retention contracts are service_role only');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := exists (select 1 from cron.job j
                     where j.jobname = 'lagranimplosion-message-retention'
                       and j.schedule = '0 4 * * *'
                       and j.command like '%run_message_retention_worker%');
    insert into t_rt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '7. pg_cron job lagranimplosion-message-retention scheduled daily at 04:00');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_rt(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; the cron tick is asserted statically. The window is the OGameX default (7 days) and deletion is by age only, so read and unread documents expire alike.');

    if v_fail > 0 then
        raise exception 'MESSAGE RETENTION FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_rt order by orden;

drop table if exists t_rt;

ROLLBACK;