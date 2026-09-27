-- RESEARCH LAB + GATES + IRN FIXTURE — LA GRAN IMPLOSIÓN
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
-- Contract (20260926180000): OGameX research_lab (200/400/200, factor 2, PLANET only, no cap),
-- the 16 ResearchObjects gates, and IRN = own lab + sum of the N highest labs of the player's OTHER
-- eligible planets (PlanetService::getResearchNetworkLabLevel), ported to LGI's curve as the divisor ratio
-- (1 + own) / (1 + effective) → exactly 1 when IRN = 0 (zero behaviour change).
-- LIMITATION: single-session harness; no cron involvement, time assertions use a ±2 s band.
-- 2026-09-27: assertions 9b (IRN above the number of available labs) and 9c (ownership: a foreign player's
-- laboratory never enters the network) added to close the two cases the mission's test list requires and the
-- 2026-09-26 fixture did not cover. No production contract was touched.

begin;

drop table if exists t_rl;
create temp table t_rl(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_universe uuid; v_planet uuid; v_moon uuid; v_p2 uuid; v_p3 uuid;
    v_queue uuid; v_own integer; v_eff integer; v_canonical numeric; v_expected numeric;
    v_actual numeric; v_own_time numeric; v_ok boolean; v_fail integer := 0; v_raised text; v_inspect record;
    v_i integer; v_galaxy integer; v_foreign_player uuid; v_foreign_planet uuid;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_planet from public.planets p
     where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET' order by p.created_at limit 1;

    if v_player is null or v_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet is required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    delete from public.research_queue where player_id = v_player;
    delete from public.planet_buildings where planet_id = v_planet;
    delete from public.planets where parent_planet_id = v_planet;
    delete from public.planets where player_id = v_player and id <> v_planet and is_destroyed = false;
    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at, updated_at)
    values (v_planet, 5000000, 5000000, 5000000, 0, now(), now())
    on conflict (planet_id) do update
       set metal = 5000000, crystal = 5000000, deuterium = 5000000, last_calculated_at = now();

    v_ok := exists (select 1 from public.building_definitions
                     where id = 'research_lab' and base_metal = 200 and base_crystal = 400 and base_deuterium = 200
                       and cost_factor = 2 and max_level is null and valid_kinds = '{PLANET}')
            and (select count(*) from public.research_building_prerequisites where building_id = 'research_lab') = 16
            and exists (select 1 from public.research_building_prerequisites
                         where research_id = 'graviton_technology' and required_level = 12)
            and exists (select 1 from public.research_building_prerequisites
                         where research_id = 'intergalactic_research_network' and required_level = 10)
            and exists (select 1 from public.research_building_prerequisites
                         where research_id = 'armour_technology' and required_level = 2);
    insert into t_rl(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '1. research_lab definition (200/400/200, factor 2, PLANET, no cap) + 16 OGameX gates');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select * into v_inspect from public.can_start_research(v_player, v_planet, 'energy_technology');
    v_raised := null;
    begin
        perform public.start_research(v_player, v_planet, 'energy_technology');
    exception when others then
        v_raised := sqlerrm;
    end;
    v_ok := not v_inspect.allowed and v_raised is not null and v_raised not like '%NOT_FOUND%';
    insert into t_rl(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. no lab → refused (can_start reason=%s, start=%s)', v_inspect.reason, coalesce(v_raised, 'accepted')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 3. gate levels: lab 1 / 3 / 4 against energy (1) and ion (4) */
    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'research_lab', 1);

    /* ion_technology also needs laser 5 + energy 4 (LGI research_prerequisites), which are player-wide */
    insert into public.player_research(player_id, research_id, level) values
        (v_player, 'laser_technology', 5), (v_player, 'energy_technology', 4)
    on conflict (player_id, research_id) do update set level = excluded.level;
    select * into v_inspect from public.can_start_research(v_player, v_planet, 'energy_technology');
    insert into t_rl(resultado, prueba) values (case when v_inspect.allowed then 'PASS' else 'FAIL' end,
      format('3a. lab 1 allows energy_technology (%s)', v_inspect.reason));
    v_fail := v_fail + case when v_inspect.allowed then 0 else 1 end;

    update public.planet_buildings set level = 3 where planet_id = v_planet and building_id = 'research_lab';
    select * into v_inspect from public.can_start_research(v_player, v_planet, 'ion_technology');
    insert into t_rl(resultado, prueba) values (case when not v_inspect.allowed then 'PASS' else 'FAIL' end,
      format('3b. lab 3 refuses ion_technology (needs 4): %s', v_inspect.reason));
    v_fail := v_fail + case when not v_inspect.allowed then 0 else 1 end;

    update public.planet_buildings set level = 4 where planet_id = v_planet and building_id = 'research_lab';
    select * into v_inspect from public.can_start_research(v_player, v_planet, 'ion_technology');
    insert into t_rl(resultado, prueba) values (case when v_inspect.allowed then 'PASS' else 'FAIL' end,
      '3c. lab 4 allows ion_technology');
    v_fail := v_fail + case when v_inspect.allowed then 0 else 1 end;

    /* 4. the laboratory is planet-only: queueing it on a moon is rejected by the kind authority */
    delete from public.planets where parent_planet_id = v_planet;
    insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
        temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind, parent_planet_id, moon_diameter_km)
    select v_universe, v_player, 'LabMoon', p.galaxy, p.system, p.position, -20, 20, 10, 0, false, false,
           'MOON', p.id, 2000 from public.planets p where p.id = v_planet
    returning id into v_moon;

    v_raised := null;
    begin
        insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status)
        values (v_moon, 'research_lab', 1, now(), now() + interval '1 hour', 'BUILDING');
    exception when others then
        v_raised := sqlerrm;
    end;
    v_ok := v_raised like 'BUILDING_NOT_AVAILABLE_FOR_KIND%';
    insert into t_rl(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. research_lab cannot be queued on a moon (%s)', coalesce(v_raised, 'accepted')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* a laboratory on a moon never joins the network (planet-only filter) */
    insert into public.planet_buildings(planet_id, building_id, level) values (v_moon, 'research_lab', 9);

    /* 5. IRN: two extra planets with labs 5 and 4 (free coordinates, unique-violation safe) */
    v_galaxy := coalesce((select max(p.galaxy) from public.planets p), 1);
    for v_i in 1..10 loop
        begin
            insert into public.planets(universe_id, player_id, name, galaxy, system, position, fields_total,
                fields_used, is_homeworld, is_destroyed, kind)
            values (v_universe, v_player, 'IrnP' || v_i, v_galaxy, 496 + ((v_i - 1) % 5), 11 + ((v_i - 1) / 5),
                100, 0, false, false, 'PLANET')
            returning id into v_p2;
            exit;
        exception when unique_violation then
            v_p2 := null;
        end;
    end loop;

    if v_p2 is null then
        raise exception 'TEST_ABORT: no free coordinates for the IRN planets';
    end if;

    for v_i in 1..10 loop
        begin
            insert into public.planets(universe_id, player_id, name, galaxy, system, position, fields_total,
                fields_used, is_homeworld, is_destroyed, kind)
            values (v_universe, v_player, 'IrnQ' || v_i, v_galaxy, 491 + ((v_i - 1) % 5), 11 + ((v_i - 1) / 5),
                100, 0, false, false, 'PLANET')
            returning id into v_p3;
            exit;
        exception when unique_violation then
            v_p3 := null;
        end;
    end loop;

    if v_p3 is null then
        raise exception 'TEST_ABORT: no free coordinates for the second IRN planet';
    end if;

    insert into public.planet_buildings(planet_id, building_id, level) values
        (v_p2, 'research_lab', 5), (v_p3, 'research_lab', 4);

    update public.planet_buildings set level = 3 where planet_id = v_planet and building_id = 'research_lab';
    delete from public.research_queue where player_id = v_player;
    delete from public.player_research where player_id = v_player
       and research_id in ('intergalactic_research_network', 'energy_technology', 'ion_technology');
    v_canonical := public.calculate_research_time('energy_technology', 1, v_universe);

    /* 6. IRN 0 → the network is inert and the curve is byte-identical */
    v_own := public.get_research_network_lab_level(v_player, v_planet, 'energy_technology');
    select crt.final_time_seconds into v_actual from public.calculate_research_time(v_player, v_planet, 'energy_technology', 1) crt;
    v_ok := v_own = 3 and v_actual = v_canonical
            and (select t.final_time_seconds from public.calculate_research_time(v_player, 'energy_technology', 1) t) = v_canonical;
    insert into t_rl(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. IRN 0 → own=%s time=%s (canonical %s, certified overload untouched)', v_own, v_actual, v_canonical));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 7. IRN 2 → own 3 + top-2 labs of other planets (5 + 4; the moon lab 9 is excluded) */
    insert into public.player_research(player_id, research_id, level) values
        (v_player, 'intergalactic_research_network', 2)
    on conflict (player_id, research_id) do update set level = 2;

    v_eff := public.get_research_network_lab_level(v_player, v_planet, 'energy_technology');
    v_expected := round(v_canonical * (4::numeric / 13), 4);
    select crt.final_time_seconds into v_actual from public.calculate_research_time(v_player, v_planet, 'energy_technology', 1) crt;
    v_ok := v_eff = 12 and v_actual = v_expected and v_actual < v_canonical;
    insert into t_rl(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. IRN 2 → effective %s, time %s (expected %s)', v_eff, v_actual, v_expected));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 8. IRN 1 → only the highest other lab counts (5) */
    update public.player_research set level = 1
     where player_id = v_player and research_id = 'intergalactic_research_network';
    v_eff := public.get_research_network_lab_level(v_player, v_planet, 'energy_technology');
    v_expected := round(v_canonical * (4::numeric / 9), 4);
    select crt.final_time_seconds into v_actual from public.calculate_research_time(v_player, v_planet, 'energy_technology', 1) crt;
    v_ok := v_eff = 8 and v_actual = v_expected;
    insert into t_rl(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. IRN 1 → effective %s, time %s (expected %s)', v_eff, v_actual, v_expected));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 9. eligibility: graviton needs lab 12, so labs 5/4 do not join the network */
    update public.player_research set level = 2
     where player_id = v_player and research_id = 'intergalactic_research_network';
    v_eff := public.get_research_network_lab_level(v_player, v_planet, 'graviton_technology');
    select crt.final_time_seconds into v_actual from public.calculate_research_time(v_player, v_planet, 'graviton_technology', 1) crt;
    v_ok := v_eff = 3 and v_actual = public.calculate_research_time('graviton_technology', 1, v_universe);
    insert into t_rl(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. eligibility filter keeps lab<12 planets out (effective %s)', v_eff));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 9b. IRN above the number of eligible labs uses the labs that exist (OGameX array_slice returns
       fewer elements than requested; nothing is invented and no level is counted twice). */
    update public.player_research set level = 10
     where player_id = v_player and research_id = 'intergalactic_research_network';
    v_eff := public.get_research_network_lab_level(v_player, v_planet, 'energy_technology');
    v_ok := v_eff = 12;
    insert into t_rl(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9b. IRN 10 with only 2 eligible other labs → effective %s (3 + 5 + 4)', v_eff));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 9c. ownership: another player's research_lab never enters the network, even though the effective
       level is computed from caller-supplied ids (the helper filters by p_player_id, never by "first
       planet" or any other global heuristic). */
    select pl.id into v_foreign_player
      from public.players pl where pl.id <> v_player order by pl.created_at, pl.id limit 1;

    if v_foreign_player is null then
        raise exception 'TEST_ABORT: a second player is required for the ownership assertion';
    end if;

    for v_i in 1..10 loop
        begin
            insert into public.planets(universe_id, player_id, name, galaxy, system, position, fields_total,
                fields_used, is_homeworld, is_destroyed, kind)
            values (v_universe, v_foreign_player, 'IrnForeign' || v_i, v_galaxy, 486 + ((v_i - 1) % 5),
                13 + ((v_i - 1) / 5), 100, 0, false, false, 'PLANET')
            returning id into v_foreign_planet;
            exit;
        exception when unique_violation then
            v_foreign_planet := null;
        end;
    end loop;

    if v_foreign_planet is null then
        raise exception 'TEST_ABORT: no free coordinates for the foreign planet';
    end if;

    insert into public.planet_buildings(planet_id, building_id, level)
    values (v_foreign_planet, 'research_lab', 20);

    v_eff := public.get_research_network_lab_level(v_player, v_planet, 'energy_technology');
    v_ok := v_eff = 12;
    insert into t_rl(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9c. ownership: a foreign lab 20 does not join the network (effective %s, expected 12)', v_eff));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 10. the dispatcher queues the network-reduced time (band ±2 s for the row timestamps) */
    /* 10. dispatcher: with IRN 2 the queued time is (1+own)/(1+effective) = 4/13 of the IRN-0 dispatch */
    delete from public.research_queue where player_id = v_player;
    delete from public.player_research where player_id = v_player and research_id = 'intergalactic_research_network';
    v_queue := public.start_research(v_player, v_planet, 'energy_technology');
    select extract(epoch from (q.finishes_at - q.started_at)) into v_own_time
      from public.research_queue q where q.id = v_queue;

    delete from public.research_queue where player_id = v_player;
    insert into public.player_research(player_id, research_id, level) values
        (v_player, 'intergalactic_research_network', 2);

    v_queue := public.start_research(v_player, v_planet, 'energy_technology');
    select extract(epoch from (q.finishes_at - q.started_at)) into v_actual
      from public.research_queue q where q.id = v_queue;

    v_expected := round(v_own_time * (4::numeric / 13), 4);
    v_ok := v_own_time > 0 and abs(v_actual - v_expected) < 2;
    insert into t_rl(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. dispatcher: IRN0 %s s → IRN2 %s s (expected 4/13 = %s)', v_own_time, v_actual, v_expected));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 11. ACL: no anon bypass on the new contracts */
    v_ok := not has_function_privilege('anon', 'public.get_research_network_lab_level(uuid,uuid,text)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.calculate_research_time(uuid,uuid,text,integer)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.get_research_network_lab_level(uuid,uuid,text)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.calculate_research_time(uuid,uuid,text,integer)', 'EXECUTE');
    insert into t_rl(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '11. ACL: laboratory/IRN contracts are authenticated/service_role only');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_rl(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness (no concurrency, no cron). Activating the 16 gates is an approved product change: players now need a Research Lab per the OGameX table; IRN applies OGameX''s divisor ratio to LGI''s own time curve and is inert at IRN 0.');

    if v_fail > 0 then
        raise exception 'RESEARCH LAB / IRN FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_rl order by orden;

drop table if exists t_rl;

ROLLBACK;
