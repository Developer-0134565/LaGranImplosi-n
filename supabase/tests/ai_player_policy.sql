-- AI POLICY FIXTURE — LA GRAN IMPLOSIÓN
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- SUPERSESSION NOTE (2026-09-26): this file originally certified the FIRST-CUT policy of
-- `20260926220000_ai_player_policy.sql` (fixed priority: energy -> lowest mine -> research list -> colony,
-- one action per tick). The owner-approved `20260926291000_ai_behaviour_policy.sql` replaced that policy
-- with the full gameplay policy (personalities, daily activity windows, cooldowns, espionage, probabilistic
-- attacks, colonisation), so every behaviour assertion moved to `supabase/tests/ai_behaviour_policy.sql`
-- (20/20 PASS LIVE). Keeping the old priority assertions here would certify a policy that no longer exists,
-- so this file now certifies only the POLICY-INDEPENDENT contract surface of the AI subsystem:
--
--   1. an invalid budget is refused whatever the policy is
--   2. the budget rule never lets the AI spend beyond its means (1 unit of each resource -> nothing queued)
--   3. the declared AI actor only accepts AI players
--   4. the worker returns one row per AI player, isolates failures and clears the actor
--   5. ACL: the AI surface (functions and profile tables) is service_role only
--   6. the pg_cron tick exists and calls the worker
--
-- LIMITATION: single-session harness like every other fixture of this repository; the cron tick is asserted
-- statically (its execution is what the LIVE policy run depends on).

begin;

drop table if exists t_ai;
create temp table t_ai(orden serial, resultado text, prueba text);

do $test$
declare
    v_ai uuid; v_planet uuid; v_human uuid;
    v_ok boolean; v_fail integer := 0; v_raised text; v_decision record; v_rows integer;
    v_own text; v_queue integer; v_movements integer; v_active timestamptz;
begin
    select pl.id, p.id into v_ai, v_planet
      from public.players pl
      join public.planets p on p.player_id = pl.id and p.kind = 'PLANET' and p.is_destroyed = false
      join public.universes u on u.id = pl.universe_id and u.is_active
     where pl.player_type = 'AI' and pl.user_id is null
     order by pl.created_at, p.created_at
     limit 1;

    select pl.id into v_human from public.players pl where pl.user_id is not null order by pl.created_at limit 1;

    if v_ai is null or v_planet is null then
        raise exception 'TEST_ABORT: an AI player with a planet in an active universe is required';
    end if;

    /* an instant inside this AI's own deterministic activity window, so the policy is allowed to decide */
    select ((now() at time zone 'utc')::date::timestamp
            + make_interval(mins => (select w.start_minute from public.ai_daily_activity(v_ai, (now() at time zone 'utc')::date) w
                                      order by w.window_index limit 1) + 1)) at time zone 'utc'
      into v_active;

    delete from public.building_queue where planet_id = v_planet;
    delete from public.research_queue where planet_id = v_planet;
    delete from public.planet_ships where planet_id = v_planet;

    /* NEW (2026-09-26): AI players are DORMANT by default (20260926295000), and a DORMANT AI never runs the
       policy. This fixture certifies the policy-independent contract surface, so the tested AI is explicitly
       activated; the DORMANT behaviour has its own fixture (ai_bootstrap_and_dormant.sql). */
    insert into public.ai_player_profiles (player_id, personality, status)
    values (v_ai, 'INDUSTRIAL', 'ACTIVE')
    on conflict (player_id) do update set status = 'ACTIVE';

    perform set_config('request.jwt.claims', '{}', true);

    /* 1. invalid budget refused whatever the policy is */
    v_raised := null;
    begin
        perform public.ai_decide_and_act(v_ai, 0);
    exception when others then v_raised := sqlerrm; end;
    v_ok := v_raised like 'AI_BUDGET_INVALID%';

    v_raised := null;
    begin
        perform public.ai_decide_and_act(v_ai, 101);
    exception when others then v_raised := sqlerrm; end;
    v_ok := v_ok and v_raised like 'AI_BUDGET_INVALID%';
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. budgets 0 and 101 refused (%s)', coalesce(v_raised, 'accepted')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 2. budget rule: with a single unit of each resource nothing is affordable and nothing is queued */
    update public.planet_resources set metal = 1, crystal = 1, deuterium = 1, last_calculated_at = now()
     where planet_id = v_planet;

    perform public.ai_actor_begin(v_ai);
    select * into v_decision from public.ai_decide_and_act(v_ai, 60, v_active);
    perform public.ai_actor_end();

    select count(*) into v_queue from public.building_queue where planet_id = v_planet;
    select count(*) into v_rows from public.research_queue where planet_id = v_planet;
    select count(*) into v_movements from public.fleet_movements
     where player_id = v_ai and created_at > now() - interval '1 minute';

    v_ok := (v_decision.action = 'none' or v_decision.action = 'idle')
            and coalesce(v_decision.result, '') not like 'AI_ERROR%'
            and v_queue = 0 and v_rows = 0 and v_movements = 0;
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. budget rule keeps it idle with one unit of each resource (%s: %s, queues %s/%s, movements %s)',
             v_decision.action, v_decision.result, v_queue, v_rows, v_movements));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 3. the declared AI actor only accepts AI players */
    v_raised := null;
    if v_human is not null then
        begin
            perform public.ai_actor_begin(v_human);
        exception when others then v_raised := sqlerrm; end;
    end if;
    v_ok := (v_human is null) or v_raised like 'AI_ACTOR_TARGET_NOT_AI%';
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. ai_actor_begin refuses a human player (%s)', coalesce(v_raised, 'accepted')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 4. worker: one row per AI player, failures isolated, declared actor cleared */
    select count(*) into v_rows from public.run_ai_policy_worker(25, 60, v_active);
    select w.out_result into v_own from public.run_ai_policy_worker(25, 60, v_active) w
     where w.out_player_id = v_ai limit 1;
    v_ok := v_rows >= 1 and v_own is not null and v_own not like 'AI_ERROR%'
            and coalesce(current_setting('lgi.ai_player', true), '') = '';
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. worker processed %s AI player(s); tested player [%s]', v_rows, coalesce(v_own, 'not in batch')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 5. ACL: the AI surface (functions and profile tables) is service_role only */
    v_ok := has_function_privilege('service_role', 'public.ai_decide_and_act(uuid,numeric,timestamp with time zone)', 'EXECUTE')
            and has_function_privilege('service_role', 'public.run_ai_policy_worker(integer,numeric,timestamp with time zone)', 'EXECUTE')
            and not has_function_privilege('authenticated', 'public.ai_decide_and_act(uuid,numeric,timestamp with time zone)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.run_ai_policy_worker(integer,numeric,timestamp with time zone)', 'EXECUTE')
            and has_table_privilege('service_role', 'public.ai_player_profiles', 'SELECT')
            and not has_table_privilege('anon', 'public.ai_player_profiles', 'SELECT')
            and not has_table_privilege('authenticated', 'public.ai_planet_profiles', 'SELECT');
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '5. ACL: AI functions and profile tables are service_role only');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 6. cron tick */
    v_ok := exists (select 1 from cron.job j where j.jobname = 'lagranimplosion-ai-policy'
                     and j.schedule = '*/5 * * * *' and j.command like '%run_ai_policy_worker%');
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '6. pg_cron lagranimplosion-ai-policy every 5 minutes calls the worker');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_ai(resultado, prueba) values ('INFO',
      'Behaviour coverage (personality, daily windows, cooldowns, espionage, attack policy, colonisation) lives in supabase/tests/ai_behaviour_policy.sql.');

    if v_fail > 0 then
        raise exception 'AI POLICY FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_ai order by orden;

drop table if exists t_ai;

ROLLBACK;