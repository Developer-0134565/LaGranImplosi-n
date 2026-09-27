-- ESPIONAGE READ CONTRACT — REVEAL OUTCOME FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional fixture: it always ends in ROLLBACK.
--
-- Contracts under test (20260927120100 + 20260927130000):
--   `get_player_espionage_reports` exposes the four reveal-gated sections (`fleet`, `defenses`, `buildings`,
--   `research`) and the four reveal OUTCOMES (`out_ships_revealed`, `out_defenses_revealed`,
--   `out_buildings_revealed`, `out_research_revealed`), all decided at arrival by `resolve_espionage_arrival` with
--   the OGameX rule (EspionageMission.php @7c420bad3478d7099791e1f33c920e9ff92822e8):
--       remaining        = max(0, probes_sent - max(0, target_espionage_level - espionage_level) ^ 2)
--       reveal_ships     = remaining >= 2  or  espionage_level - 1 >= target_espionage_level
--       reveal_defenses  = remaining >= 3  or  espionage_level - 2 >= target_espionage_level
--       reveal_buildings = remaining >= 5  or  espionage_level - 3 >= target_espionage_level
--       reveal_research  = remaining >= 7  or  espionage_level - 4 >= target_espionage_level
--
-- The fixture drives the REAL resolver and then asserts, as `authenticated`, that every reported flag agrees with
-- the map the resolver actually stored — in every direction:
--
--   A. levels 0 vs 2, 1 probe   -> remaining 0 -> nothing revealed (maps stored empty)
--   B. levels 1 vs 2, 2 probes  -> remaining 1 -> still nothing revealed: the level gap eats the extra probe
--                                  (this is the `pow(levelDifference, 2)` rule, not a rounding artefact)
--   C. levels 0 vs 1, 3 probes  -> remaining 2 -> SHIPS revealed, DEFENCE not (2 >= 2, 2 < 3)
--   D. levels 1 vs 1, 5 probes  -> remaining 5 -> ships + defence + BUILDINGS (5 is the buildings threshold)
--   E. the four flags read the stored snapshot (researching further afterwards changes nothing)
--   G. TABLE-DRIVEN block over six level/probe configurations — remaining 2, 4, 5 and 7 probes, the level path with
--      a single probe, and a level gap that eats every probe — where the fixture DERIVES the expected outcome from
--      the OGameX rule itself and asserts: the four flags match that derivation, a denied section stored nothing
--      while a revealed one stored the target's real buildings/research, and the returned maps are the stored ones
--   F. ownership, the row-level closure of the table and the p_limit clamp are untouched
--
-- LIMITATION: single-session harness with ROLLBACK, like every fixture of this repository.

begin;

drop table if exists t_erf;
create temp table t_erf(orden serial, resultado text, prueba text);

do $test$
declare
    v_attacker uuid; v_auth uuid; v_origin uuid; v_target uuid; v_target_owner uuid;
    v_fleet uuid; v_report uuid; v_row record; v_report_row public.espionage_reports%rowtype;
    v_ok boolean; v_fail integer := 0; v_n integer;
    v_sc record; v_remaining numeric; v_expected_flags jsonb;
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

    /* a full fleet slot budget so the ESPIONAGE dispatch is never the limiting factor */
    insert into public.player_research(player_id, research_id, level) values (v_attacker, 'computer_technology', 60)
      on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, 60);

    /* the target OWNS a building and a research: a hidden section must be empty because of the RULE, never because
       the target happens to have nothing (that is the whole point of the gating) */
    insert into public.planet_buildings(planet_id, building_id, level) values (v_target, 'metal_mine', 5)
      on conflict (planet_id, building_id) do update set level = 5;
    insert into public.player_research(player_id, research_id, level) values (v_target_owner, 'energy_technology', 3)
      on conflict (player_id, research_id) do update set level = 3;

    /* a defence structure the target never loses, so a revealed defence section has a non-empty map */
    delete from public.planet_ships where planet_id = v_target;
    insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_target, 'rocket_launcher', 7)
      on conflict (planet_id, defense_id) do update set quantity = 7;

    /* ================= A. levels 0 vs 2, 1 probe: nothing revealed ================= */
    insert into public.player_research(player_id, research_id, level) values (v_attacker, 'espionage_technology', 0)
      on conflict (player_id, research_id) do update set level = 0;
    insert into public.player_research(player_id, research_id, level) values (v_target_owner, 'espionage_technology', 2)
      on conflict (player_id, research_id) do update set level = 2;

    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position)
    select v_attacker, v_origin, v_target, 'ESPIONAGE', clock_timestamp() - interval '20 minutes',
           clock_timestamp(), 'ARRIVED', p.galaxy, p.system, p.position
    from public.planets p where p.id = v_target
    returning id into v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'espionage_probe', 1);
    perform public.resolve_espionage_arrival(v_fleet);

    select * into v_report_row from public.espionage_reports where fleet_id = v_fleet;
    v_report := v_report_row.id;
    set local role authenticated;
    select * into v_row from public.get_player_espionage_reports(200) g where g.out_report_id = v_report;
    reset role;

    v_ok := v_row.out_ships_revealed = false and v_row.out_defenses_revealed = false
            and v_row.out_fleet = '{}'::jsonb and v_row.out_defenses = '{}'::jsonb
            and v_row.out_espionage_level = 0 and v_row.out_target_espionage_level = 2 and v_row.out_probes_sent = 1;
    insert into t_erf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('A. levels 0 vs 2 with 1 probe: ships %s / defence %s, both stored maps empty',
             v_row.out_ships_revealed, v_row.out_defenses_revealed));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ================= B. levels 1 vs 2, 2 probes: the gap eats the probe (remaining 1) ================= */
    update public.player_research set level = 1 where player_id = v_attacker and research_id = 'espionage_technology';

    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position)
    select v_attacker, v_origin, v_target, 'ESPIONAGE', clock_timestamp() - interval '20 minutes',
           clock_timestamp(), 'ARRIVED', p.galaxy, p.system, p.position
    from public.planets p where p.id = v_target
    returning id into v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'espionage_probe', 2);
    perform public.resolve_espionage_arrival(v_fleet);

    select * into v_report_row from public.espionage_reports where fleet_id = v_fleet;
    set local role authenticated;
    select * into v_row from public.get_player_espionage_reports(200) g where g.out_report_id = v_report_row.id;
    reset role;

    v_ok := v_row.out_probes_sent = 2
            and v_row.out_ships_revealed = false and v_row.out_defenses_revealed = false
            and v_row.out_fleet = '{}'::jsonb and v_row.out_defenses = '{}'::jsonb;
    insert into t_erf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('B. levels 1 vs 2 with 2 probes (remaining = 2 - 1^2 = 1): ships %s / defence %s, nothing revealed',
             v_row.out_ships_revealed, v_row.out_defenses_revealed));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ================= C. levels 0 vs 1, 3 probes: remaining 2 -> ships only ================= */
    update public.player_research set level = 0 where player_id = v_attacker and research_id = 'espionage_technology';
    update public.player_research set level = 1 where player_id = v_target_owner and research_id = 'espionage_technology';
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_target, 'light_fighter', 4)
      on conflict (planet_id, ship_id) do update set quantity = 4;

    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position)
    select v_attacker, v_origin, v_target, 'ESPIONAGE', clock_timestamp() - interval '20 minutes',
           clock_timestamp(), 'ARRIVED', p.galaxy, p.system, p.position
    from public.planets p where p.id = v_target
    returning id into v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'espionage_probe', 3);
    perform public.resolve_espionage_arrival(v_fleet);

    select * into v_report_row from public.espionage_reports where fleet_id = v_fleet;
    v_report := v_report_row.id;
    set local role authenticated;
    select * into v_row from public.get_player_espionage_reports(200) g where g.out_report_id = v_report;
    reset role;

    v_ok := v_row.out_probes_sent = 3
            and v_row.out_ships_revealed = true and v_row.out_defenses_revealed = false
            and v_row.out_fleet <> '{}'::jsonb and v_row.out_defenses = '{}'::jsonb
            and v_row.out_ships_revealed = (v_report_row.fleet <> '{}'::jsonb)
            and v_row.out_defenses_revealed = (v_report_row.defenses <> '{}'::jsonb);
    insert into t_erf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('C. levels 0 vs 1 with 3 probes (remaining 2): ships %s with map %s, defence %s with map %s',
             v_row.out_ships_revealed, v_report_row.fleet, v_row.out_defenses_revealed, v_report_row.defenses));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ================= D. levels 1 vs 1, 5 probes: everything revealed ================= */
    update public.player_research set level = 1 where player_id = v_attacker and research_id = 'espionage_technology';

    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position)
    select v_attacker, v_origin, v_target, 'ESPIONAGE', clock_timestamp() - interval '20 minutes',
           clock_timestamp(), 'ARRIVED', p.galaxy, p.system, p.position
    from public.planets p where p.id = v_target
    returning id into v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'espionage_probe', 5);
    perform public.resolve_espionage_arrival(v_fleet);

    select * into v_report_row from public.espionage_reports where fleet_id = v_fleet;
    v_report := v_report_row.id;
    set local role authenticated;
    select * into v_row from public.get_player_espionage_reports(200) g where g.out_report_id = v_report;
    reset role;

    v_ok := v_row.out_probes_sent = 5
            and v_row.out_ships_revealed = true and v_row.out_defenses_revealed = true
            and v_row.out_fleet <> '{}'::jsonb and v_row.out_defenses <> '{}'::jsonb
            and v_row.out_ships_revealed = (v_report_row.fleet <> '{}'::jsonb)
            and v_row.out_defenses_revealed = (v_report_row.defenses <> '{}'::jsonb);
    insert into t_erf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('D. levels 1 vs 1 with 5 probes: ships %s with map %s, defence %s with map %s',
             v_row.out_ships_revealed, v_report_row.fleet, v_row.out_defenses_revealed, v_report_row.defenses));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ================= E. the snapshot semantics: a later level never upgrades the report ================= */
    update public.player_research set level = 9 where player_id = v_attacker and research_id = 'espionage_technology';

    set local role authenticated;
    select * into v_row from public.get_player_espionage_reports(200) g where g.out_report_id = v_report;
    reset role;
    select * into v_report_row from public.espionage_reports where id = v_report;

    v_ok := v_row.out_ships_revealed = (v_report_row.fleet <> '{}'::jsonb)
            and v_row.out_defenses_revealed = (v_report_row.defenses <> '{}'::jsonb)
            and v_row.out_buildings_revealed = (v_report_row.buildings <> '{}'::jsonb)
            and v_row.out_research_revealed = (v_report_row.research <> '{}'::jsonb)
            and v_row.out_espionage_level = 1;
    insert into t_erf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('E. raising the attacker to level 9 changes neither the stored maps (ships %s / def %s / bld %s / res %s) nor the reported outcome (reported level %s, snapshot)',
             v_report_row.fleet, v_report_row.defenses, v_report_row.buildings, v_report_row.research, v_row.out_espionage_level));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ================= G. TABLE-DRIVEN: all four thresholds on both branches =================
       The expectation is DERIVED INDEPENDENTLY from the row the resolver wrote (the OGameX rule re-evaluated here),
       never copied from the implementation, and every scenario asserts:
         · the four flags equal the independent derivation,
         · a denied section stored NOTHING (`'{}'`) and a revealed one stored the target's real data,
         · the maps the contract returns are the ones the resolver stored (no client-side invention).
       Scenarios: probe path (remaining 2/5/7), the level path (attacker 4 vs 0 with a single probe) and the
       level-gap case where the gap eats every probe.                                                */
    for v_sc in
        select * from (values
            (0, 2, 6),   /* gap 2 -> remaining 2  : ships only            */
            (0, 1, 6),   /* gap 1 -> remaining 5  : + buildings           */
            (0, 0, 7),   /* gap 0 -> remaining 7  : + research            */
            (0, 0, 4),   /* gap 0 -> remaining 4  : ships + defence only  */
            (4, 0, 1),   /* level path            : all four with 1 probe */
            (2, 2, 4)    /* gap 0, levels equal   : ships + defence only  */
        ) as t(attacker_level, defender_level, probes)
    loop
        update public.player_research set level = v_sc.attacker_level
         where player_id = v_attacker and research_id = 'espionage_technology';
        update public.player_research set level = v_sc.defender_level
         where player_id = v_target_owner and research_id = 'espionage_technology';

        insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type,
            started_at, arrives_at, status, destination_galaxy, destination_system, destination_position)
        select v_attacker, v_origin, v_target, 'ESPIONAGE', clock_timestamp() - interval '20 minutes',
               clock_timestamp(), 'ARRIVED', p.galaxy, p.system, p.position
        from public.planets p where p.id = v_target
        returning id into v_fleet;
        insert into public.fleet_movement_ships(fleet_id, ship_id, quantity)
        values (v_fleet, 'espionage_probe', v_sc.probes);
        perform public.resolve_espionage_arrival(v_fleet);

        select * into v_report_row from public.espionage_reports where fleet_id = v_fleet;
        v_remaining := greatest(0, v_report_row.probes_sent
                                  - power(greatest(0, v_report_row.target_espionage_level - v_report_row.espionage_level), 2));
        v_expected_flags := jsonb_build_object(
            'ships',    (v_remaining >= 2 or (v_report_row.espionage_level - 1) >= v_report_row.target_espionage_level),
            'defenses', (v_remaining >= 3 or (v_report_row.espionage_level - 2) >= v_report_row.target_espionage_level),
            'buildings',(v_remaining >= 5 or (v_report_row.espionage_level - 3) >= v_report_row.target_espionage_level),
            'research', (v_remaining >= 7 or (v_report_row.espionage_level - 4) >= v_report_row.target_espionage_level));

        set local role authenticated;
        select * into v_row from public.get_player_espionage_reports(200) g where g.out_report_id = v_report_row.id;
        reset role;

        v_ok := jsonb_build_object(
                    'ships', v_row.out_ships_revealed, 'defenses', v_row.out_defenses_revealed,
                    'buildings', v_row.out_buildings_revealed, 'research', v_row.out_research_revealed)
                = v_expected_flags
                /* a denied section stored nothing; a revealed one stored the target's real data */
                and (v_expected_flags->>'buildings')::boolean is not distinct from
                    (v_report_row.buildings <> '{}'::jsonb)
                and (v_expected_flags->>'research')::boolean is not distinct from
                    (v_report_row.research <> '{}'::jsonb)
                and v_report_row.buildings = (case when (v_expected_flags->>'buildings')::boolean
                                                   then v_report_row.buildings else '{}'::jsonb end)
                /* the returned maps are exactly the stored ones (the contract invents nothing) */
                and v_row.out_buildings = v_report_row.buildings
                and v_row.out_research = v_report_row.research
                and (not (v_expected_flags->>'buildings')::boolean or (v_row.out_buildings ? 'metal_mine'))
                and (not (v_expected_flags->>'research')::boolean or (v_row.out_research ? 'energy_technology'))
                and v_row.out_probes_sent = v_sc.probes;
        insert into t_erf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
          format('G. levels %s vs %s with %s probe(s), remaining %s: ships %s / def %s / bld %s / res %s (independent derivation %s)',
                 v_sc.attacker_level, v_sc.defender_level, v_sc.probes, v_remaining,
                 v_row.out_ships_revealed, v_row.out_defenses_revealed,
                 v_row.out_buildings_revealed, v_row.out_research_revealed, v_expected_flags));
        v_fail := v_fail + case when v_ok then 0 else 1 end;
    end loop;

    /* ================= F. ownership, row-level closure and the limit clamp are untouched ================= */
    set local role authenticated;
    select count(*) into v_n from public.get_player_espionage_reports(500) g where g.out_player_id <> v_attacker;
    reset role;

    v_ok := v_n = 0
            and has_function_privilege('authenticated', 'public.get_player_espionage_reports(integer)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.get_player_espionage_reports(integer)', 'EXECUTE')
            and not has_function_privilege('authenticated', 'public.resolve_espionage_arrival(uuid)', 'EXECUTE')
            and exists (select 1 from pg_policies pol
                         where pol.schemaname = 'public' and pol.tablename = 'espionage_reports'
                           and pol.policyname = 'deny_direct_api_access'
                           and pol.qual = 'false');
    insert into t_erf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('F1. contract returns only the caller''s reports (%s foreign rows), authenticated-only, and the table keeps its deny_direct_api_access policy', v_n));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    set local role authenticated;
    select count(*) into v_n from public.get_player_espionage_reports(100000) g;
    reset role;
    v_ok := v_n <= 200;
    insert into t_erf(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('F2. p_limit is still clamped to 200 (%s rows returned for 100000)', v_n));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_erf(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; the reveal flags are a derivation of the stored snapshot, so they are asserted against the maps the resolver actually wrote.');

    if v_fail > 0 then
        raise exception 'ESPIONAGE REVEAL FLAGS FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select case when count(*) filter (where resultado = 'FAIL') = 0 then 'PASS' else 'FAIL' end as final,
       count(*) filter (where resultado = 'PASS') as passed,
       count(*) filter (where resultado <> 'INFO') as assertions
  from t_erf;

select orden, resultado, prueba from t_erf order by orden;

drop table if exists t_erf;

rollback;
