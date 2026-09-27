-- RANKING REFRESH WORKER FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
-- Contract (migration 20260926123000_ranking_refresh_scheduler): `run_ranking_worker()` refreshes every ACTIVE
-- universe through the certified `recalculate_universe_ranking`, the refresh is idempotent, it is scheduled by
-- pg_cron every 5 minutes (OGameX cadence), it is not client-executable, and it unblocks the expedition resource cap
-- consumer. LIMITATION: single-session harness; the cron execution itself is not simulated.

begin;

drop table if exists t_rank_w;
create temp table t_rank_w(orden serial, resultado text, prueba text);

do $test$
declare
    v_universe uuid; v_players integer; v_rows integer; v_active integer; v_planet uuid;
    v_points bigint; v_rank integer; v_rank2 integer; v_points2 bigint;
    v_top numeric; v_cap numeric; v_floor numeric; v_schedule text;
    v_ok boolean; v_fail integer := 0;
begin
    select u.id into v_universe from public.universes u where u.is_active order by u.created_at limit 1;
    if v_universe is null then
        raise exception 'TEST_ABORT: no active universe';
    end if;

    select count(*)::integer into v_active from public.universes u where u.is_active;

    update public.players set points = 0, rank = null where universe_id = v_universe;

    /* 1. the worker covers every active universe */
    select count(*)::integer, coalesce(sum(w.out_players_ranked), 0)
      into v_rows, v_players
      from public.run_ranking_worker() w;

    v_ok := v_rows = v_active and v_players > 0;
    insert into t_rank_w(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. worker refreshed %s of %s active universes (%s players ranked)', v_rows, v_active, v_players));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 2. points and rank are materialised */
    select count(*)::integer into v_rows from public.players pl
     where pl.universe_id = v_universe and pl.points > 0 and pl.rank is not null;
    v_ok := v_rows > 0;
    insert into t_rank_w(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. %s players now carry points > 0 and a rank', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select pl.points, pl.rank into v_points, v_rank
      from public.players pl where pl.universe_id = v_universe and pl.points > 0
      order by pl.points desc limit 1;

    /* 3. replay: the refresh is idempotent (pure function of the current assets) */
    perform public.run_ranking_worker();

    select pl.points, pl.rank into v_points2, v_rank2
      from public.players pl where pl.universe_id = v_universe and pl.points > 0
      order by pl.points desc limit 1;

    v_ok := v_points2 = v_points and v_rank2 = v_rank;
    insert into t_rank_w(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. a second refresh changes nothing (top: %s points / rank %s)', v_points2, v_rank2));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 4. the expedition resource cap consumer leaves its floor bracket once a real top player exists */
    select p.id into v_planet
      from public.planets p
      join public.players pl on pl.id = p.player_id
     where pl.universe_id = v_universe and not p.is_destroyed
     order by pl.points desc, p.created_at
     limit 1;

    insert into public.planet_buildings(planet_id, building_id, level)
    values (v_planet, 'metal_mine', 40)
    on conflict (planet_id, building_id) do update
        set level = greatest(public.planet_buildings.level, excluded.level);

    perform public.recalculate_universe_ranking(v_universe);

    select public.get_universe_top1_points(v_universe) into v_top;
    select public.calculate_expedition_resource_cap(v_universe) into v_cap;
    select min(c.max_resource_find) into v_floor from public.expedition_resource_caps c;

    v_ok := v_top > 0 and v_cap > coalesce(v_floor, 0);
    insert into t_rank_w(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. top1=%s resolves the expedition cap to %s (floor bracket %s)', v_top, v_cap, v_floor));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 5. the schedule exists and is the OGameX cadence */
    select j.schedule into v_schedule from cron.job j where j.jobname = 'lagranimplosion-ranking-refresh';
    v_ok := v_schedule = '*/5 * * * *' and
            exists (select 1 from cron.job j where j.jobname = 'lagranimplosion-ranking-refresh' and j.active);
    insert into t_rank_w(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. pg_cron job present and active with schedule %s', coalesce(v_schedule, 'MISSING')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 6. ACL */
    v_ok := not has_function_privilege('authenticated', 'public.run_ranking_worker()', 'EXECUTE')
            and not has_function_privilege('anon', 'public.run_ranking_worker()', 'EXECUTE')
            and has_function_privilege('service_role', 'public.run_ranking_worker()', 'EXECUTE')
            and not has_function_privilege('authenticated', 'public.recalculate_universe_ranking(uuid)', 'EXECUTE');
    insert into t_rank_w(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '6. ACL: only the service role can run the refresh; the recalculator stays internal');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_rank_w(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; pg_cron execution itself is not simulated (job presence/schedule asserted).');

    if v_fail > 0 then
        raise exception 'RANKING REFRESH FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_rank_w order by orden;

drop table if exists t_rank_w;

ROLLBACK;
