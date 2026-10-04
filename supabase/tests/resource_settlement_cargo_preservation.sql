-- RESOURCE SETTLEMENT MUST NOT DESTROY DELIVERED CARGO -- 2026-09-30
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- THE DEFECT THIS CERTIFIES
--   Both settlement functions ended with
--       LEAST(capacity, GREATEST(0, current + produced))
--   which clamps the RUNNING TOTAL. The arrival resolvers credit cargo unconditionally,
--   exactly like OGameX's PlanetService::addResources(). Together they meant a transport that
--   overflowed a full planet was credited in full and then silently DELETED by the next tick:
--       capacity 100 000 | stock 99 000 | transport delivers 50 000
--       -> arrival 149 000 -> next tick 100 000   (49 000 metal vanished, no event, no report)
--
--   OGameX (PlanetService::updateResourcesUntil) caps only the amount being ADDED:
--       if (($current_metal + $add_resources->metal->get()) > $max_metal) {
--           $add_resources->metal->set($max_metal - $current_metal);
--       }
--   Stock already held is never reduced; an over-capacity planet simply stops producing until
--   the player spends the excess down.
--
-- THE FIX UNDER TEST
--   public.settle_resource_stock(current, delta, capacity), an IMMUTABLE helper holding the whole
--   rule, delegated to by update_planet_resources_until_raw and update_planet_resources:
--       positive delta -> fills only the FREE space
--       negative delta -> always in full (the fusion plant consumes deuterium)
--       result         -> floored at 0
--
-- LIMITATION: the fixture exercises the settlement and the arrival resolvers sequentially
-- (ROLLBACK); it does not execute true concurrency. Row locking is asserted by the deployed
-- bodies (FOR UPDATE on planet_resources) and is unchanged by this migration.

begin;

drop table if exists t_settlement_results;
create temp table t_settlement_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid;
    v_player uuid;
    v_src uuid;
    v_dst uuid;
    v_fleet uuid;
    v_universe uuid;
    v_gal integer;
    v_sys integer;
    v_cap numeric;
    v_metal numeric;
    v_crystal numeric;
    v_ok boolean;
    v_fail integer := 0;
begin
    /* ------------------------------------------------------------------ FIXTURE */
    select pl.id, pl.user_id into v_player, v_auth
      from public.players pl
     where pl.user_id is not null
     order by pl.created_at, pl.id limit 1;

    select p.id, p.universe_id, p.galaxy, p.system
      into v_src, v_universe, v_gal, v_sys
      from public.planets p
     where p.player_id = v_player and not p.is_destroyed
     order by p.created_at, p.id limit 1;

    if v_player is null or v_src is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet is required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* FLEET SLOTS PREREQUISITE (2026-09-26): 1 + computer_technology simultaneous fleets. */
    insert into public.player_research(player_id, research_id, level)
    values (v_player, 'computer_technology', 60)
    on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, excluded.level);

    /* Destination colony with NO storage buildings => capacity is the 100 000 floor, so the
       overflow case is reachable without touching any real player empire. */
    insert into public.planets(universe_id, player_id, name, galaxy, system, position,
                               is_homeworld, fields_total, temperature_min, temperature_max)
    values (v_universe, v_player, 'SETTLEMENT_PROBE', v_gal, v_sys + 402, 4, false, 163, -20, 20)
    returning id into v_dst;

    perform public.bootstrap_new_player_state(v_player, v_dst);

    delete from public.planet_buildings
     where planet_id = v_dst
       and building_id in ('metal_storage','crystal_storage','deuterium_tank');

    /* bootstrap_new_player_state seeds NO buildings, so the probe planet would produce 0/h and
       every production assertion below would pass VACUOUSLY -- including assertion 9, which is the
       regression itself. It must be a genuinely producing planet. */
    insert into public.planet_buildings(planet_id, building_id, level)
    values (v_dst, 'metal_mine', 10),
           (v_dst, 'crystal_mine', 8),
           (v_dst, 'deuterium_synthesizer', 6),
           (v_dst, 'solar_plant', 12)
    on conflict (planet_id, building_id) do update set level = excluded.level;

    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_src, 'small_cargo', 10);

    select st.metal_capacity into v_cap from public.calculate_planet_storage_internal(v_dst) st;

    /* GUARD: refuse to run a vacuous fixture. */
    if (select pp.metal_per_hour from public.calculate_planet_production(v_dst) pp) <= 0 then
        raise exception 'TEST_ABORT: probe planet does not produce; assertions would be vacuous';
    end if;

    /* ============ 1. THE HELPER IS THE SINGLE AUTHORITY ============ */
    /* overflow already held is preserved (the regression itself) */
    v_ok := public.settle_resource_stock(149000, 0, 100000) = 149000;
    insert into t_settlement_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '1. overflow already held is preserved, not clamped away [149000 @ cap 100000]');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* production below the cap lands in full */
    v_ok := public.settle_resource_stock(90000, 5000, 100000) = 95000;
    insert into t_settlement_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '2. production under the cap is credited in full [90000 + 5000 = 95000]');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* production may never exceed the free space (the cap still binds NEW production) */
    v_ok := public.settle_resource_stock(90000, 50000, 100000) = 100000;
    insert into t_settlement_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '3. production cannot exceed the free space [90000 + 50000 -> 100000, not 140000]');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* an over-capacity planet produces NOTHING until the excess is spent */
    v_ok := public.settle_resource_stock(149000, 50000, 100000) = 149000;
    insert into t_settlement_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '4. an over-capacity planet stops producing instead of destroying stock');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* consumption is never throttled by capacity: the fusion plant must always burn deuterium */
    v_ok := public.settle_resource_stock(50000, -10000, 100000) = 40000;
    insert into t_settlement_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '5. consumption applies in full and is not clamped by capacity [50000 - 10000 = 40000]');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* the result can never go negative (OGameX max(0, ...) in addResources) */
    v_ok := public.settle_resource_stock(100, -5000, 100000) = 0;
    insert into t_settlement_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '6. the result is floored at 0, never negative [100 - 5000 -> 0]');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* consumption still applies while over capacity */
    v_ok := public.settle_resource_stock(149000, -9000, 100000) = 140000;
    insert into t_settlement_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '7. consumption still applies while over capacity [149000 - 9000 = 140000]');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 2. END TO END: TRANSPORT OVERFLOW ============ */
    update public.planet_resources
       set metal = 99000, crystal = 0, deuterium = 0, last_calculated_at = now()
     where planet_id = v_dst;

    insert into public.fleet_movements
      (player_id, origin_planet_id, destination_planet_id, mission_type, status,
       started_at, arrives_at, returns_at, metal, crystal, deuterium)
    values (v_player, v_src, v_dst, 'TRANSPORT', 'ARRIVED',
            now(), now(), now() + interval '1 hour', 50000, 0, 0)
    returning id into v_fleet;

    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'small_cargo', 10);

    perform public.resolve_transport_arrival(v_fleet);

    select pr.metal into v_metal from public.planet_resources pr where pr.planet_id = v_dst;

    v_ok := v_metal = 149000;
    insert into t_settlement_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '8. the arrival credits the full cargo even when it overflows [99000 + 50000 = 149000]');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* THE REGRESSION. The probe planet really produces, so the tick does run: the stock must stay
       exactly because the planet is over capacity and therefore produces nothing, NOT because the
       overflow was silently destroyed back down to the cap. */
    perform public.update_planet_resources_until(v_dst, now() + interval '1 hour');

    select pr.metal into v_metal from public.planet_resources pr where pr.planet_id = v_dst;

    v_ok := v_metal = 149000;
    insert into t_settlement_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '9. THE REGRESSION: the tick does NOT destroy the overflow [stays 149000, not 100000]');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* a second tick must be idempotent: still no loss */
    perform public.update_planet_resources_until(v_dst, now() + interval '2 hours');
    select pr.metal into v_metal from public.planet_resources pr where pr.planet_id = v_dst;

    v_ok := v_metal = 149000;
    insert into t_settlement_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10. repeated ticks never ratchet the overflow away [still exactly 149000]');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* spending the excess down re-arms production: below the cap the tick produces again */
    update public.planet_resources set metal = 50000, last_calculated_at = now() where planet_id = v_dst;
    perform public.update_planet_resources_until(v_dst, now() + interval '3 hours');
    select pr.metal into v_metal from public.planet_resources pr where pr.planet_id = v_dst;

    v_ok := v_metal > 50000 and v_metal <= v_cap;
    insert into t_settlement_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '11. once back under the cap the planet produces again and never passes the cap');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 3. BOTH SETTLEMENT PATHS AGREE ============ */
    /* update_planet_resources (the now() wrapper) must apply the same rule as the _until one */
    update public.planet_resources
       set metal = 149000, crystal = 0, deuterium = 0, last_calculated_at = now() - interval '2 hours'
     where planet_id = v_dst;
    perform public.update_planet_resources(v_dst);
    select pr.metal into v_metal from public.planet_resources pr where pr.planet_id = v_dst;

    v_ok := v_metal >= 149000;
    insert into t_settlement_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '12. update_planet_resources preserves the overflow too (one authority, both callers)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* the real production path must not regress: a normal under-cap planet still fills up */
    update public.planet_resources
       set metal = 0, crystal = 0, deuterium = 0, last_calculated_at = now() - interval '5 hours'
     where planet_id = v_dst;
    perform public.update_planet_resources(v_dst);
    select pr.metal, pr.crystal into v_metal, v_crystal
      from public.planet_resources pr where pr.planet_id = v_dst;

    v_ok := v_metal > 0 and v_metal <= v_cap;
    insert into t_settlement_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '13. production is untouched for a normal planet [0 < metal <= capacity]');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 4. AUTHORIZATION / EXPOSURE ============ */
    /* the helper is internal: it is not a client contract and grants nothing to anon */
    v_ok := not has_function_privilege('anon', 'public.settle_resource_stock(numeric,numeric,numeric)', 'EXECUTE')
       and not has_function_privilege('authenticated', 'public.settle_resource_stock(numeric,numeric,numeric)', 'EXECUTE');
    insert into t_settlement_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '14. the helper is internal: no EXECUTE for anon or authenticated');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* the settlement entry points keep exactly the ACL they had (no new client surface) */
    v_ok := has_function_privilege('service_role', 'public.update_planet_resources_until_raw(uuid,timestamptz)', 'EXECUTE');
    insert into t_settlement_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '15. the settlement entry point keeps its service_role EXECUTE (no new client surface)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 5. PRODUCTION STILL RESPECTS THE CAP ============ */
    v_ok := not exists (
        select 1 from public.planets p
          join public.planet_resources pr on pr.planet_id = p.id
          join lateral public.calculate_planet_storage_internal(p.id) st on true
         where p.is_destroyed = false
           and p.id <> v_dst
           and pr.last_calculated_at > now() - interval '10 minutes'
           and (pr.metal > st.metal_capacity or pr.crystal > st.crystal_capacity or pr.deuterium > st.deuterium_capacity)
    );
    insert into t_settlement_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '16. no recently settled live planet sits above its capacity (production still clamps)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* the deuterium path (fusion consumption) is a signed delta, never clamped by capacity */
    v_ok := public.settle_resource_stock(0, -1, 0) = 0;
    insert into t_settlement_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '17. a signed deuterium delta at zero capacity is floored, not wrapped');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    raise notice 'RESOURCE SETTLEMENT FIXTURE: % failures', v_fail;
end $test$;

select resultado, prueba from t_settlement_results order by orden;

do $summary$
declare v_fail integer; v_total integer;
begin
    select count(*) filter (where resultado = 'FAIL'), count(*)
      into v_fail, v_total from t_settlement_results;
    raise notice 'RESULT: % / % PASS', v_total - v_fail, v_total;
    if v_fail > 0 then
        raise exception 'FIXTURE FAILED: % of % assertions failed', v_fail, v_total;
    end if;
end $summary$;

rollback;
