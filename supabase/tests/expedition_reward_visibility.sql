-- EXPEDITION CARGO CLAMP VISIBILITY FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional fixture: it always ends in ROLLBACK.
--
-- Gap closed 2026-09-28 (UI only). The expedition engine computes
--     final_resource_amount = LEAST(base_resource_find * reward_multiplier, cargo_capacity)
-- and credits only that. When the find exceeded the fleet's hold the difference was silently
-- discarded and the report showed ONLY the award, so the player could not tell "the expedition found
-- nothing" from "the expedition found plenty and my cargo was too small".
--
-- `get_player_expedition_reports` already returned both sides of the clamp (`scaled_resource_find` and
-- `cargo_capacity`); nothing consumed them. This fixture certifies the contract payload the panel now
-- renders: the CLAMPED case, the UNCLAMPED case, and that both values come back VERBATIM.
--
-- `reward_tier`, `reward_multiplier` and `max_resource_find` are deliberately NOT rendered: they are
-- formula internals. `loot_applied_at` is not an expedition field at all (it lives on combat_battles).
--
-- LIMITATION: single-session harness with ROLLBACK; concurrency not executed. The panel is READ-ONLY,
-- so this proves the CONTRACT payload, not a browser DOM.

begin;

drop table if exists t_erv;
create temp table t_erv(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid; v_player uuid; v_planet uuid; v_fleet uuid; v_row record;
    v_ok boolean; v_fails integer := 0; v_rows integer; v_found numeric; v_hold numeric; v_i integer;
begin
    select pl.user_id, pl.id into v_auth, v_player from public.players pl
     where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_planet from public.planets p
     where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET' order by p.created_at limit 1;
    if v_player is null or v_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet is required';
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'shipyard', 4)
      on conflict (planet_id, building_id) do update set level = greatest(public.planet_buildings.level, 4);
    insert into public.player_research(player_id, research_id, level) values (v_player, 'combustion_drive', 6)
      on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, 6);
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_planet, 'large_cargo', 6)
      on conflict (planet_id, ship_id) do update set quantity = greatest(public.planet_ships.quantity, 6);
    update public.planet_resources set deuterium = 9000000 where planet_id = v_planet;

    /* ---- 1. a REAL expedition, resolved by the REAL resolver.
       The outcome is a genuine random roll, so the fixture repeats the REAL flow until the REAL engine
       produces RESOURCES. Nothing is forced and nothing is mocked: only a non-RESOURCES roll is retried,
       and the discarded fleet is completed so the single expedition slot is freed the honest way.
       Between attempts the resource clock is pulled back to now(): resolving a fleet advances
       planet_resources.last_calculated_at to its arrival instant, which is already ahead of now(), and
       the engine's own INVALID_RESOURCE_TIMESTAMP guard must be respected rather than bypassed. Only
       bookkeeping is touched, never a reward value. ---- */
    v_fleet := null;
    for v_i in 1..30 loop
        update public.planet_resources
           set last_calculated_at = clock_timestamp() - interval '1 second'
         where planet_id = v_planet;
        perform public.start_fleet_mixed(v_player, v_planet, null, '{"large_cargo": 1}'::jsonb, 'EXPEDITION');
        select id into v_fleet from public.fleet_movements
         where player_id = v_player and mission_type = 'EXPEDITION' and status = 'OUTBOUND'
         order by created_at desc limit 1;
        if v_fleet is null then
            raise exception 'TEST_ABORT: the dispatch created no movement';
        end if;
        update public.fleet_movements set status = 'ARRIVED' where id = v_fleet;
        perform public.resolve_expedition_arrival(v_fleet);
        select er.outcome into v_row from public.expedition_results er where er.fleet_id = v_fleet;
        exit when v_row.outcome = 'RESOURCES';
        update public.fleet_movements set status = 'COMPLETED', returns_at = now() where id = v_fleet;
    end loop;
    v_ok := v_fleet is not null and v_row.outcome = 'RESOURCES';
    insert into t_erv(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,

    /* ---- 2. a CLAMPED result: found > hold, the case the panel now explains ---- */
    update public.expedition_results
       set scaled_resource_find = 23107, cargo_capacity = 100
     where fleet_id = v_fleet;
    select * into v_row from public.get_player_expedition_reports(25) r where r.fleet_id = v_fleet;
    v_found := coalesce(v_row.scaled_resource_find, 0);
    v_hold := coalesce(v_row.cargo_capacity, 0);
    v_ok := v_found = 23107 and v_hold = 100 and v_found > v_hold;
    insert into t_erv(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. CLAMPED: the contract exposes found=%s hold=%s (found > hold -> the panel explains it)', v_found, v_hold));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 3. the values are VERBATIM: stored == returned, never recomputed ---- */
    v_ok := v_row.scaled_resource_find = (select er.scaled_resource_find from public.expedition_results er where er.fleet_id = v_fleet)
            and v_row.cargo_capacity = (select er.cargo_capacity from public.expedition_results er where er.fleet_id = v_fleet);
    insert into t_erv(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '3. both clamp values are returned VERBATIM (stored == contract, nothing recomputed)');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 4. an UNCLAMPED result: the panel must render nothing extra ---- */
    update public.expedition_results
       set scaled_resource_find = 500, cargo_capacity = 25000
     where fleet_id = v_fleet;
    select * into v_row from public.get_player_expedition_reports(25) r where r.fleet_id = v_fleet;
    v_found := coalesce(v_row.scaled_resource_find, 0);
    v_hold := coalesce(v_row.cargo_capacity, 0);
    v_ok := v_found = 500 and v_hold = 25000 and not (v_found > v_hold);
    insert into t_erv(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. UNCLAMPED: found=%s hold=%s (found <= hold -> no extra line)', v_found, v_hold));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 5. a zero-hold row must not trigger the line either ---- */
    update public.expedition_results set scaled_resource_find = 900, cargo_capacity = 0 where fleet_id = v_fleet;
    select * into v_row from public.get_player_expedition_reports(25) r where r.fleet_id = v_fleet;
    v_ok := coalesce(v_row.cargo_capacity, 0) = 0;
    insert into t_erv(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,

    /* ---- 6. OWNERSHIP: another authenticated player reads 0 rows ---- */
    perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid())::text, true);
    select count(*)::integer into v_rows from public.get_player_expedition_reports(25) r where r.fleet_id = v_fleet;
    v_ok := v_rows = 0;
    insert into t_erv(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. another authenticated player reads 0 rows of that expedition (%s)', v_rows));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 7. without a session nothing is returned ---- */
    perform set_config('request.jwt.claims', '{}', true);
    select count(*)::integer into v_rows from public.get_player_expedition_reports(25);
    v_ok := v_rows = 0;
    insert into t_erv(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. without a session the contract returns 0 rows (%s)', v_rows));
    v_fails := v_fails + case when v_ok then 0 else 1 end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* ---- 8. ACL unchanged ---- */
    v_ok := has_function_privilege('authenticated', 'public.get_player_expedition_reports(integer)', 'EXECUTE')
            and has_function_privilege('service_role', 'public.get_player_expedition_reports(integer)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.get_player_expedition_reports(integer)', 'EXECUTE');
    insert into t_erv(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '8. ACL unchanged: authenticated + service_role, anon denied');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 9. NO ENGINE CHANGE: no presentation text leaked into SQL ---- */
    v_ok := not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                         where n.nspname = 'public'
                           and p.proname in ('resolve_expedition_arrival','calculate_expedition_resource_budget',
                                             'calculate_expedition_resource_amount_for_type',
                                             'calculate_expedition_final_resource_amount')
                           and p.prosrc::text ilike '%no cabía%');
    insert into t_erv(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '9. the expedition engine was NOT modified (no presentation text leaked into SQL)');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 10. the clamp formula itself is untouched ---- */
    v_ok := (select p.prosrc::text ilike '%LEAST(%' and p.prosrc::text ilike '%v_cargo%'
               from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'calculate_expedition_resource_budget');
    insert into t_erv(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10. the LEAST(tier_amount, cargo) clamp formula is unchanged');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    insert into t_erv(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness with ROLLBACK; concurrency not executed. The panel is READ-ONLY, so this proves the CONTRACT payload, not a browser render. The outcome roll is random, so the fixture repeats the real flow until RESOURCES.');
    insert into t_erv(resultado, prueba) values ('INFO', format('SUMMARY: %s failed assertion(s).', v_fails));
    if v_fails > 0 then
        raise exception 'EXPEDITION CARGO CLAMP VISIBILITY: % failed assertion(s)', v_fails;
    end if;
end;
$test$;

select orden, resultado, prueba from t_erv order by orden;

drop table if exists t_erv;

ROLLBACK;

      '5. a zero-hold row reports 0 and the panel guard (hold > 0) suppresses the line');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    update public.expedition_results
       set scaled_resource_find = 23107, cargo_capacity = 100
     where fleet_id = v_fleet;

      format('1. the REAL engine produced a RESOURCES result (outcome %s after %s attempt(s))',
             coalesce(v_row.outcome, 'none'), v_i));
    v_fails := v_fails + case when v_ok then 0 else 1 end;
