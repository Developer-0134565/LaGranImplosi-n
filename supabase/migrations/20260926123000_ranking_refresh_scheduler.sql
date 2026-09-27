-- RANKING — periodic refresh (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- `README_RANKING.md` §7 recorded the only remaining gap of the ranking contract: "NO cron/job calls the
-- recalculation". Product decision of the GAMEPLAY COMPLETION SWEEP: the refresh is scheduled.
--
-- Cadence: OGameX refreshes highscores every 5 minutes (`routes/console.php` schedules
-- `GenerateHighscores`/`GenerateHighscoreRanks`, @ 7c420bad) — the same cadence is adopted here, so no arbitrary
-- constant is invented.
--
-- Infrastructure: the EXISTING pg_cron job list is used (no parallel scheduler): the job runs
-- `public.run_ranking_worker()`, which iterates the ACTIVE universes and calls the certified, idempotent
-- `recalculate_universe_ranking(universe)` once per universe. Recalculation is a pure function of the current
-- assets, so a repeated or overlapping run can never accumulate points, and the worker only writes
-- `players.points` / `players.rank`.
--
-- Consumer unlocked: `get_universe_top1_points` → `calculate_expedition_resource_cap` no longer resolves the
-- lowest bracket once the refresh has run (verified by the ranking fixture).
--
-- Certified by `supabase/tests/ranking_refresh_worker.sql`.
begin;

create or replace function public.run_ranking_worker()
returns table(out_universe_id uuid, out_players_ranked integer)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_universe record;
    v_ranked integer;
begin
    for v_universe in
        select u.id
        from public.universes u
        where u.is_active
        order by u.id
    loop
        v_ranked := public.recalculate_universe_ranking(v_universe.id);

        out_universe_id := v_universe.id;
        out_players_ranked := coalesce(v_ranked, 0);
        return next;
    end loop;
end;
$function$;

comment on function public.run_ranking_worker() is
$c$Scheduler entry point: recalculates points and rank for every ACTIVE universe through the certified, idempotent
`recalculate_universe_ranking`. Scheduled by pg_cron every 5 minutes (OGameX `GenerateHighscores` cadence). Idempotent
and safe to replay: it is a pure function of the current assets and writes only players.points / players.rank.$c$;

revoke all on function public.run_ranking_worker() from public, anon, authenticated;
grant execute on function public.run_ranking_worker() to service_role;

-- --------------------------------------------------------------------------- schedule (idempotent)
do $do$
begin
    if exists (select 1 from cron.job where jobname = 'lagranimplosion-ranking-refresh') then
        perform cron.unschedule('lagranimplosion-ranking-refresh');
    end if;
end
$do$;

select cron.schedule(
    'lagranimplosion-ranking-refresh',
    '*/5 * * * *',
    $cron$select public.run_ranking_worker();$cron$
);

commit;
