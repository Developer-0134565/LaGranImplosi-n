-- =====================================================================
-- MESSAGE / ESPIONAGE RETENTION WORKER — LGI ↔ OGameX (owner-approved 2026-09-26)
-- =====================================================================
-- OGameX reference: app/Console/Commands/Scheduler/DeleteOldMessages.php
--   private const RETENTION_DAYS = 7;
--   deletes every inbox Message older than the window in chunks of 1000 (ChatMessage has no LGI
--   equivalent: the chat subsystem does not exist here) and is driven by the framework scheduler.
--
-- LGI adaptation (documented):
--   * player_messages and espionage_reports are the two "inbox" documents of LGI, so both are purged with the
--     same window, each in batches of 1000 like OGameX.
--   * Deletion is strictly by age (`created_at <= now() - keep_days`), so read and unread documents expire
--     alike — exactly the OGameX rule. Ownership is untouched (the rows are deleted, never rewritten).
--   * Default window = 7 days (the OGameX constant), exposed as a parameter so the product can change it
--     without a schema change.
--   * Scheduled with pg_cron once a day, following the project convention
--     (`lagranimplosion-ranking-refresh` → `select public.run_ranking_worker();`).
-- =====================================================================

create or replace function public.purge_old_player_messages(p_keep_days integer default 7, p_batch integer default 1000)
returns bigint
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_cutoff timestamptz;
    v_deleted bigint := 0;
    v_rows bigint;
begin
    if p_keep_days is null or p_keep_days < 1 then
        raise exception 'RETENTION_WINDOW_INVALID: %', p_keep_days;
    end if;
    if p_batch is null or p_batch < 1 then
        raise exception 'RETENTION_BATCH_INVALID: %', p_batch;
    end if;

    v_cutoff := now() - make_interval(days => p_keep_days);

    loop
        with doomed as (
            select pm.id
            from public.player_messages pm
            where pm.created_at <= v_cutoff
            order by pm.created_at
            limit p_batch
        )
        delete from public.player_messages pm using doomed d where pm.id = d.id;

        get diagnostics v_rows = row_count;
        v_deleted := v_deleted + v_rows;
        exit when v_rows = 0;
    end loop;

    return v_deleted;
end;
$function$;

create or replace function public.purge_old_espionage_reports(p_keep_days integer default 7, p_batch integer default 1000)
returns bigint
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_cutoff timestamptz;
    v_deleted bigint := 0;
    v_rows bigint;
begin
    if p_keep_days is null or p_keep_days < 1 then
        raise exception 'RETENTION_WINDOW_INVALID: %', p_keep_days;
    end if;
    if p_batch is null or p_batch < 1 then
        raise exception 'RETENTION_BATCH_INVALID: %', p_batch;
    end if;

    v_cutoff := now() - make_interval(days => p_keep_days);

    loop
        with doomed as (
            select er.id
            from public.espionage_reports er
            where er.created_at <= v_cutoff
            order by er.created_at
            limit p_batch
        )
        delete from public.espionage_reports er using doomed d where er.id = d.id;

        get diagnostics v_rows = row_count;
        v_deleted := v_deleted + v_rows;
        exit when v_rows = 0;
    end loop;

    return v_deleted;
end;
$function$;

create or replace function public.run_message_retention_worker(p_keep_days integer default 7, p_batch integer default 1000)
returns table(out_messages_deleted bigint, out_reports_deleted bigint)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
    out_messages_deleted := public.purge_old_player_messages(p_keep_days, p_batch);
    out_reports_deleted := public.purge_old_espionage_reports(p_keep_days, p_batch);
    return next;
end;
$function$;

-- ACL: worker contracts are service-role only (the client never triggers retention).
revoke all on function public.purge_old_player_messages(integer, integer) from public;
revoke all on function public.purge_old_espionage_reports(integer, integer) from public;
revoke all on function public.run_message_retention_worker(integer, integer) from public;

grant execute on function public.purge_old_player_messages(integer, integer) to service_role;
grant execute on function public.purge_old_espionage_reports(integer, integer) to service_role;
grant execute on function public.run_message_retention_worker(integer, integer) to service_role;

-- Scheduling (idempotent): daily at 04:00, same convention as the ranking worker.
select cron.unschedule(jobid) from cron.job where jobname = 'lagranimplosion-message-retention';
select cron.schedule(
    'lagranimplosion-message-retention',
    '0 4 * * *',
    'select public.run_message_retention_worker();'
);
