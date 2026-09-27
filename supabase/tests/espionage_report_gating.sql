-- ESPIONAGE REPORT LEVEL GATING FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional fixture: it always ends in ROLLBACK.
--
-- Contract under test (authority: public.resolve_espionage_arrival, the single writer of espionage_reports):
--
--   level_gap       = max(0, target_espionage_level - attacker_espionage_level)
--   remaining       = max(0, probes_sent - level_gap ^ 2)
--   reveal_ships    = remaining >= 2  or  attacker_level - 1 >= target_level
--   reveal_defenses = remaining >= 3  or  attacker_level - 2 >= target_level
--   resources       = stored unconditionally (metal, crystal, deuterium)
--
-- This is the OGameX @7c420bad convention verbatim: `canRevealData($remaining, $attacker, $defender, 2, 1)` for
-- ships and `(…, 3, 2)` for defense, with `$extraProbesRequired = pow($levelDifference, 2)`. OGameX also reveals
-- buildings (5, 3) and research (7, 4); LGI has no such columns in the report at all (the research/action client
-- contract was retired by 20260921140925_retire_research_action_candidates_client_contract), so nothing to gate.
--
-- The counter-espionage chance is 0 whenever attacker_level >= defender_level + 1 — exactly the level threshold
-- that reveals ships — so the level cases run with no battle at all. In the probe-only cases a battle may happen,
-- which does not affect the assertion: OGameX combat spares or destroys a whole unit (never damages it), only
-- probes take part, and the defender's light fighters always survive.
--
-- LIMITATION: single-session harness with ROLLBACK, like every fixture of this repository.

begin;

drop table if exists t_eg;
create temp table t_eg(orden serial, resultado text, prueba text);

do $test$
declare
    v_attacker uuid; v_auth uuid; v_origin uuid; v_target uuid; v_target_owner uuid;
    v_fleet uuid; v_report public.espionage_reports%rowtype;
    v_pr record; v_expected numeric;
    v_ok boolean; v_fail integer := 0; v_lvl integer; v_cnt integer; v_hidden_report uuid; v_moon uuid;
begin
    select pl.id, pl.user_id into v_attacker, v_auth from public.players pl
     where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_origin from public.planets p
     where p.player_id = v_attacker and not p.is_destroyed order by p.created_at limit 1;
    select p.id, p.player_id into v_target, v_target_owner from public.planets p
     where p.player_id is not null and p.player_id <> v_attacker and not p.is_destroyed
     order by p.created_at limit 1;

    if v_origin is null or v_target is null or v_auth is null then
        raise exception 'TEST_ABORT: needs the auth-linked player, one of its planets and a foreign owned planet';
    end if;

    insert into public.player_research(player_id, research_id, level) values (v_attacker, 'computer_technology', 60)
      on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, 60);
    /* the legacy human may not carry an `espionage_technology` row at all: upsert it so the level writes below bite */
    insert into public.player_research(player_id, research_id, level) values (v_attacker, 'espionage_technology', 0)
      on conflict (player_id, research_id) do update set level = 0;
    insert into public.player_research(player_id, research_id, level)
    select v_target_owner, 'espionage_technology', 0
      where v_target_owner is not null
    on conflict (player_id, research_id) do update set level = 0;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* fixed garrison: whole ships survive OGameX combat, defenses never take part in counter-espionage */
    delete from public.planet_ships where planet_id = v_target;
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_target, 'light_fighter', 3);
    delete from public.planet_defenses where planet_id = v_target;
    insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_target, 'rocket_launcher', 5);
    update public.planet_resources set metal = 1000, crystal = 2000, deuterium = 3000, energy = 40,
           last_calculated_at = now() where planet_id = v_target;

    /* ============ 1. LEVEL LADDER against a level-0 defender, ONE probe ============ */
    update public.player_research set level = 0 where player_id = v_target_owner and research_id = 'espionage_technology';
    for v_lvl in 0..4 loop
        update public.player_research set level = v_lvl where player_id = v_attacker and research_id = 'espionage_technology';
        insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type,
            started_at, arrives_at, status, destination_galaxy, destination_system, destination_position)
        select v_attacker, v_origin, v_target, 'ESPIONAGE', clock_timestamp() - interval '20 minutes',
               clock_timestamp(), 'ARRIVED', p.galaxy, p.system, p.position
        from public.planets p where p.id = v_target returning id into v_fleet;
        insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'espionage_probe', 1);
        perform set_config('request.jwt.claims', '', true);   /* the fleet worker resolves without a session */
        perform public.resolve_espionage_arrival(v_fleet);
        perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
        select * into v_report from public.espionage_reports where fleet_id = v_fleet;

        if v_lvl = 0 then
            v_ok := v_report.fleet = '{}'::jsonb and v_report.defenses = '{}'::jsonb;
        elsif v_lvl = 1 then
            v_ok := v_report.fleet = '{"light_fighter": 3}'::jsonb and v_report.defenses = '{}'::jsonb;
        else
            v_ok := v_report.fleet = '{"light_fighter": 3}'::jsonb and v_report.defenses = '{"rocket_launcher": 5}'::jsonb;
        end if;
        insert into t_eg(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
          format('1.%s level %s vs 0 with 1 probe: fleet=%s defenses=%s', v_lvl, v_lvl, v_report.fleet, v_report.defenses));
        v_fail := v_fail + case when v_ok then 0 else 1 end;
        if v_lvl = 0 then v_hidden_report := v_report.id; end if;
    end loop;

    /* ============ 2. RESOURCES ARE NEVER GATED, even when both categories are hidden ============ */
    select * into v_report from public.espionage_reports er where er.id = v_hidden_report;
    v_ok := v_report.fleet = '{}'::jsonb and v_report.defenses = '{}'::jsonb
            and v_report.metal = 1000 and v_report.crystal = 2000 and v_report.deuterium = 3000;
    insert into t_eg(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. a fully hidden report still carries the resources (%s/%s/%s) — OGameX stores them unconditionally',
             v_report.metal, v_report.crystal, v_report.deuterium));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 3. `energy` COLUMN = THE DOCUMENTED SHIP-ATTACK AGGREGATE ============ */
    select * into v_report from public.espionage_reports er
     where er.player_id = v_attacker and er.target_planet_id = v_target
     order by er.created_at desc, er.id desc limit 1;
    select coalesce(sum(ps.quantity * sd.attack), 0) into v_expected
      from public.planet_ships ps join public.ship_definitions sd on sd.id = ps.ship_id
     where ps.planet_id = v_target;
    v_ok := v_report.energy = v_expected;
    insert into t_eg(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. energy column = ship attack aggregate (%s = %s): LGI contract, pinned; OGameX stores the planet energy instead (DEFERRED, README_FLEET_ENGINE §26)',
             v_report.energy, v_expected));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 4. PROBE BUDGET against a LEVEL GAP (defender level 2) ============ */
    update public.player_research set level = 0 where player_id = v_attacker and research_id = 'espionage_technology';
    update public.player_research set level = 2 where player_id = v_target_owner and research_id = 'espionage_technology';

    /* 4a. one probe cannot pay the gap^2 = 4 -> nothing revealed at all */
    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position)
    select v_attacker, v_origin, v_target, 'ESPIONAGE', clock_timestamp() - interval '20 minutes',
           clock_timestamp(), 'ARRIVED', p.galaxy, p.system, p.position
    from public.planets p where p.id = v_target returning id into v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'espionage_probe', 1);
    perform set_config('request.jwt.claims', '', true);
    perform public.resolve_espionage_arrival(v_fleet);
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    select * into v_report from public.espionage_reports where fleet_id = v_fleet;
    v_ok := v_report.fleet = '{}'::jsonb and v_report.defenses = '{}'::jsonb
            and v_report.espionage_level = 0 and v_report.target_espionage_level = 2;
    insert into t_eg(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4a. gap 2 with 1 probe: remaining 0, everything hidden (fleet=%s defenses=%s)', v_report.fleet, v_report.defenses));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 4b. 6 probes pay the gap^2 and leave 2 -> ships revealed by probes alone, defenses still hidden */
    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position)
    select v_attacker, v_origin, v_target, 'ESPIONAGE', clock_timestamp() - interval '20 minutes',
           clock_timestamp(), 'ARRIVED', p.galaxy, p.system, p.position
    from public.planets p where p.id = v_target returning id into v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'espionage_probe', 6);
    perform set_config('request.jwt.claims', '', true);
    perform public.resolve_espionage_arrival(v_fleet);
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    select * into v_report from public.espionage_reports where fleet_id = v_fleet;
    v_ok := v_report.fleet = '{"light_fighter": 3}'::jsonb and v_report.defenses = '{}'::jsonb;
    insert into t_eg(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4b. gap 2 with 6 probes: remaining 2 -> ships revealed by the probe budget, defenses hidden (fleet=%s defenses=%s)',
             v_report.fleet, v_report.defenses));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 4c. 8 probes leave 4 -> the probe budget beats the level gap entirely */
    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position)
    select v_attacker, v_origin, v_target, 'ESPIONAGE', clock_timestamp() - interval '20 minutes',
           clock_timestamp(), 'ARRIVED', p.galaxy, p.system, p.position
    from public.planets p where p.id = v_target returning id into v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'espionage_probe', 8);
    perform set_config('request.jwt.claims', '', true);
    perform public.resolve_espionage_arrival(v_fleet);
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    select * into v_report from public.espionage_reports where fleet_id = v_fleet;
    v_ok := v_report.fleet = '{"light_fighter": 3}'::jsonb and v_report.defenses = '{"rocket_launcher": 5}'::jsonb;
    insert into t_eg(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4c. gap 2 with 8 probes: remaining 4 -> both categories revealed (fleet=%s defenses=%s)',
             v_report.fleet, v_report.defenses));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 5. MIXED LEVEL FRONTIER: ships yes, defenses no, and NO battle at all ============ */
    /* attacker 3 vs defender 2 -> chance 0 (3 >= 2 + 1); (3-1) >= 2 reveals ships, (3-2) < 2 hides defenses */
    update public.player_research set level = 3 where player_id = v_attacker and research_id = 'espionage_technology';
    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position)
    select v_attacker, v_origin, v_target, 'ESPIONAGE', clock_timestamp() - interval '20 minutes',
           clock_timestamp(), 'ARRIVED', p.galaxy, p.system, p.position
    from public.planets p where p.id = v_target returning id into v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'espionage_probe', 1);
    perform set_config('request.jwt.claims', '', true);
    perform public.resolve_espionage_arrival(v_fleet);
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    select * into v_report from public.espionage_reports where fleet_id = v_fleet;
    v_ok := v_report.fleet = '{"light_fighter": 3}'::jsonb and v_report.defenses = '{}'::jsonb
            and v_report.counter_espionage_chance = 0 and v_report.counter_espionage_triggered = false
            and v_report.probes_lost = 0
            and (select coalesce(sum(fms.quantity), 0) from public.fleet_movement_ships fms where fms.fleet_id = v_fleet) = 1
            and (select count(*) from public.combat_battles cb where cb.fleet_id = v_fleet) = 0;
    insert into t_eg(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. level 3 vs 2 with 1 probe: fleet=%s defenses=%s chance=%s probes_lost=%s / no battle',
             v_report.fleet, v_report.defenses, v_report.counter_espionage_chance, v_report.probes_lost));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 6. FULL LEVEL REVEAL: attacker 4 vs defender 2 ============ */
    update public.player_research set level = 4 where player_id = v_attacker and research_id = 'espionage_technology';
    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position)
    select v_attacker, v_origin, v_target, 'ESPIONAGE', clock_timestamp() - interval '20 minutes',
           clock_timestamp(), 'ARRIVED', p.galaxy, p.system, p.position
    from public.planets p where p.id = v_target returning id into v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'espionage_probe', 1);
    perform set_config('request.jwt.claims', '', true);
    perform public.resolve_espionage_arrival(v_fleet);
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    select * into v_report from public.espionage_reports where fleet_id = v_fleet;
    v_ok := v_report.fleet = '{"light_fighter": 3}'::jsonb and v_report.defenses = '{"rocket_launcher": 5}'::jsonb
            and v_report.counter_espionage_chance = 0;
    insert into t_eg(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. level 4 vs 2 with 1 probe: both categories revealed through the level path (fleet=%s defenses=%s)',
             v_report.fleet, v_report.defenses));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 7. MOON: the same authority and the same thresholds gate a moon target ============ */
    /* a moon shares its parent's coordinates (enforced by the certified kind-consistency trigger) */
    insert into public.planets(universe_id, player_id, name, galaxy, system, position, kind, parent_planet_id,
                               moon_diameter_km, fields_total, fields_used, is_homeworld)
    select p.universe_id, p.player_id, 'Gating moon', p.galaxy, p.system, p.position, 'MOON', p.id, 6000, 3, 0, false
      from public.planets p where p.id = v_target
    returning id into v_moon;

    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at, updated_at)
    values (v_moon, 10, 20, 30, 0, now(), now());
    insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_moon, 'rocket_launcher', 7);
    update public.player_research set level = 0 where player_id = v_target_owner and research_id = 'espionage_technology';
    update public.player_research set level = 0 where player_id = v_attacker and research_id = 'espionage_technology';

    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position)
    select v_attacker, v_origin, v_moon, 'ESPIONAGE', clock_timestamp() - interval '20 minutes',
           clock_timestamp(), 'ARRIVED', p.galaxy, p.system, p.position
    from public.planets p where p.id = v_moon returning id into v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'espionage_probe', 1);
    perform set_config('request.jwt.claims', '', true);
    perform public.resolve_espionage_arrival(v_fleet);
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    select * into v_report from public.espionage_reports where fleet_id = v_fleet;
    v_ok := v_report.defenses = '{}'::jsonb and v_report.fleet = '{}'::jsonb;

    update public.player_research set level = 2 where player_id = v_attacker and research_id = 'espionage_technology';
    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position)
    select v_attacker, v_origin, v_moon, 'ESPIONAGE', clock_timestamp() - interval '20 minutes',
           clock_timestamp(), 'ARRIVED', p.galaxy, p.system, p.position
    from public.planets p where p.id = v_moon returning id into v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'espionage_probe', 1);
    perform set_config('request.jwt.claims', '', true);
    perform public.resolve_espionage_arrival(v_fleet);
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    select * into v_report from public.espionage_reports where fleet_id = v_fleet;

    v_ok := v_ok and v_report.defenses = '{"rocket_launcher": 7}'::jsonb and v_report.metal = 10;
    insert into t_eg(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. moon: level 0 hides its defenses, level 2 reveals them (%s); resources stay ungated (%s)',
             v_report.defenses, v_report.metal));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 8. CLIENT BYPASS: a direct SELECT as a client role reads nothing ============ */
    v_ok := false;
    begin
        set local role authenticated;
        select count(*) into v_cnt from public.espionage_reports;
        reset role;
        v_ok := (v_cnt = 0);
    exception when others then
        reset role;
        v_ok := false;
    end;
    if v_ok then
        begin
            set local role anon;
            select count(*) into v_cnt from public.espionage_reports;
            reset role;
            v_ok := (v_cnt = 0);
        exception when others then
            reset role;
            v_ok := false;
        end;
    end if;
    insert into t_eg(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. neither `authenticated` nor `anon` reads espionage_reports directly (deny_direct_api_access): last count %s', v_cnt));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 9. THE READ RPC CANNOT MINE MORE THAN THE STORED SNAPSHOT ============ */
    v_ok := false;
    begin
        set local role authenticated;
        select count(*) into v_cnt from public.get_player_espionage_reports(200) g
         where g.out_report_id = v_hidden_report and g.out_player_id = v_attacker
           and g.out_fleet = '{}'::jsonb and g.out_defenses = '{}'::jsonb;
        /* v_lvl is reused here as the "foreign report" counter */
        select count(*) into v_lvl from public.get_player_espionage_reports(200) g where g.out_player_id <> v_attacker;
        reset role;
        v_ok := (v_cnt = 1 and v_lvl = 0);
    exception when others then
        reset role;
    end;
    insert into t_eg(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. as `authenticated`, the owner RPC returns the hidden report with empty categories (%s row) and no foreign report (%s)', v_cnt, v_lvl));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 10. A STORED SNAPSHOT NEVER GAINS INFORMATION ============ */
    update public.player_research set level = 7 where player_id = v_attacker and research_id = 'espionage_technology';
    select * into v_report from public.espionage_reports where id = v_hidden_report;
    v_ok := v_report.fleet = '{}'::jsonb and v_report.defenses = '{}'::jsonb and v_report.espionage_level = 0;
    insert into t_eg(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10. raising the attacker to level 7 does not upgrade an existing report: the gating is a snapshot taken at arrival');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 11. NORMAL FLOW INTACT + AUTHORITY ACL ============ */
    v_ok := (select count(*) from public.fleet_movements fm
              where fm.player_id = v_attacker and fm.mission_type = 'ESPIONAGE') =
            (select count(*) from public.espionage_reports er
              where er.fleet_id in (select fm.id from public.fleet_movements fm
                                     where fm.player_id = v_attacker and fm.mission_type = 'ESPIONAGE'))
            and not has_function_privilege('authenticated', 'public.resolve_espionage_arrival(uuid)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.get_player_espionage_reports(integer)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.get_player_espionage_reports(integer)', 'EXECUTE')
            and has_function_privilege('service_role', 'public.resolve_espionage_arrival(uuid)', 'EXECUTE')
            and not has_table_privilege('authenticated', 'public.espionage_reports', 'INSERT')
            and not has_table_privilege('authenticated', 'public.espionage_reports', 'UPDATE');
    insert into t_eg(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '11. one report per fleet, writer service_role only, reader authenticated only, and the client cannot INSERT/UPDATE the table');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_eg(resultado, prueba) values ('INFO',
      'OGameX @7c420bad comparison: ships (probe 2 / level 1) and defense (probe 3 / level 2) match LGI verbatim; buildings (5, 3) and research (7, 4) are absent from the LGI report contract, so nothing is gated there.');

    if v_fail > 0 then
        raise exception 'ESPIONAGE GATING FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select case when count(*) filter (where resultado = 'FAIL') = 0 then 'PASS' else 'FAIL' end as final,
       count(*) filter (where resultado = 'PASS') as passed,
       count(*) filter (where resultado <> 'INFO') as assertions
  from t_eg;

select orden, resultado, prueba from t_eg order by orden;

drop table if exists t_eg;

rollback;
