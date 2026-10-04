-- FLEET STUCK RETURNING / ARRIVED ON A PAST EVENT -- 2026-09-30
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- THE DEFECT THIS CERTIFIES
--   Every fleet settlement anchors the economy clock to a SCHEDULED EVENT TIMESTAMP:
--       process_fleet_movements   -> update_planet_resources_until(origin,  returns_at)
--       resolve_transport_arrival -> update_planet_resources_until(dest,    arrives_at)
--       resolve_deploy_arrival    -> update_planet_resources_until(dest,    arrives_at)
--       resolve_expedition_return -> update_planet_resources_until(origin,  returns_at)
--   and `update_planet_resources_until` deliberately refuses to move a planet's clock BACKWARDS
--   (INVALID_RESOURCE_TIMESTAMP). That guard is correct and is NOT touched by these migrations.
--
--   The bug: the fleet worker's per-fleet handler downgrades any error to a WARNING
--       exception when others then raise warning 'FLEET_RESOLUTION_FAILED ...'
--   A WARNING rolls nothing back and surfaces nothing, so when the event timestamp was ALREADY BEHIND
--   that body's production clock -- which happens on the ordinary event order, because any player
--   action on the body (start_building, cancel_building, load_fleet_cargo, the merchant, the UI's
--   sync_current_planet_resources) settles it to now() -- the settlement failed on every heartbeat,
--   forever. The fleet never advanced and its ships (already debited at dispatch) were LOST.
--
--   Reproduced on LIVE with no artificial rewind:
--       started 9h ago . arrived 7h ago . hold expired 6h ago . outbound leg 2h  =>  returns_at 4h AGO
--       the player touched the origin planet in between
--       => origin 0 ships, movement stranded with 5 cruisers, status RETURNING, permanently
--
-- THE FIX UNDER TEST
--   Clamp the anchor: settle at greatest(<event timestamp>, last_calculated_at).
--   When the event is still in the FUTURE -- the normal certified path -- this is a no-op and the
--   arrival-time anchoring is byte-identical. When it is behind, there is simply no elapsed time left
--   to credit, so settling at the current clock grants zero extra production and lets the fleet finish.
--
-- LIMITATION: sequential, inside ROLLBACK. True concurrency is not executed; the advisory lock and
-- the `for update skip locked` row claims are unchanged by these migrations.

begin;

drop table if exists t_fleet_stuck_results;
create temp table t_fleet_stuck_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid;
    v_player uuid;
    v_src uuid;
    v_dst uuid;
    v_fleet uuid;
    v_universe uuid;
    v_now timestamptz := now();
    v_ok boolean;
    v_fail integer := 0;
    v_meta record;
    v_res record;
    v_qty numeric;
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
     where pl.player_type = 'AI' and not p.is_destroyed
     order by p.created_at, p.id limit 1;

    select universe_id into v_universe from public.planets where id = v_src;

    if v_player is null or v_src is null or v_dst is null then
        raise exception 'TEST_ABORT: need one auth-linked player and one AI planet';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* FLEET SLOTS PREREQUISITE (2026-09-26). */
    insert into public.player_research(player_id, research_id, level) values (v_player, 'computer_technology', 60)
    on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, excluded.level);

    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_src, 'cruiser', 5)
    on conflict (planet_id, ship_id) do update set quantity = 5;

    /* ==================== 1. THE REGRESSION: ACS_HOLD RETURNING ==================== */
    update public.planet_ships set quantity = quantity - 5
     where planet_id = v_src and ship_id = 'cruiser';

    insert into public.fleet_movements
      (player_id, origin_planet_id, destination_planet_id, mission_type, status,
       started_at, arrives_at, holding_until, destination_galaxy, destination_system, destination_position)
    values (v_player, v_src, v_src, 'ACS_HOLD', 'OUTBOUND',
            v_now - interval '9 hours', v_now - interval '7 hours', v_now - interval '6 hours', 1, 1, 4)
    returning id into v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'cruiser', 5);

    /* the ordinary player action that moves the origin clock past the return event */
    perform public.update_planet_resources_until(v_src, v_now);

    perform public.process_universe_tick(v_universe);

    select fm.status into v_meta from public.fleet_movements fm where fm.id = v_fleet;
    v_ok := v_meta.status = 'COMPLETED';
    insert into t_fleet_stuck_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. THE REGRESSION: an overdue ACS_HOLD return is no longer stuck (status=%s)', v_meta.status));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select ps.quantity into v_meta from public.planet_ships ps
     where ps.planet_id = v_src and ps.ship_id = 'cruiser';
    v_ok := coalesce(v_meta.quantity, 0) = 5;
    insert into t_fleet_stuck_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. the 5 cruisers come home instead of being lost (got %s)', coalesce(v_meta.quantity::text, '0')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* The composition rows are deliberately RETAINED as the historical record of the flight (the same
       convention every completed movement uses), so this asserts the STATE, not the row count: the
       movement is closed AND the ships were credited to the planet exactly once. */
    select fm.status into v_meta from public.fleet_movements fm where fm.id = v_fleet;
    select count(*) into v_qty from public.planet_ships ps
     where ps.planet_id = v_src and ps.ship_id = 'cruiser';
    /* `v_qty` counts ROWS, not units, so the assertion is "credited exactly ONCE" => one row,
       plus the unit total from test 2. Comparing the row count against 5 (as this line used to)
       contradicted the comment directly above it and could never hold. */
    v_ok := v_meta.status = 'COMPLETED'
        and coalesce(v_qty, 0) = 1
        and coalesce((select sum(ps.quantity) from public.planet_ships ps
                       where ps.planet_id = v_src and ps.ship_id = 'cruiser'), 0) = 5;
    insert into t_fleet_stuck_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. the movement is closed and the ships credited exactly once (status=%s, ships=%s)',
             v_meta.status, coalesce(v_qty::text, '0')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;
    /* ==================== 2. THE SIBLING REGRESSION: TRANSPORT ARRIVAL ==================== */
    update public.planet_resources set metal = 0, crystal = 0, deuterium = 0, last_calculated_at = v_now
     where planet_id = v_dst;
    insert into public.fleet_movements
      (player_id, origin_planet_id, destination_planet_id, mission_type, status,
       started_at, arrives_at, destination_galaxy, destination_system, destination_position,
       metal, crystal, deuterium)
    values (v_player, v_src, v_dst, 'TRANSPORT', 'OUTBOUND',
            v_now - interval '3 hours', v_now - interval '2 hours', 1, 1, 4, 1000, 500, 0)
    returning id into v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'small_cargo', 5);

    perform public.process_universe_tick(v_universe);

    select fm.status into v_meta from public.fleet_movements fm where fm.id = v_fleet;
    v_ok := v_meta.status <> 'ARRIVED';
    insert into t_fleet_stuck_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. an overdue TRANSPORT is no longer frozen in ARRIVED (status=%s)', v_meta.status));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select pr.metal, pr.crystal into v_res from public.planet_resources pr where pr.planet_id = v_dst;
    v_ok := v_res.metal >= 1000 and v_res.crystal >= 500;
    insert into t_fleet_stuck_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. the transport cargo is actually delivered (%s M / %s C)', v_res.metal, v_res.crystal));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ==================== 3. THE NORMAL PATH IS UNCHANGED ==================== */
    /* A FUTURE event must still anchor the settlement to the event timestamp, not to now().
       This is the certified behaviour; the clamp must be a no-op there. */
    update public.planet_resources set metal = 0, crystal = 0, deuterium = 0,
           last_calculated_at = v_now - interval '1 hour'
     where planet_id = v_dst;

    insert into public.fleet_movements
      (player_id, origin_planet_id, destination_planet_id, mission_type, status,
       started_at, arrives_at, destination_galaxy, destination_system, destination_position,
       metal, crystal, deuterium)
    values (v_player, v_src, v_dst, 'TRANSPORT', 'ARRIVED',
            v_now, v_now + interval '1 hour', 1, 1, 4, 700, 300, 0)
    returning id into v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'small_cargo', 5);

    perform public.resolve_transport_arrival(v_fleet);

    select pr.last_calculated_at into v_meta from public.planet_resources pr where pr.planet_id = v_dst;
    v_ok := v_meta.last_calculated_at = v_now + interval '1 hour';
    insert into t_fleet_stuck_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '6. a FUTURE event still settles exactly at the event timestamp (clamp is a no-op)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select fm.status into v_meta from public.fleet_movements fm where fm.id = v_fleet;
    v_ok := v_meta.status = 'RETURNING';
    insert into t_fleet_stuck_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. the normal transport path still ends RETURNING (status=%s)', v_meta.status));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ==================== 4. THE SETTLEMENT GUARD IS NOT WEAKENED ==================== */
    select pr.last_calculated_at into v_meta from public.planet_resources pr where pr.planet_id = v_dst;
    v_ok := false;
    begin
        perform public.update_planet_resources_until(v_dst, v_meta.last_calculated_at - interval '1 hour');
    exception when others then
        v_ok := position('INVALID_RESOURCE_TIMESTAMP' in sqlerrm) > 0;
    end;
    insert into t_fleet_stuck_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '8. the guard still refuses to move a planet backwards (the fix does not weaken it)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* the deployed bodies carry the clamp */
    v_ok := (
        select count(*) = 4 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('process_fleet_movements','resolve_transport_arrival',
                             'resolve_deploy_arrival','resolve_expedition_return')
           and p.prosrc ilike '%last_calculated_at%'
    );
    insert into t_fleet_stuck_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '9. all four settlement call sites carry the clamp');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* the canonical ordering (fleets before planets) survives */
    v_ok := (select p.prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'process_universe_tick')
            ilike '%process_fleet_movements%';
    insert into t_fleet_stuck_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10. the universe tick still drains fleets before planets');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ==================== 5. NOTHING ELSE MOVED ==================== */
    v_ok := (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'calculate_planet_production')
            ilike '%crawler_effective%';
    insert into t_fleet_stuck_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '11. the production engine was NOT touched by this mission');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'settle_resource_stock')
            ilike '%capacity - p_current%';
    insert into t_fleet_stuck_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '12. the cargo-preservation settlement helper (2026-09-30) is still intact');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* no fleet created by this fixture is left mid-lifecycle */
    v_ok := not exists (
        select 1 from public.fleet_movements fm
         where fm.mission_type in ('ACS_HOLD','TRANSPORT')
           and fm.started_at <= v_now - interval '3 hours'
           and fm.status in ('OUTBOUND','ARRIVED','HOLDING','RETURNING'));
    insert into t_fleet_stuck_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '13. the fixture leaves no fleet of these missions stuck mid-lifecycle');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    raise notice 'FLEET STUCK-STATE FIXTURE: % failures', v_fail;
end $test$;

select resultado, prueba from t_fleet_stuck_results order by orden;

do $summary$
declare v_fail integer; v_total integer;
begin
    select count(*) filter (where resultado = 'FAIL'), count(*)
      into v_fail, v_total from t_fleet_stuck_results;
    raise notice 'RESULT: % / % PASS', v_total - v_fail, v_total;
    if v_fail > 0 then
        raise exception 'FIXTURE FAILED: % of % assertions failed', v_fail, v_total;
    end if;
end $summary$;

rollback;
