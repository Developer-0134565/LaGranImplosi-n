-- BUILDING / RESEARCH STUCK-STATE ON A PAST EVENT — 2026-10-01
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- THE DEFECT THIS CERTIFIES
--   `complete_building` and `complete_research` settle the economy AT THE EVENT TIMESTAMP
--   through `update_planet_resources_until_raw`, which deliberately refuses to move a planet's
--   clock BACKWARDS (INVALID_RESOURCE_TIMESTAMP). That guard is correct and is NOT touched.
--
--   Measured before the fix: an overdue research whose planet clock was already past
--   `finishes_at` made `process_planet_tick` raise INVALID_RESOURCE_TIMESTAMP and the
--   research_queue row stayed 'RESEARCHING' FOREVER (identical across 3 retries). Because
--   `process_universe_tick` has no per-planet error isolation, the exception propagated and
--   NO planet in that universe settled on that heartbeat. `complete_research` loops EVERY
--   planet of the player, so ONE advanced planet aborted the loop and the grant for everyone.
--
-- DECISION GATE (determined from the code, not invented)
--   Semantics A -- COMPLETE the overdue queue. `process_planet_tick` selects `finishes_at <= now()`;
--   `complete_building`/`complete_research` have no CANCELLED branch and no DELETE; only the
--   explicit player actions `cancel_building`/`cancel_research` set CANCELLED (with refund).
--   Completing an overdue row is the already-certified, idempotent path.
--
-- CASES
--   1 stale building   2 stale research   3 normal (non-stale) timestamp
--   4 anti-vacuity     5 idempotency      6 multi-planet isolation
--   7 guard intact     8 no extra production
--
-- LIMITATION: sequential, inside ROLLBACK. True concurrency is not executed.

begin;

drop table if exists t_stuck_queue_results;
create temp table t_stuck_queue_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid; v_player uuid; v_home uuid; v_colony uuid; v_univ uuid; v_pos integer;
    v_bq uuid; v_rq uuid; v_now timestamptz := now();
    v_ok boolean; v_fail integer := 0; v_level integer; v_res integer; v_fields integer;
begin
    /* ------------------------------------------------------------------ FIXTURE */
    select pl.id, pl.user_id into v_player, v_auth
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;

    select p.id, p.universe_id into v_home, v_univ
      from public.planets p
     where p.player_id = v_player and not p.is_destroyed
     order by p.created_at, p.id limit 1;

    if v_player is null or v_home is null then
        raise exception 'TEST_ABORT: need one auth-linked player';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    update public.planet_resources set metal = 1000000, crystal = 1000000, deuterium = 1000000
     where planet_id = v_home;
    delete from public.planet_buildings where planet_id = v_home and building_id = 'metal_mine';

    /* ================ 1 + 4a. STALE BUILDING (with anti-vacuity) ================ */
    insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status)
    values (v_home, 'metal_mine', 1, v_now - interval '60 minutes', v_now - interval '50 minutes', 'BUILDING')
    returning id into v_bq;

    -- the ordinary fleet/combat-style settlement: raw anchor, no event walking
    perform public.update_planet_resources_until_raw(v_home, v_now);

    v_ok := (select pr.last_calculated_at > q.finishes_at
               from public.planet_resources pr, public.building_queue q
              where pr.planet_id = v_home and q.id = v_bq);
    insert into t_stuck_queue_results(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       '4a. ANTI-VACUITY: the building clock really IS ahead of finishes_at');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    begin
        perform * from public.process_universe_tick(v_univ);
        v_ok := true;
    exception when others then
        v_ok := false;
        insert into t_stuck_queue_results(resultado, prueba) values
          ('FAIL', format('1. universe tick raised [%] %', sqlstate, sqlerrm));
    end;
    insert into t_stuck_queue_results(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       '1a. THE REGRESSION: a stale BUILDING no longer aborts the universe tick');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select q.status = 'COMPLETED' from public.building_queue q where q.id = v_bq);
    insert into t_stuck_queue_results(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       format('1b. the stale building queue is COMPLETED (status=%s)',
              (select q.status from public.building_queue q where q.id = v_bq)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select coalesce(pb.level, 0) into v_level from public.planet_buildings pb
     where pb.planet_id = v_home and pb.building_id = 'metal_mine';
    v_ok := v_level = 1;
    insert into t_stuck_queue_results(resultado, prueba) values
/* ================ 2 + 4b. STALE RESEARCH (with anti-vacuity) ================ */
    insert into public.research_queue(player_id, research_id, planet_id, target_level, started_at, finishes_at, status)
    values (v_player, 'laser_technology', v_home, 1, v_now - interval '60 minutes', v_now - interval '50 minutes', 'RESEARCHING')
    returning id into v_rq;

    perform public.update_planet_resources_until_raw(v_home, v_now);

    v_ok := (select pr.last_calculated_at > q.finishes_at
               from public.planet_resources pr, public.research_queue q
              where pr.planet_id = v_home and q.id = v_rq);
    insert into t_stuck_queue_results(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       '4b. ANTI-VACUITY: the research clock really IS ahead of finishes_at');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    begin
        perform * from public.process_universe_tick(v_univ);
        v_ok := true;
    exception when others then
        v_ok := false;
        insert into t_stuck_queue_results(resultado, prueba) values
          ('FAIL', format('2. universe tick raised [%] %', sqlstate, sqlerrm));
    end;
    insert into t_stuck_queue_results(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       '2a. THE REGRESSION: a stale RESEARCH no longer aborts the universe tick');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select q.status = 'COMPLETED' from public.research_queue q where q.id = v_rq);
    insert into t_stuck_queue_results(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       format('2b. the stale research queue is COMPLETED (status=%s)',
              (select q.status from public.research_queue q where q.id = v_rq)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select coalesce(pr.level, 0) into v_res from public.player_research pr
     where pr.player_id = v_player and pr.research_id = 'laser_technology';
    v_ok := v_res = 1;
    insert into t_stuck_queue_results(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       format('2c. the research level was actually granted (level=%s)', v_res));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ================ 3. A NORMAL (NON-STALE) TIMESTAMP IS UNTOUCHED ================
       The planet may already own this building in LIVE, so the assertion is "level UNCHANGED",
       not "absent": a future queue must neither complete early nor grant a level. */
    declare v_before integer;
    begin
        select coalesce(pb.level, 0) into v_before from public.planet_buildings pb
         where pb.planet_id = v_home and pb.building_id = 'crystal_mine';
    insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status)
perform * from public.process_planet_tick(v_home);

        v_ok := (select count(*) = 1 from public.building_queue q
                  where q.building_id = 'crystal_mine' and q.status = 'BUILDING');
        insert into t_stuck_queue_results(resultado, prueba) values
          (case when v_ok then 'PASS' else 'FAIL' end,
           '3a. a FUTURE queue is left BUILDING and is NOT completed early');
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        select coalesce(pb.level, 0) into v_level from public.planet_buildings pb
         where pb.planet_id = v_home and pb.building_id = 'crystal_mine';
        v_ok := v_level = v_before;
        insert into t_stuck_queue_results(resultado, prueba) values
          (case when v_ok then 'PASS' else 'FAIL' end,
           format('3b. a FUTURE queue granted NO level (%s -> %s; normal timing intact)',
                  v_before, v_level));
        v_fail := v_fail + case when v_ok then 0 else 1 end;
    end;
    values (v_home, 'crystal_mine', 1, now(), now() + interval '1 minute', 'BUILDING');

/* ================ 5. IDEMPOTENCY ================ */
    select p.fields_used into v_fields from public.planets p where p.id = v_home;

    perform public.complete_building(v_bq);    -- already COMPLETED
    perform public.complete_research(v_rq);    -- already COMPLETED
    perform * from public.process_universe_tick(v_univ);

    select coalesce(pb.level, 0) into v_level from public.planet_buildings pb
     where pb.planet_id = v_home and pb.building_id = 'metal_mine';
    v_ok := v_level = 1;
    insert into t_stuck_queue_results(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       format('5a. re-completing the building does NOT re-apply the level (level=%s)', v_level));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select coalesce(pr.level, 0) into v_res from public.player_research pr
     where pr.player_id = v_player and pr.research_id = 'laser_technology';
    v_ok := v_res = 1;
    insert into t_stuck_queue_results(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       format('5b. re-completing the research does NOT re-apply the level (level=%s)', v_res));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select p.fields_used = v_fields from public.planets p where p.id = v_home);
/* ================ 6. MULTI-PLANET ISOLATION ================
       `complete_research` loops EVERY planet of the player. Here the homeworld clock is AHEAD
       of the research event (stale) while the colony clock is BEHIND it (valid). The valid
       planet must NOT be blocked by the stale one, and the research must still be granted. */
    select p.position + 1 into v_pos
      from public.planets p
     where p.universe_id = v_univ and not p.is_destroyed
       and not exists (select 1 from public.planets q
                        where q.universe_id = v_univ and q.position = p.position + 1)
     order by p.position desc limit 1;

    if v_pos is not null then
        insert into public.planets(id, universe_id, player_id, galaxy, system, position, name, is_destroyed, created_at)
        values (gen_random_uuid(), v_univ, v_player,
                (select p.galaxy from public.planets p where p.id = v_home),
                (select p.system from public.planets p where p.id = v_home),
                v_pos, 'StuckQueueFixtureColony', false, now())
        returning id into v_colony;

        insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at)
        values (v_colony, 1000000, 1000000, 1000000, 0, v_now - interval '60 minutes');

        insert into public.research_queue(player_id, research_id, planet_id, target_level, started_at, finishes_at, status)
        values (v_player, 'energy_technology', v_home, 1,
                v_now - interval '60 minutes', v_now - interval '50 minutes', 'RESEARCHING')
        returning id into v_rq;

        -- only the homeworld is pulled past the event; the colony stays behind it
        perform public.update_planet_resources_until_raw(v_home, v_now);

        v_ok := (select pr.last_calculated_at > q.finishes_at
                   from public.planet_resources pr, public.research_queue q
                  where pr.planet_id = v_home and q.id = v_rq)
           and (select pr.last_calculated_at < q.finishes_at
                  from public.planet_resources pr, public.research_queue q
                 where pr.planet_id = v_colony and q.id = v_rq);
        insert into t_stuck_queue_results(resultado, prueba) values
          (case when v_ok then 'PASS' else 'FAIL' end,
           '4c. ANTI-VACUITY: homeworld stale AND colony valid on the same player');
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        v_ok := (select count(*) = 2 from public.planets p
                  where p.player_id = v_player and not p.is_destroyed);
        insert into t_stuck_queue_results(resultado, prueba) values
          (case when v_ok then 'PASS' else 'FAIL' end,
           '6a. complete_research really loops 2 planets for this player');
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        begin
            perform * from public.process_universe_tick(v_univ);
            v_ok := true;
        exception when others then
            v_ok := false;
            insert into t_stuck_queue_results(resultado, prueba) values
              ('FAIL', format('6. universe tick raised [%] %', sqlstate, sqlerrm));
        end;
        insert into t_stuck_queue_results(resultado, prueba) values
          (case when v_ok then 'PASS' else 'FAIL' end,
           '6b. one stale planet does NOT abort the tick or the other planet');
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        v_ok := (select q.status = 'COMPLETED' from public.research_queue q where q.id = v_rq);
        insert into t_stuck_queue_results(resultado, prueba) values
          (case when v_ok then 'PASS' else 'FAIL' end,
           '6c. the research completes even though one planet was already ahead');
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        select coalesce(pr.level, 0) into v_res from public.player_research pr
         where pr.player_id = v_player and pr.research_id = 'energy_technology';
        v_ok := v_res = 1;
        insert into t_stuck_queue_results(resultado, prueba) values
          (case when v_ok then 'PASS' else 'FAIL' end,
/* ================ 7. THE GUARD ITSELF IS NOT WEAKENED ================ */
    begin
        perform public.update_planet_resources_until_raw(v_home, v_now - interval '3 hours');
        v_ok := false;
    exception when others then
        v_ok := sqlerrm = 'INVALID_RESOURCE_TIMESTAMP';
    end;
    insert into t_stuck_queue_results(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       '7. a raw backwards timestamp is still rejected (the clamp did not weaken the guard)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ================ 8. NO EXTRA PRODUCTION FROM THE CLAMP ================ */
    declare v_before numeric; v_after numeric;
    begin
        select coalesce(metal,0) + coalesce(crystal,0) + coalesce(deuterium,0) into v_before
          from public.planet_resources where planet_id = v_home;
        perform public.update_planet_resources_until(v_home, v_now);
        select coalesce(metal,0) + coalesce(crystal,0) + coalesce(deuterium,0) into v_after
          from public.planet_resources where planet_id = v_home;
        v_ok := v_after = v_before;
        insert into t_stuck_queue_results(resultado, prueba) values
          (case when v_ok then 'PASS' else 'FAIL' end,
           format('8. clamping to the current clock credits ZERO extra resources (%s -> %s)',
                  v_before, v_after));
        v_fail := v_fail + case when v_ok then 0 else 1 end;
    end;
end $test$;

select resultado, prueba from t_stuck_queue_results order by orden;

do $summary$
declare v_fail integer; v_total integer;
begin
    select count(*) filter (where resultado = 'FAIL'), count(*)
      into v_fail, v_total from t_stuck_queue_results;
    raise notice 'RESULT: % / % PASS', v_total - v_fail, v_total;
    if v_fail > 0 then
        raise exception 'FIXTURE FAILED: % of % assertions failed', v_fail, v_total;
    end if;
end $summary$;

rollback;