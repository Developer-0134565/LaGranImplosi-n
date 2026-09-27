-- COUNTER-ESPIONAGE FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
-- Contract (migrations 20260926124000 / ...4010 / ...4020): OGameX chance formula verbatim; a triggered battle of
-- the probes against the target's SHIPS only, run by the existing combat engine; losses written back; debris at the
-- target; OGameX reveal gating; defender notification; a report written even when every probe dies; replay safety.
-- LIMITATION: single-session harness, real concurrency not executed.

begin;

drop table if exists t_ce;
create temp table t_ce(orden serial, resultado text, prueba text);

do $test$
declare
    v_attacker uuid; v_auth uuid; v_origin uuid; v_target uuid; v_target_owner uuid;
    v_fleet uuid; v_battle uuid; v_report public.espionage_reports%rowtype;
    v_ships_before bigint; v_ships_after bigint; v_probes bigint; v_debris numeric;
    v_ok boolean; v_fail integer := 0; v_state text; v_n integer; v_raised text;
begin
    select pl.id, pl.user_id into v_attacker, v_auth from public.players pl
     where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_origin from public.planets p
     where p.player_id = v_attacker and not p.is_destroyed order by p.created_at limit 1;
    select p.id, p.player_id into v_target, v_target_owner from public.planets p
     where p.player_id is not null and p.player_id <> v_attacker and not p.is_destroyed
     order by p.created_at limit 1;

    if v_origin is null or v_target is null then
        raise exception 'TEST_ABORT: the fixture needs the auth-linked player and a foreign owned planet';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* 1. the OGameX chance formula, verbatim */
    v_ok := public.calculate_counter_espionage_chance(0, 0, 0, 10) = 0
            and public.calculate_counter_espionage_chance(5, 0, 0, 0) = 0
            and public.calculate_counter_espionage_chance(4, 0, 0, 10) = 62
            and public.calculate_counter_espionage_chance(1, 5, 0, 1000) = 0
            and public.calculate_counter_espionage_chance(1, 0, 0, 10000) = 100;
    insert into t_ce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '1. chance: no probes 0, no ships 0, 10 ships/4 probes 62, attacker 2+ ahead 0, clamped 100');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* scenario A: guaranteed counter-espionage (chance 100) and a reveal gap (attacker 0 vs defender 2) */
    insert into public.player_research(player_id, research_id, level)
    values (v_attacker, 'espionage_technology', 0)
    on conflict (player_id, research_id) do update set level = 0;

    insert into public.player_research(player_id, research_id, level)
    values (v_target_owner, 'espionage_technology', 2)
    on conflict (player_id, research_id) do update set level = 2;

    delete from public.planet_ships where planet_id = v_target;
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_target, 'light_fighter', 40);

    delete from public.player_messages
     where recipient_player_id in (v_attacker, v_target_owner) and dedupe_key is not null;

    delete from public.debris_fields df
     where df.universe_id = (select p.universe_id from public.planets p where p.id = v_target)
       and df.galaxy = (select p.galaxy from public.planets p where p.id = v_target)
       and df.system = (select p.system from public.planets p where p.id = v_target)
       and df.position = (select p.position from public.planets p where p.id = v_target);

    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position)
    select v_attacker, v_origin, v_target, 'ESPIONAGE', clock_timestamp() - interval '20 minutes',
           clock_timestamp(), 'ARRIVED', p.galaxy, p.system, p.position
    from public.planets p where p.id = v_target
    returning id into v_fleet;

    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'espionage_probe', 3);

    select coalesce(sum(quantity), 0) into v_ships_before from public.planet_ships where planet_id = v_target;

    perform public.resolve_espionage_arrival(v_fleet);

    select * into v_report from public.espionage_reports where fleet_id = v_fleet;
    select coalesce(sum(quantity), 0) into v_ships_after from public.planet_ships where planet_id = v_target;
    select coalesce(sum(quantity), 0) into v_probes from public.fleet_movement_ships where fleet_id = v_fleet;
    select fm.status into v_state from public.fleet_movements fm where fm.id = v_fleet;


    v_ok := v_report.id is not null and v_report.counter_espionage_chance = 100
            and v_report.counter_espionage_triggered = true and v_report.probes_sent = 3;
    insert into t_ce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. report stores chance %s, trigger %s, probes %s',
             v_report.counter_espionage_chance, v_report.counter_espionage_triggered, v_report.probes_sent));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := v_report.fleet = '{}'::jsonb and v_report.defenses = '{}'::jsonb
            and v_report.espionage_level = 0 and v_report.target_espionage_level = 2;
    insert into t_ce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. reveal gating: attacker 0 vs defender 2 hides ships (fleet=%s)', v_report.fleet));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select cb.id into v_battle from public.combat_battles cb where cb.fleet_id = v_fleet;
    select count(*)::integer into v_n from public.combat_battles cb
     where cb.fleet_id = v_fleet and cb.defender_planet_id = v_target;
    v_ok := v_n = 1;
    insert into t_ce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. a real battle was created against the target planet (%s)', v_n));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := exists (select 1 from public.combat_battle_participants cp
                     where cp.battle_id = v_battle and cp.side = 'DEFENDER' and cp.participant_type = 'PLANET')
            and not exists (select 1 from public.combat_individual_units u
                             where u.battle_id = v_battle and u.unit_type = 'DEFENSE');
    insert into t_ce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '5. defendant is a PLANET participant and no defence structure took part');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := v_report.probes_lost = 3 and v_probes = 0;
    insert into t_ce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. every probe died: probes_lost %s, surviving ship rows %s', v_report.probes_lost, v_probes));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := v_state = 'COMPLETED';
    insert into t_ce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. a wiped flight goes to COMPLETED instead of a ghost return (%s)', v_state));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := v_ships_after = v_ships_before;
    insert into t_ce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. defender ships untouched when probes cannot damage them (%s -> %s)', v_ships_before, v_ships_after));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select coalesce(sum(df.crystal), 0) into v_debris from public.debris_fields df
     where df.universe_id = (select p.universe_id from public.planets p where p.id = v_target)
       and df.galaxy = (select p.galaxy from public.planets p where p.id = v_target)
       and df.system = (select p.system from public.planets p where p.id = v_target)
       and df.position = (select p.position from public.planets p where p.id = v_target);
    v_ok := v_debris > 0
            and exists (select 1 from public.combat_debris_generations g where g.battle_id = v_battle);
    insert into t_ce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. destroyed probes left debris at the target (%s crystal, generation row present)', v_debris));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*)::integer into v_n from public.player_messages pm
     where pm.dedupe_key in ('espionage_detected:' || v_fleet::text,
                             'espionage_report:' || v_fleet::text,
                             'fleet_lost_contact:' || v_fleet::text,
                             'battle_report_defender:' || v_battle::text);
    v_ok := v_n = 4;
    insert into t_ce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. messages: espied + report + lost contact + defender battle report (%s/4)', v_n));

    /* 11. replay safety */
    v_raised := null;
    begin
        perform public.resolve_espionage_arrival(v_fleet);
    exception when others then
        v_raised := sqlerrm;
    end;

    select count(*)::integer into v_n from public.espionage_reports er where er.fleet_id = v_fleet;
    v_ok := v_raised like 'Espionage must be ARRIVED%' and v_n = 1;
    insert into t_ce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11. a replay is refused (%s) and the report is not duplicated (%s row)', coalesce(v_raised, 'no error'), v_n));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 12. no defender ships: chance 0, probes survive, ships revealed, normal return */
    insert into public.player_research(player_id, research_id, level)
    values (v_attacker, 'espionage_technology', 5)
    on conflict (player_id, research_id) do update set level = 5;

    /* the defender is two levels behind: the technology factor is <= 0, so no battle even with ships present */
    update public.player_research set level = 0
     where player_id = v_target_owner and research_id = 'espionage_technology';

    delete from public.planet_ships where planet_id = v_target;
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_target, 'light_fighter', 3);

    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position)
    select v_attacker, v_origin, v_target, 'ESPIONAGE', clock_timestamp() - interval '20 minutes',
           clock_timestamp(), 'ARRIVED', p.galaxy, p.system, p.position
    from public.planets p where p.id = v_target
    returning id into v_fleet;

    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'espionage_probe', 2);

    perform public.resolve_espionage_arrival(v_fleet);

    select * into v_report from public.espionage_reports where fleet_id = v_fleet;
    select fm.status, coalesce((select sum(fms.quantity) from public.fleet_movement_ships fms where fms.fleet_id = fm.id), 0)
      into v_state, v_probes
      from public.fleet_movements fm where fm.id = v_fleet;

    v_ok := v_report.counter_espionage_chance = 0 and v_report.counter_espionage_triggered = false
            and v_state = 'RETURNING' and v_probes = 2
            and v_report.fleet = '{"light_fighter": 3}'::jsonb;
    insert into t_ce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('12. attacker two levels ahead: chance 0, probes survive and return, ships revealed (%s, %s probes, fleet %s)',
             v_state, v_probes, v_report.fleet));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 13. ACL */
    v_ok := not has_function_privilege('authenticated', 'public.resolve_espionage_arrival(uuid)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.get_planet_defender_ship_count(uuid)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.get_player_espionage_reports(integer)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.get_player_espionage_reports(integer)', 'EXECUTE');
    insert into t_ce(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '13. ACL: resolver and helpers internal, report contract client-readable');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_ce(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; the concurrent case is not executed.');

    if v_fail > 0 then
        raise exception 'COUNTER-ESPIONAGE FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_ce order by orden;

drop table if exists t_ce;

ROLLBACK;
