-- FLEET STUCK-STATE: ATTACK / ESPIONAGE / EXPEDITION arrival on a past event — 2026-10-01
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- THE DEFECT THIS CERTIFIES
--   `update_planet_resources_until` deliberately refuses to move a planet's clock BACKWARDS
--   (INVALID_RESOURCE_TIMESTAMP). That guard is correct and is NOT touched.
--   20260930240000 / 20260930241000 clamped four settlement anchors to
--   greatest(<event timestamp>, last_calculated_at) -- the RETURNING leg plus two arrival
--   resolvers -- but the fix enumerates a FIXED list of call sites. Four more anchors kept
--   passing the RAW timestamp and are covered here:
--       resolve_attack_arrival     -> update_planet_resources_until(defender, arrives_at)
--       resolve_espionage_arrival  -> update_planet_resources_until(target,   arrives_at)
--       resolve_expedition_arrival -> update_planet_resources_until(origin,    arrives_at)
--       apply_attack_loot          -> update_planet_resources_until(defender, arrives_at)
--
--   The fleet worker downgrades every error to `raise warning 'FLEET_RESOLUTION_FAILED'`, so
--   nothing rolls back and nothing surfaces: the movement retries forever and the ships -- already
--   debited at dispatch -- are lost permanently. Measured before the fix, through the real worker
--   entry point, with the event 2 h in the past and the body already settled to now():
--       ATTACK -> OUTBOUND after 5 passes, 0 battles, 0 ships credited
--       ESPIONAGE -> OUTBOUND, 0 reports     EXPEDITION -> OUTBOUND
--
-- WHAT THIS CERTIFIES
--   The four anchors no longer strand the movement; the missions reach their real terminal state;
--   the result is persisted; the already-covered TRANSPORT path does not regress; the settlement
--   guard still rejects a raw backwards timestamp; and no clamp is granted EXTRA production.
--
-- LIMITATION: sequential, inside ROLLBACK. True concurrency is not executed; the advisory lock and
-- the `for update skip locked` row claims are unchanged by the migration.

begin;

drop table if exists t_stuck_arrival_results;
create temp table t_stuck_arrival_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid; v_player uuid; v_src uuid; v_dst uuid;
    v_attack uuid; v_espionage uuid; v_expedition uuid; v_transport uuid;
    v_now timestamptz := now();
    v_ok boolean; v_fail integer := 0; v_meta record;
begin
    /* ------------------------------------------------------------------ FIXTURE */
    select pl.id, pl.user_id into v_player, v_auth
      from public.players pl where pl.user_id is not null
     order by pl.created_at, pl.id limit 1;

    select p.id into v_src
      from public.planets p
     where p.player_id = v_player and not p.is_destroyed
     order by p.created_at, p.id limit 1;

    select p.id into v_dst
      from public.planets p join public.players pl on pl.id = p.player_id
     where pl.player_type = 'AI' and not p.is_destroyed and p.id <> v_src
       and exists (select 1 from public.planet_resources pr where pr.planet_id = p.id)
     order by p.created_at, p.id limit 1;

    if v_player is null or v_src is null or v_dst is null then
        raise exception 'TEST_ABORT: need one auth-linked player and one AI planet with resources';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* FLEET SLOTS PREREQUISITE (2026-09-26). */
    insert into public.player_research(player_id, research_id, level) values (v_player, 'computer_technology', 60)
    on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, excluded.level);

    /* ============ 1. THE REGRESSION: ATTACK on a past arrival event ============ */
    insert into public.fleet_movements
      (player_id, origin_planet_id, destination_planet_id, mission_type, status,
       started_at, arrives_at, destination_galaxy, destination_system, destination_position)
    values (v_player, v_src, v_dst, 'ATTACK', 'OUTBOUND',
            v_now - interval '3 hours', v_now - interval '2 hours', 1, 1, 4)
    returning id into v_attack;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_attack, 'cruiser', 5);

    -- the ordinary event that moves the defender's clock past the arrival timestamp
    perform public.update_planet_resources_until(v_dst, v_now);

    insert into t_stuck_arrival_results(resultado, prueba) values
      (case when (select (pr.last_calculated_at > fm.arrives_at)
                    from public.planet_resources pr, public.fleet_movements fm
                   where pr.planet_id = v_dst and fm.id = v_attack)
            then 'PASS' else 'FAIL' end,
       '1. ANTI-VACUITY: the destination clock really is ahead of the arrival event');

    -- several worker passes, exactly as the 1-second cron does
    perform * from public.process_fleet_movements();
    perform * from public.process_fleet_movements();
    perform * from public.process_fleet_movements();

    select fm.status into v_meta from public.fleet_movements fm where fm.id = v_attack;
    v_ok := v_meta.status not in ('OUTBOUND', 'ARRIVED');
    insert into t_stuck_arrival_results(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       format('1a. THE REGRESSION: an overdue ATTACK is no longer stuck (status=%s)', v_meta.status));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_stuck_arrival_results(resultado, prueba) values
      (case when exists (select 1 from public.combat_battles cb where cb.fleet_id = v_attack)
            then 'PASS' else 'FAIL' end,
       '1b. the attack actually produced its combat battle');
    v_fail := v_fail + case when exists (select 1 from public.combat_battles cb where cb.fleet_id = v_attack)
                            then 0 else 1 end;
/* ============ 2. THE REGRESSION: ESPIONAGE on a past arrival event ============ */
    insert into public.fleet_movements
      (player_id, origin_planet_id, destination_planet_id, mission_type, status,
       started_at, arrives_at, destination_galaxy, destination_system, destination_position)
    values (v_player, v_src, v_dst, 'ESPIONAGE', 'OUTBOUND',
            v_now - interval '3 hours', v_now - interval '2 hours', 1, 1, 4)
    returning id into v_espionage;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_espionage, 'espionage_probe', 3);

    perform public.update_planet_resources_until(v_dst, v_now);
    perform * from public.process_fleet_movements();
    perform * from public.process_fleet_movements();

    select fm.status into v_meta from public.fleet_movements fm where fm.id = v_espionage;
    v_ok := v_meta.status not in ('OUTBOUND', 'ARRIVED');
    insert into t_stuck_arrival_results(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       format('2a. THE REGRESSION: an overdue ESPIONAGE is no longer stuck (status=%s)', v_meta.status));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := exists (select 1 from public.espionage_reports er where er.fleet_id = v_espionage);
    insert into t_stuck_arrival_results(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       '2b. the espionage report the player must read was actually produced');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 3. THE REGRESSION: EXPEDITION on a past arrival event ============ */
    insert into public.fleet_movements
      (player_id, origin_planet_id, destination_planet_id, mission_type, status,
       started_at, arrives_at, destination_galaxy, destination_system, destination_position)
    values (v_player, v_src, null, 'EXPEDITION', 'OUTBOUND',
            v_now - interval '3 hours', v_now - interval '2 hours', 1, 1, 4)
    returning id into v_expedition;

    perform public.update_planet_resources_until(v_src, v_now);
    perform * from public.process_fleet_movements();
    perform * from public.process_fleet_movements();

    select fm.status into v_meta from public.fleet_movements fm where fm.id = v_expedition;
    v_ok := v_meta.status not in ('OUTBOUND', 'ARRIVED');
    insert into t_stuck_arrival_results(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       format('3a. THE REGRESSION: an overdue EXPEDITION arrival resolves (status=%s)', v_meta.status));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := exists (select 1 from public.expedition_results er where er.fleet_id = v_expedition);
/* ============ 5. NO MOVEMENT LEFT STUCK ANYWHERE ============ */
    v_ok := not exists (
        select 1 from public.fleet_movements fm
         where fm.id in (v_attack, v_espionage, v_expedition, v_transport)
           and fm.status in ('OUTBOUND', 'ARRIVED', 'HOLDING'));
    insert into t_stuck_arrival_results(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       '5. no movement from this fixture is left in a non-terminal state');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 6. THE GUARD ITSELF IS NOT WEAKENED ============ */
    begin
        perform public.update_planet_resources_until(v_dst, v_now - interval '3 hours');
        v_ok := false;
    exception when others then
        v_ok := sqlerrm = 'INVALID_RESOURCE_TIMESTAMP';
    end;
    insert into t_stuck_arrival_results(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       '6. a raw backwards timestamp is still rejected (the clamp did not weaken the guard)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 7. NO EXTRA PRODUCTION IS GRANTED BY THE CLAMP ============
       Anti-vacuity for the fix itself: settling at the planet's own clock must credit exactly
       zero elapsed time. If a clamp ever started manufacturing production, this catches it. */
    declare v_before numeric; v_after numeric;
    begin
        select coalesce(metal,0) + coalesce(crystal,0) + coalesce(deuterium,0)
          into v_before from public.planet_resources where planet_id = v_dst;

        perform public.update_planet_resources_until(v_dst, v_now);

        select coalesce(metal,0) + coalesce(crystal,0) + coalesce(deuterium,0)
          into v_after from public.planet_resources where planet_id = v_dst;

        v_ok := v_after = v_before;
        insert into t_stuck_arrival_results(resultado, prueba) values
          (case when v_ok then 'PASS' else 'FAIL' end,
           format('7. clamping to the current clock credits ZERO extra resources (%s -> %s)',
                  v_before, v_after));
        v_fail := v_fail + case when v_ok then 0 else 1 end;
    end;
end $test$;

select resultado, prueba from t_stuck_arrival_results order by orden;

do $summary$
declare v_fail integer; v_total integer;
begin
    select count(*) filter (where resultado = 'FAIL'), count(*)
      into v_fail, v_total from t_stuck_arrival_results;
    raise notice 'RESULT: % / % PASS', v_total - v_fail, v_total;
    if v_fail > 0 then
        raise exception 'FIXTURE FAILED: % of % assertions failed', v_fail, v_total;
    end if;
end $summary$;

rollback;
    insert into t_stuck_arrival_results(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       '3b. the expedition outcome was persisted');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 4. NO REGRESSION: TRANSPORT (clamped by 20260930241000) ============ */
    insert into public.fleet_movements
      (player_id, origin_planet_id, destination_planet_id, mission_type, status,
       started_at, arrives_at, destination_galaxy, destination_system, destination_position,
       metal, crystal, deuterium)
    values (v_player, v_src, v_dst, 'TRANSPORT', 'OUTBOUND',
            v_now - interval '3 hours', v_now - interval '2 hours', 1, 1, 4, 1000, 500, 0)
    returning id into v_transport;

    perform public.update_planet_resources_until(v_dst, v_now);
    perform * from public.process_fleet_movements();
    perform * from public.process_fleet_movements();

    select fm.status into v_meta from public.fleet_movements fm where fm.id = v_transport;
    v_ok := v_meta.status = 'COMPLETED';
    insert into t_stuck_arrival_results(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       format('4. the already-covered TRANSPORT path still completes (status=%s)', v_meta.status));
    v_fail := v_fail + case when v_ok then 0 else 1 end;