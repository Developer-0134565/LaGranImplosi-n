-- RESEARCH LAB ↔ INVESTIGACIÓN — OGameX parity (2026-09-27): ESTADO/UI + ENFORCEMENT de cola.
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK, zero residue.
-- Contracts (@ 7c420bad):
--   * `get_player_research_lab_status()` (migration 20260927014725) reproduces the OGameX STATE:
--       research_lab_upgrading = $player->isBuildingObject('research_lab') → research-item.blade.php data-status="disabled"
--       research_in_progress   = $player->isResearching()                 → payload of the building details
--   * `20260927015502` reproduces the `BuildingQueueService` ENFORCEMENT: while a research is running the
--     laboratory can be neither upgraded nor downgraded (BEFORE INSERT guard on building_queue + availability in
--     `evaluate_building_start_internal` and `inspect_demolition`; OGameX addDowngrade 207-210, start() 398-401/416-421).
-- Assertion 6 proves `start_research` is NEVER blocked (OGameX does not block it server-side either:
-- `ResearchController::addBuildRequest` validates vacation + CSRF only), so LGI is not stricter than OGameX.
-- Assertions 8/8c: the laboratory refusal (upgrade and downgrade); 8b: no other building is affected;
-- 8d-8e: an item ALREADY IN FLIGHT still completes (OGameX `start()` only inspects items that have not begun).
-- LIMITATION: single-session harness; the visual mark (UI) is not certifiable from SQL.

begin;

drop table if exists t_rlu;
create temp table t_rlu(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_universe uuid; v_planet uuid; v_planet2 uuid;
    v_foreign_player uuid; v_foreign_planet uuid;
    v_state record; v_queue uuid; v_raised text; v_ok boolean; v_fail integer := 0;
    v_inspect record; v_queue_research uuid; v_status text; v_level integer;
    v_metal_before numeric; v_metal_after numeric;
    v_i integer; v_galaxy integer;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_planet from public.planets p
     where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET' order by p.created_at limit 1;

    if v_player is null or v_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet is required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth, 'role', 'authenticated')::text, true);

    /* ------------------------------------------------ FIXTURE: clean state */
    delete from public.research_queue where player_id = v_player;
    delete from public.building_queue
     where planet_id in (select p.id from public.planets p where p.player_id = v_player);
    delete from public.planets where player_id = v_player and id <> v_planet and is_destroyed = false;
    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at, updated_at)
    values (v_planet, 5000000, 5000000, 5000000, 0, now(), now())
    on conflict (planet_id) do update
       set metal = 5000000, crystal = 5000000, deuterium = 5000000, last_calculated_at = now();
    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'research_lab', 4)
    on conflict (planet_id, building_id) do update set level = 4;

    /* 1. clean state: exactly one row, both flags false, no upgrade data */
    select * into v_state from public.get_player_research_lab_status();
    v_ok := (select count(*) from public.get_player_research_lab_status()) = 1
            and coalesce(v_state.research_lab_upgrading, false) = false
            and coalesce(v_state.research_in_progress, false) = false
            and v_state.upgrading_planet_id is null
            and v_state.upgrading_target_level is null
            and v_state.upgrading_finishes_at is null;
    insert into t_rlu(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. clean state: one row, flags %s/%s', v_state.research_lab_upgrading, v_state.research_in_progress));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 2. a lab upgrade on ANOTHER owned planet raises the EMPIRE flag (OGameX loops every planet) */
    v_galaxy := coalesce((select max(p.galaxy) from public.planets p), 1);
    for v_i in 1..10 loop
        begin
            insert into public.planets(universe_id, player_id, name, galaxy, system, position, fields_total,
                fields_used, is_homeworld, is_destroyed, kind)
            values (v_universe, v_player, 'LabState' || v_i, v_galaxy, 476 + ((v_i - 1) % 5), 15 + ((v_i - 1) / 5),
                100, 0, false, false, 'PLANET')
            returning id into v_planet2;
            exit;
        exception when unique_violation then
            v_planet2 := null;
        end;
    end loop;

    if v_planet2 is null then
        raise exception 'TEST_ABORT: no free coordinates for the second own planet';
    end if;

    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet2, 'research_lab', 3);

    insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status, is_downgrade)
    values (v_planet2, 'research_lab', 4, now(), now() + interval '30 minutes', 'BUILDING', false)
    returning id into v_queue;

    select * into v_state from public.get_player_research_lab_status();
    v_ok := coalesce(v_state.research_lab_upgrading, false)
            and v_state.upgrading_planet_id = v_planet2
            and v_state.upgrading_target_level = 4
            and v_state.upgrading_finishes_at is not null;
    insert into t_rlu(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. empire flag from another own planet (planet=%s target=%s)', v_state.upgrading_planet_id, v_state.upgrading_target_level));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 3. only the laboratory counts: another building in the queue does not raise the flag */
    delete from public.building_queue where id = v_queue;
    insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status, is_downgrade)
    values (v_planet2, 'metal_mine', 1, now(), now() + interval '30 minutes', 'BUILDING', false);

    select * into v_state from public.get_player_research_lab_status();
    v_ok := coalesce(v_state.research_lab_upgrading, false) = false;
    insert into t_rlu(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. a non-lab building does not raise the flag (%s)', v_state.research_lab_upgrading));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 4. a lab DOWNGRADE does not raise the flag (OGameX compares target = current_level + 1) */
    delete from public.building_queue
     where planet_id in (select p.id from public.planets p where p.player_id = v_player);
    insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status, is_downgrade)
    values (v_planet2, 'research_lab', 2, now(), now() + interval '30 minutes', 'BUILDING', true);

    select * into v_state from public.get_player_research_lab_status();
    v_ok := coalesce(v_state.research_lab_upgrading, false) = false;
    insert into t_rlu(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. a lab downgrade does not raise the flag (%s)', v_state.research_lab_upgrading));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 5. ownership: another player's laboratory never raises my flag.
       La fila ajena se escribe con el contexto declarado del worker de IA (mismo idioma que
       `can_start_building_ownership.sql`: rol service_role + `lgi.ai_worker/ai_player`), porque el
       guard `enforce_player_write_access` de `building_queue` rechaza escribir para otro jugador desde
       una sesión autenticada. Es el único modo legítimo de fabricar el escenario ajeno. */
    select pl.id into v_foreign_player
      from public.players pl
     where pl.id <> v_player and pl.player_type = 'AI' and pl.user_id is null
     order by pl.created_at, pl.id
     limit 1;

    if v_foreign_player is null then
        raise exception 'TEST_ABORT: a second player is required for the ownership assertion';
    end if;

    for v_i in 1..10 loop
        begin
            insert into public.planets(universe_id, player_id, name, galaxy, system, position, fields_total,
                fields_used, is_homeworld, is_destroyed, kind)
            values (v_universe, v_foreign_player, 'LabForeign' || v_i, v_galaxy, 471 + ((v_i - 1) % 5),
                17 + ((v_i - 1) / 5), 100, 0, false, false, 'PLANET')
            returning id into v_foreign_planet;
            exit;
        exception when unique_violation then
            v_foreign_planet := null;
        end;
    end loop;

    if v_foreign_planet is null then
        raise exception 'TEST_ABORT: no free coordinates for the foreign planet';
    end if;

    perform set_config('role', 'service_role', true);
    perform set_config('request.jwt.claims', '{}', true);
    perform set_config('lgi.ai_worker', 'on', true);
    perform set_config('lgi.ai_player', v_foreign_player::text, true);

    insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status, is_downgrade)
    values (v_foreign_planet, 'research_lab', 1, now(), now() + interval '30 minutes', 'BUILDING', false);

    perform set_config('role', 'postgres', true);
    perform set_config('lgi.ai_worker', 'off', true);
    perform set_config('lgi.ai_player', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth, 'role', 'authenticated')::text, true);

    select * into v_state from public.get_player_research_lab_status();
    v_ok := coalesce(v_state.research_lab_upgrading, false) = false;
    insert into t_rlu(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. ownership: a foreign lab upgrade does not raise my flag (%s)', v_state.research_lab_upgrading));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 6. NOT an enforcement: with the flag ACTIVE the research still starts (OGameX does not block it either) */
    delete from public.building_queue
     where planet_id in (select p.id from public.planets p where p.player_id = v_player);
    insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status, is_downgrade)
    values (v_planet2, 'research_lab', 4, now(), now() + interval '30 minutes', 'BUILDING', false);

    v_queue := null; v_raised := null;
    begin
        v_queue := public.start_research(v_player, v_planet, 'energy_technology');
    exception when others then
        v_raised := sqlerrm;
    end;

    select * into v_state from public.get_player_research_lab_status();
    v_ok := v_queue is not null and v_raised is null
            and coalesce(v_state.research_lab_upgrading, false)
            and exists (select 1 from public.research_queue q where q.id = v_queue and q.status = 'RESEARCHING');
    insert into t_rlu(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. state only: start_research accepted while upgrading (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 7. the inverse flag: an active research sets research_in_progress (both flags can coexist) */
    select * into v_state from public.get_player_research_lab_status();
    v_ok := coalesce(v_state.research_in_progress, false) and coalesce(v_state.research_lab_upgrading, false);
    insert into t_rlu(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. research_in_progress=%s with an active research', v_state.research_in_progress));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 8. ENFORCEMENT (OGameX BuildingQueueService 416-421): with a research in progress the laboratory
       upgrade is refused BEFORE charging and nothing is queued. */
    delete from public.building_queue where planet_id = v_planet;
    select pr.metal into v_metal_before from public.planet_resources pr where pr.planet_id = v_planet;

    v_queue := null; v_raised := null;
    begin
        v_queue := public.start_building(v_player, v_planet, 'research_lab');
    exception when others then
        v_raised := sqlerrm;
    end;

    select pr.metal into v_metal_after from public.planet_resources pr where pr.planet_id = v_planet;
    select * into v_state from public.get_player_research_lab_status();
    v_ok := v_queue is null
            and v_raised like 'BUILDING_BLOCKED_BY_ACTIVE_RESEARCH%'
            and v_metal_after = v_metal_before
            and not exists (select 1 from public.building_queue q where q.planet_id = v_planet)
            and coalesce(v_state.research_in_progress, false);
    insert into t_rlu(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. start_building(lab) refused while researching, no charge (%s)', coalesce(v_raised, 'accepted')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 8b. NOT stricter than OGameX: any OTHER building is unaffected while a research is in progress. */
    v_queue := null; v_raised := null;
    begin
        v_queue := public.start_building(v_player, v_planet, 'metal_mine');
    exception when others then
        v_raised := sqlerrm;
    end;
    v_ok := v_queue is not null and v_raised is null
            and exists (select 1 from public.building_queue q where q.id = v_queue and q.building_id = 'metal_mine');
    insert into t_rlu(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8b. a non-lab building is still allowed while researching (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 8c. ENFORCEMENT on the downgrade (OGameX addDowngrade 207-210): while ANY research is in progress the
       laboratory cannot be demolished, even though the active research (energy_technology) only needs lab 1
       and the fixture laboratory is level 4 — the blanket OGameX rule, not just the level dependency. */
    delete from public.building_queue
     where planet_id in (select p.id from public.planets p where p.player_id = v_player);
    select * into v_inspect from public.inspect_demolition(v_player, v_planet, 'research_lab');
    v_ok := not v_inspect.allowed and v_inspect.reason = 'DEMOLITION_BLOCKED_BY_ACTIVE_RESEARCH'
            and not v_inspect.research_idle;
    insert into t_rlu(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8c. lab demolition blocked while researching (%s)', coalesce(v_inspect.reason, 'null')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 8d. OGameX tolerance for items ALREADY in flight: the upgrade starts while no research runs, and the
       research starts afterwards — accepted, because OGameX never blocks the research side. */
    delete from public.research_queue where player_id = v_player;
    v_queue := null; v_raised := null;
    begin
        v_queue := public.start_building(v_player, v_planet, 'research_lab');
    exception when others then
        v_raised := sqlerrm;
    end;
    v_queue_research := null;
    begin
        v_queue_research := public.start_research(v_player, v_planet, 'energy_technology');
    exception when others then
        v_raised := coalesce(v_raised, '') || ' ' || sqlerrm;
    end;
    v_ok := v_queue is not null and v_queue_research is not null
            and exists (select 1 from public.building_queue q where q.id = v_queue and upper(q.status) = 'BUILDING')
            and exists (select 1 from public.research_queue q where q.id = v_queue_research and upper(q.status) = 'RESEARCHING');
    insert into t_rlu(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8d. in-flight lab upgrade + research accepted (%s)', coalesce(nullif(v_raised, ''), 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 8e. ...and the in-flight upgrade completes untouched by the research (PlanetService::updateBuildingQueue
       1693-1740 does not look at research), while the research keeps running. El liquidado de recursos de
       `complete_building` exige `finishes_at >= planet_resources.last_calculated_at`, así que el fixture
       retrasa también esa marca. */
    update public.planet_resources
       set last_calculated_at = now() - interval '2 hours'
     where planet_id = v_planet;
    update public.building_queue
       set started_at = now() - interval '1 hour', finishes_at = now() - interval '1 second'
     where id = v_queue;
    perform * from public.process_building_queue_for_planet(v_planet);

    select upper(q.status) into v_status from public.building_queue q where q.id = v_queue;
    select coalesce(max(pb.level), 0) into v_level
      from public.planet_buildings pb where pb.planet_id = v_planet and pb.building_id = 'research_lab';
    v_ok := v_status = 'COMPLETED' and v_level = 5
            and exists (select 1 from public.research_queue q
                        where q.id = v_queue_research and upper(q.status) = 'RESEARCHING');
    insert into t_rlu(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8e. in-flight upgrade completed (status=%s level=%s) with the research untouched', v_status, v_level));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 9. ACL: authenticated/service_role only, never anon */
    v_ok := not has_function_privilege('anon', 'public.get_player_research_lab_status()', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.get_player_research_lab_status()', 'EXECUTE');
    insert into t_rlu(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '9. ACL: state contract is authenticated/service_role only');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 10. anonymous caller: no identity, no rows, no error */
    perform set_config('request.jwt.claims', '{}', true);
    v_ok := (select count(*) from public.get_player_research_lab_status()) = 0;
    insert into t_rlu(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10. anonymous session → 0 rows (no identity is inferred)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_rlu(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness. The OGameX UI mark (research-item.blade.php data-status="disabled") is mirrored by the React views and is not SQL-certifiable. BuildingQueueService 398-401/416-421 is implemented as a pre-charge refusal (LGI charges at start): identical reachable state, without the charge/refund cycle.');

    if v_fail > 0 then
        raise exception 'RESEARCH LAB UPGRADING STATE FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_rlu order by orden;

drop table if exists t_rlu;

ROLLBACK;
