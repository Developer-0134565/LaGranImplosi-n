-- ESPIONAGE MISSION COMPOSITION FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional fixture: it always ends in ROLLBACK.
--
-- Gap closed 2026-09-28 (`enforce_espionage_probe_composition_rule`): the espionage cycle itself was
-- already certified end to end. What was missing is ONE dispatch invariant.
--
--   * `start_fleet` / `start_fleet_mixed` enforce the composition rule for RECYCLE but enforced
--     NOTHING for ESPIONAGE: any hull could be sent on an espionage flight.
--   * A fleet of three light_fighters on ESPIONAGE was accepted, persisted, charged fuel and consumed
--     a fleet slot — and the resolver then produced probes_sent = 0, counter_chance = 0 and all four
--     reveal flags false, because everything it computes derives from `espionage_probe`.
--
-- This fixture proves the invariant is enforced, that a REAL espionage flight still works end to end
-- (so the fix did not close the mechanic), and that nothing else about dispatch moved.
--
-- LIMITATION: single-session harness with ROLLBACK; concurrency is not executed.

begin;

drop table if exists t_ecr;
create temp table t_ecr(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_planet uuid; v_target uuid; v_target_owner uuid;
    v_fleet uuid; v_err text; v_ok boolean; v_fails integer := 0; v_rows integer;
    v_lf numeric; v_report record;
begin
    select pl.id, pl.user_id into v_player, v_auth from public.players pl
     where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_planet from public.planets p
     where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET' order by p.created_at limit 1;
    select p.id, p.player_id into v_target, v_target_owner from public.planets p
     where p.player_id is not null and p.player_id <> v_player and not p.is_destroyed
     order by p.created_at limit 1;
    if v_player is null or v_planet is null or v_target is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet and a foreign planet are required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    /* `check_ship_requirements` gates `espionage_probe` on a shipyard 3 AND espionage_technology 2.
       Without BOTH, the positive half of the fixture would fail for an unrelated reason and would
       prove nothing about the new rule. The research row is only a launch prerequisite here: the
       reveal ladder is driven by the LEVEL GAP between attacker and defender, which this fixture
       deliberately leaves at 0/0 so a 3-probe flight reveals ships. */
    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'shipyard', 4)
      on conflict (planet_id, building_id) do update set level = greatest(public.planet_buildings.level, 4);
    insert into public.player_research(player_id, research_id, level) values (v_player, 'espionage_technology', 2)
      on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, 2);
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_planet, 'espionage_probe', 5)
      on conflict (planet_id, ship_id) do update set quantity = greatest(public.planet_ships.quantity, 5);
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_planet, 'light_fighter', 10)
      on conflict (planet_id, ship_id) do update set quantity = greatest(public.planet_ships.quantity, 10);
    update public.planet_resources set deuterium = 9000000 where planet_id = v_planet;

    /* 1. the mixed dispatcher refuses a probe-less ESPIONAGE fleet */
    v_err := null;
    begin
        perform public.start_fleet_mixed(v_player, v_planet, v_target, '{"light_fighter": 3}'::jsonb, 'ESPIONAGE');
    exception when others then v_err := sqlerrm; end;
    v_ok := v_err ilike '%ESPIONAGE_MISSION_REQUIRES_PROBES%';
    insert into t_ecr(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. start_fleet_mixed refuses a light_fighter ESPIONAGE fleet (%s)', coalesce(v_err,'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 2. the refusal is atomic: the guard raises inside the composition loop, before any resource */
    select count(*)::integer into v_rows from public.fleet_movements
     where player_id = v_player and mission_type = 'ESPIONAGE';
    select quantity into v_lf from public.planet_ships where planet_id = v_planet and ship_id = 'light_fighter';
    v_ok := v_rows = 0 and v_lf = 10;
    insert into t_ecr(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,

    /* 4. THE MECHANIC IS STILL OPEN: a real probe flight is accepted */
    v_err := null;
    begin
        perform public.start_fleet_mixed(v_player, v_planet, v_target, '{"espionage_probe": 3}'::jsonb, 'ESPIONAGE');
    exception when others then v_err := sqlerrm; end;
    select id into v_fleet from public.fleet_movements
     where player_id = v_player and mission_type = 'ESPIONAGE' order by created_at desc limit 1;
    v_ok := v_err is null and v_fleet is not null;
    insert into t_ecr(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. a real espionage_probe flight is still accepted (%s)', coalesce(v_err,'dispatched')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 5. a MIXED fleet is refused: probes may not ride with combat hulls on ESPIONAGE */
    v_err := null;
    begin
        perform public.start_fleet_mixed(v_player, v_planet, v_target,
            '{"espionage_probe": 1, "light_fighter": 1}'::jsonb, 'ESPIONAGE');
    exception when others then v_err := sqlerrm; end;
    v_ok := v_err ilike '%ESPIONAGE_MISSION_REQUIRES_PROBES%';
    insert into t_ecr(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. a mixed probe+fighter ESPIONAGE fleet is refused (%s)', coalesce(v_err,'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 6. and the real flight produces a report that actually reveals (probes_sent = 3) */
    /* the resolver only requires status = 'ARRIVED', so the timeline is left untouched: back-dating
       `arrives_at` would violate fleet_movements_time_chk (arrives_at >= started_at). */
    update public.fleet_movements set status = 'ARRIVED' where id = v_fleet;
    perform public.resolve_espionage_arrival(v_fleet);
    select * into v_report from public.get_player_espionage_reports(50) r where r.out_fleet_id = v_fleet;
    v_ok := v_report.out_report_id is not null and v_report.out_probes_sent = 3;
    insert into t_ecr(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. the probe flight yields a real report: probes_sent=%s', v_report.out_probes_sent));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 7. REGRESSION: RECYCLE still refuses a non-recycler fleet (the rule this one mirrors) */
    v_err := null;
    begin
        perform public.start_fleet_mixed(v_player, v_planet, v_target, '{"light_fighter": 1}'::jsonb, 'RECYCLE');
    exception when others then v_err := sqlerrm; end;
    v_ok := v_err is not null and v_err not ilike '%ESPIONAGE%';
    insert into t_ecr(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. RECYCLE still refuses a non-recycler fleet, unchanged (%s)', coalesce(v_err,'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 8. REGRESSION: the new guard is scoped to ESPIONAGE. The live player has a single fleet slot and
          step 4 already consumed it, so the honest assertion is that ATTACK fails for the SLOT reason
          and NEVER with the espionage message — i.e. the guard did not leak into other missions. */
    v_err := null;
    begin
        perform public.start_fleet_mixed(v_player, v_planet, v_target, '{"light_fighter": 2}'::jsonb, 'ATTACK');
    exception when others then v_err := sqlerrm; end;
    v_ok := v_err is not null and v_err not ilike '%ESPIONAGE_MISSION_REQUIRES_PROBES%';
    insert into t_ecr(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. ATTACK never raises the espionage guard; it fails on its own reason (%s)', coalesce(v_err,'accepted')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 9. ownership is unchanged: an anonymous session still cannot dispatch */
    v_err := null;
    begin
        perform set_config('request.jwt.claims', '{}', true);
        perform public.start_fleet_mixed(v_player, v_planet, v_target, '{"espionage_probe": 1}'::jsonb, 'ESPIONAGE');
    exception when others then v_err := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    v_ok := v_err ilike '%Authentication required%' or v_err ilike '%does not belong to authenticated user%';
    insert into t_ecr(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. an anonymous session still cannot dispatch (%s)', coalesce(v_err,'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 10. the resolver was NOT touched: the level-gating rule still lives only there */
    v_ok := (select p.prosrc::text not ilike '%ESPIONAGE_MISSION_REQUIRES_PROBES%'
               from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'resolve_espionage_arrival');
    insert into t_ecr(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10. the resolver does not carry the dispatch guard (level gating untouched)');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 11. ACL unchanged on both dispatchers */
    v_ok := has_function_privilege('authenticated', 'public.start_fleet(uuid,uuid,uuid,text,bigint,text)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.start_fleet_mixed(uuid,uuid,uuid,jsonb,text)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.start_fleet(uuid,uuid,uuid,text,bigint,text)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.start_fleet_mixed(uuid,uuid,uuid,jsonb,text)', 'EXECUTE');
    insert into t_ecr(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '11. ACL unchanged: both dispatchers authenticated/service_role, anon denied');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    insert into t_ecr(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness with ROLLBACK; concurrency not executed.');
    insert into t_ecr(resultado, prueba) values ('INFO', format('SUMMARY: %s failed assertion(s).', v_fails));
    if v_fails > 0 then
        raise exception 'ESPIONAGE MISSION COMPOSITION: % failed assertion(s)', v_fails;
    end if;
end;
$test$;

select orden, resultado, prueba from t_ecr order by orden;

drop table if exists t_ecr;

ROLLBACK;

      format('2. the refusal is atomic: 0 ESPIONAGE movements persisted, light_fighter still %s', v_lf));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 3. the single-ship dispatcher refuses it too */
    v_err := null;
    begin
        perform public.start_fleet(v_player, v_planet, v_target, 'light_fighter', 1, 'ESPIONAGE');
    exception when others then v_err := sqlerrm; end;
    v_ok := v_err ilike '%ESPIONAGE_MISSION_REQUIRES_PROBES%';
    insert into t_ecr(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. start_fleet refuses a single light_fighter ESPIONAGE mission (%s)', coalesce(v_err,'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;
