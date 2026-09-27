-- RESEARCH BUILDING PREREQUISITES FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract under test (migration 20260925192948_research_building_prerequisites_mechanism, whose content
-- was activated by 20260926180000_research_lab_gates_and_irn):
--   * `research_building_prerequisites(research_id, building_id, required_level)`, RLS-enabled. PRODUCTION
--     CONTENT (since 20260926180000, owner-approved): the 16 OGameX `research_lab` gates — energy 1,
--     laser 1, ion 4, hyperspace 7, plasma 4, combustion 1, impulse 2, hyperspace drive 7, espionage 3,
--     computer 1, astrophysics 3, IRN 10, graviton 12, weapons 4, shielding 6, armour 2;
--   * `check_research_building_prerequisites(planet_id, research_id)` = single source of truth, evaluated on
--     the planet that starts the research (OGameX parity);
--   * `can_start_research` reports both dimensions in the same `prerequisites` jsonb (`kind` discriminator)
--     and derives `prerequisites_met` from it;
--   * `start_research` rejects with `RESEARCH_REQUIREMENTS_NOT_MET` and mutates nothing.
--
-- The fixture also installs TEMPORARY requirements against an EXISTING building (`shipyard`) inside this
-- transaction only, and exercises the empty-mechanism branch by emptying the table within the transaction.
-- Because the shipped 16 gates also apply to the technologies under test, the fixture installs the level
-- the contract itself requires (derived from the table, never invented) after isolating the planet.
--
-- LIMITATION: single-session harness. Atomicity is asserted as "a rejected call leaves no queue row, no
-- resource change and no level change"; true concurrency is not executed.

begin;

drop table if exists t_rbp_results;
create temp table t_rbp_results(orden serial, resultado text, prueba text);

-- Snapshot of the SHIPPED production content, taken before the fixture mutates anything: it is what
-- assertions 14/15 compare against, so the equivalence checks stay meaningful even though the
-- empty-mechanism branch empties the table inside this transaction.
drop table if exists t_rbp_shipped;
create temp table t_rbp_shipped on commit drop as
    select research_id, building_id, required_level
      from public.research_building_prerequisites;

do $test$
declare
    v_auth_a uuid; v_player uuid; v_planet uuid;
    v_player_b uuid; v_planet_b uuid;
    v_queue_before integer; v_metal_before numeric; v_crystal_before numeric; v_deut_before numeric;
    v_metal_after numeric; v_crystal_after numeric; v_deut_after numeric;
    v_level_before integer;
    v_rec record; v_info record; v_json jsonb; v_q uuid; v_bad integer := 0;
    v_ok boolean; v_fail integer := 0; v_msg text;
begin
    /* ------------------------------------------------------------------ FIXTURE */
    select pl.id, pl.user_id into v_player, v_auth_a
      from public.players pl where pl.user_id is not null order by pl.created_at limit 1;
    select p.id into v_planet
      from public.planets p where p.player_id = v_player and not p.is_destroyed
      order by p.created_at, p.id limit 1;
    select p.player_id, p.id into v_player_b, v_planet_b
      from public.planets p join public.players pl on pl.id = p.player_id
     where not p.is_destroyed and pl.player_type = 'AI' and p.player_id <> v_player
     order by p.created_at, p.id limit 1;

    if v_player is null or v_planet is null or v_planet_b is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet and a foreign planet are required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_a)::text, true);

    -- isolate the fixture: no mines (zero production), no research rows, resources at the storage cap
    delete from public.planet_buildings where planet_id = v_planet;

    /* The shipped laboratory gates (20260926180000) also apply to the technologies this fixture
       exercises. Install the level the contract itself requires (derived from the table, not invented)
       so that the temporary `shipyard` requirement stays the only unmet dimension under test. */
    insert into public.planet_buildings(planet_id, building_id, level)
    select v_planet, rbp.building_id, max(rbp.required_level)
      from public.research_building_prerequisites rbp
     where rbp.research_id in ('energy_technology','combustion_drive','plasma_technology',
                               'ion_technology','laser_technology')
       and rbp.building_id <> 'shipyard'
     group by rbp.building_id
    on conflict (planet_id, building_id) do update set level = excluded.level;
    delete from public.player_research
     where player_id = v_player
       and research_id in ('energy_technology','combustion_drive','plasma_technology','ion_technology','laser_technology');
    delete from public.research_queue where player_id = v_player;

    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at)
    values (v_planet, 100000, 100000, 100000, 0, now())
    on conflict (planet_id) do update
       set metal = 100000, crystal = 100000, deuterium = 100000, energy = 0, last_calculated_at = now();

    -- the foreign planet has a high shipyard, so "another player's building" is a real temptation
    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet_b, 'shipyard', 9)
    on conflict (planet_id, building_id) do update set level = 9;

    /* ---------------------------- TEMPORARY requirement (rolled back with the transaction) */
    insert into public.research_building_prerequisites(research_id, building_id, required_level)
    values ('energy_technology','shipyard',2)
    on conflict (research_id, building_id) do update set required_level = excluded.required_level;

    /* ---------------------------------------------- 1. MISSING BUILDING => BLOCKED */
    select * into v_info from public.can_start_research(v_player, v_planet, 'energy_technology');
    v_json := v_info.prerequisites;
    v_ok := v_info.allowed = false
        and v_info.reason_code = 'RESEARCH_REQUIREMENTS_NOT_MET'
        and v_info.prerequisites_met = false
        and exists (select 1 from jsonb_array_elements(v_json) e
                     where e->>'kind' = 'building' and e->>'building_id' = 'shipyard'
                       and (e->>'required_level')::int = 2 and (e->>'current_level')::int = 0
                       and (e->>'satisfied')::boolean = false);
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. missing building blocks availability [%s · met=%s · json=%s]', v_info.reason_code, v_info.prerequisites_met, v_json));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*) into v_queue_before from public.research_queue where player_id = v_player;
    select metal, crystal, deuterium into v_metal_before, v_crystal_before, v_deut_before from public.planet_resources where planet_id = v_planet;
    begin
        v_q := public.start_research(v_player, v_planet, 'energy_technology');
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    select metal, crystal, deuterium into v_metal_after, v_crystal_after, v_deut_after from public.planet_resources where planet_id = v_planet;
    v_ok := v_msg like 'RESEARCH_REQUIREMENTS_NOT_MET%'
        and (select count(*) from public.research_queue where player_id = v_player) = v_queue_before
        and v_metal_after = v_metal_before and v_crystal_after = v_crystal_before and v_deut_after = v_deut_before;
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. start_research rejected [%s] with zero mutation (queue rows %s, resources unchanged)', v_msg, v_queue_before));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------ 3-4. LEVEL TOO LOW => STILL BLOCKED */
    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'shipyard', 1)
    on conflict (planet_id, building_id) do update set level = 1;

    select * into v_info from public.can_start_research(v_player, v_planet, 'energy_technology');
    v_json := v_info.prerequisites;
    v_ok := v_info.allowed = false and v_info.prerequisites_met = false
        and exists (select 1 from jsonb_array_elements(v_json) e
                     where e->>'kind' = 'building' and e->>'building_id' = 'shipyard'
                       and (e->>'required_level')::int = 2 and (e->>'current_level')::int = 1
                       and (e->>'satisfied')::boolean = false);
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. level 1 < required 2 blocks availability [json=%s]', v_json));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    begin
        v_q := public.start_research(v_player, v_planet, 'energy_technology');
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'RESEARCH_REQUIREMENTS_NOT_MET%'
        and (select count(*) from public.research_queue where player_id = v_player) = v_queue_before;
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. insufficient level rejected [%s] and no queue row was created', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------- 5-6. SATISFIED => ALLOWED */
    update public.planet_buildings set level = 2 where planet_id = v_planet and building_id = 'shipyard';

    select * into v_info from public.can_start_research(v_player, v_planet, 'energy_technology');
    v_json := v_info.prerequisites;
    v_ok := v_info.allowed = true and v_info.prerequisites_met = true
        and exists (select 1 from jsonb_array_elements(v_json) e
                     where e->>'kind' = 'building' and e->>'building_id' = 'shipyard'
                       and (e->>'current_level')::int = 2 and (e->>'satisfied')::boolean = true);
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. shipyard level 2 satisfies the requirement [allowed=%s · met=%s · json=%s]',
             v_info.allowed, v_info.prerequisites_met, v_json));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select metal, crystal, deuterium into v_metal_before, v_crystal_before, v_deut_before
      from public.planet_resources where planet_id = v_planet;
    v_q := public.start_research(v_player, v_planet, 'energy_technology');
    select metal, crystal, deuterium into v_metal_after, v_crystal_after, v_deut_after
      from public.planet_resources where planet_id = v_planet;
    v_ok := v_q is not null
        and (select count(*) from public.research_queue
              where player_id = v_player and research_id = 'energy_technology'
                and target_level = 1 and upper(status) = 'RESEARCHING') = 1
        and v_metal_before - v_metal_after = (select metal from public.calculate_research_cost('energy_technology',1))
        and v_crystal_before - v_crystal_after = (select crystal from public.calculate_research_cost('energy_technology',1))
        and v_deut_before - v_deut_after = (select deuterium from public.calculate_research_cost('energy_technology',1));
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. research started and the exact cost was charged (queue=%s · metal -%s crystal -%s deuterium -%s)',
             v_q is not null, v_metal_before - v_metal_after, v_crystal_before - v_crystal_after, v_deut_before - v_deut_after));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------- 7. EMPTY TABLE => CONTRACT UNCHANGED (production behaviour) */
    delete from public.research_building_prerequisites;
    delete from public.research_queue where player_id = v_player;

    select * into v_info from public.can_start_research(v_player, v_planet, 'energy_technology');
    v_ok := v_info.allowed = true and v_info.prerequisites_met = true
        and v_info.prerequisites = '[]'::jsonb;
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. with the mechanism empty nothing is blocked and the payload is unchanged [allowed=%s · prerequisites=%s]',
             v_info.allowed, v_info.prerequisites));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_q := public.start_research(v_player, v_planet, 'energy_technology');
    v_ok := v_q is not null
        and (select count(*) from public.research_queue
              where player_id = v_player and research_id = 'energy_technology' and upper(status) = 'RESEARCHING') = 1;
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '8. a research with no building prerequisite still starts normally (no regression)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------- 9. MULTIPLE PREREQUISITES + RESEARCH DIMENSION COMBINED */
    insert into public.research_building_prerequisites(research_id, building_id, required_level)
    values ('combustion_drive','shipyard',2), ('combustion_drive','metal_storage',1);

    select * into v_info from public.can_start_research(v_player, v_planet, 'combustion_drive');
    v_json := v_info.prerequisites;
    v_ok := v_info.allowed = false and v_info.prerequisites_met = false
        and jsonb_array_length(v_json) = 3
        and (select count(*) from jsonb_array_elements(v_json) e where e->>'kind' = 'building') = 2
        and exists (select 1 from jsonb_array_elements(v_json) e
                     where e->>'building_id' = 'shipyard' and (e->>'satisfied')::boolean = true)
        and exists (select 1 from jsonb_array_elements(v_json) e
                     where e->>'building_id' = 'metal_storage' and (e->>'current_level')::int = 0
                       and (e->>'satisfied')::boolean = false)
        and exists (select 1 from jsonb_array_elements(v_json) e
                     where e->>'kind' = 'research' and e->>'research_id' = 'energy_technology'
                       and (e->>'satisfied')::boolean = false);
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. multiple prerequisites combined with the research dimension [entries=%s json=%s]',
             jsonb_array_length(v_json), v_json));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* --------------------------------------------- 10. ALL DIMENSIONS SATISFIED */
    insert into public.player_research(player_id, research_id, level) values (v_player,'energy_technology',1)
    on conflict (player_id, research_id) do update set level = 1;
    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet,'metal_storage',1)
    on conflict (planet_id, building_id) do update set level = 1;
    delete from public.research_queue where player_id = v_player;

    select * into v_info from public.can_start_research(v_player, v_planet, 'combustion_drive');
    v_ok := v_info.allowed = true and v_info.prerequisites_met = true;
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10a. building + research prerequisites all satisfied [allowed=%s met=%s]', v_info.allowed, v_info.prerequisites_met));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_q := public.start_research(v_player, v_planet, 'combustion_drive');
    v_ok := v_q is not null
        and (select count(*) from public.research_queue
              where player_id = v_player and research_id = 'combustion_drive'
                and target_level = 1 and upper(status) = 'RESEARCHING') = 1;
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10b. research starts when every dimension is satisfied');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* --------- 11. RESEARCH DIMENSION STILL ENFORCED ON ITS OWN (building satisfied) */
    delete from public.player_research where player_id = v_player and research_id = 'energy_technology';
    delete from public.research_queue where player_id = v_player;

    select * into v_info from public.can_start_research(v_player, v_planet, 'combustion_drive');
    v_json := v_info.prerequisites;
    v_ok := v_info.allowed = false and v_info.prerequisites_met = false
        and (select bool_and((e->>'satisfied')::boolean) from jsonb_array_elements(v_json) e
              where e->>'kind' = 'building') = true
        and exists (select 1 from jsonb_array_elements(v_json) e
                     where e->>'kind' = 'research' and (e->>'satisfied')::boolean = false);
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11a. building dimension satisfied but the research prerequisite still blocks [json=%s]', v_json));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    begin
        v_q := public.start_research(v_player, v_planet, 'combustion_drive');
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'RESEARCH_REQUIREMENTS_NOT_MET%';
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11b. start_research still enforces the research prerequisite [%s]', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* -------------- 12. PROPERTY: A FOREIGN PLANET/BUILDING NEVER SATISFIES */
    insert into public.research_building_prerequisites(research_id, building_id, required_level)
    values ('energy_technology','shipyard',2)
    on conflict (research_id, building_id) do update set required_level = 2;

    select * into v_info from public.can_start_research(v_player, v_planet_b, 'energy_technology');
    v_ok := v_info.allowed = false and v_info.reason_code = 'PLANET_NOT_FOUND_OR_NOT_OWNED';
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('12a. the foreign planet (shipyard level 9) is rejected by the ownership gate [%s]', v_info.reason_code));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    begin
        v_q := public.start_research(v_player, v_planet_b, 'energy_technology');
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'PLANET_NOT_FOUND_OR_NOT_OWNED%'
        and (select count(*) from public.research_queue where player_id = v_player) = 0;
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('12b. start_research rejects the foreign planet and creates no queue row [%s]', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------ 13. UNAUTHENTICATED ACTOR */
    perform set_config('request.jwt.claims', '{}', true);
    select * into v_info from public.can_start_research(v_player, v_planet, 'energy_technology');
    v_ok := v_info.allowed = false and v_info.reason_code = 'AUTHENTICATION_REQUIRED';
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('13a. unauthenticated actor gets no availability [%s]', v_info.reason_code));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    begin
        v_q := public.start_research(v_player, v_planet, 'energy_technology');
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'Authentication required%'
        and (select count(*) from public.research_queue where player_id = v_player) = 0;
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('13b. unauthenticated start rejected [%s] with no mutation', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_a)::text, true);

    /* ------------- 14. PRODUCTION CONTENT (20260926180000): THE 16 OGAMEX LABORATORY GATES ---- */
    v_ok := (select count(*) from t_rbp_shipped) = 16
        and not exists (select 1 from t_rbp_shipped where building_id <> 'research_lab')
        and exists (select 1 from t_rbp_shipped
                     where research_id = 'graviton_technology' and required_level = 12)
        and exists (select 1 from t_rbp_shipped
                     where research_id = 'intergalactic_research_network' and required_level = 10)
        and exists (select 1 from t_rbp_shipped
                     where research_id = 'armour_technology' and required_level = 2);
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('14. production ships the 16 OGameX laboratory gates [rows=%s]', (select count(*) from t_rbp_shipped)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- 14b. RESTORE the shipped content: assertions 15a/15b compare the availability payload against
       the real table, so they must not run against the table emptied by assertion 7. ---- */
    delete from public.research_building_prerequisites;
    insert into public.research_building_prerequisites(research_id, building_id, required_level)
    select research_id, building_id, required_level from t_rbp_shipped;

    /* ---- 15. EQUIVALENCE: the research dimension is byte-for-byte what it was before the change ---- */
    select count(*) into v_bad
      from public.research_definitions rd
      cross join lateral public.can_start_research(v_player, v_planet, rd.id) c
     where c.reason_code <> 'RESEARCH_MAX_LEVEL_REACHED'
       and ((select count(*) from jsonb_array_elements(c.prerequisites) e where e->>'kind' = 'research')
              <> (select count(*) from public.research_prerequisites rp where rp.research_id = rd.id)
         or (select count(*) from jsonb_array_elements(c.prerequisites) e where e->>'kind' = 'building')
              <> (select count(*) from public.research_building_prerequisites rb where rb.research_id = rd.id));
    v_ok := v_bad = 0;
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('15a. every research reports exactly its own prerequisite rows [mismatches=%s of 16]', v_bad));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*) into v_bad
      from public.research_prerequisites rp
      cross join lateral public.can_start_research(v_player, v_planet, rp.research_id) c
      cross join lateral jsonb_array_elements(c.prerequisites) e
     where c.reason_code <> 'RESEARCH_MAX_LEVEL_REACHED'
       and e->>'kind' = 'research'
       and e->>'research_id' = rp.prerequisite_research_id
       and ((e->>'required_level')::int <> rp.required_level
         or (e->>'current_level')::int <> coalesce((select pr.level from public.player_research pr
                                                     where pr.player_id = v_player
                                                       and pr.research_id = rp.prerequisite_research_id), 0)
         or (e->>'satisfied')::boolean <> (coalesce((select pr.level from public.player_research pr
                                                      where pr.player_id = v_player
                                                        and pr.research_id = rp.prerequisite_research_id), 0) >= rp.required_level));
    v_ok := v_bad = 0;
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('15b. every research prerequisite entry keeps its exact values [mismatches=%s]', v_bad));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------- 16. THE RESEARCH-ONLY GATE IS UNCHANGED (can_research) ---------------- */
    v_ok := public.can_research(v_player, 'energy_technology', 1) = true
        and public.can_research(v_player, 'combustion_drive', 1) = false;
    insert into t_rbp_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '16. can_research still gates the research dimension on its own (energy level 1 allowed, combustion without energy blocked)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_rbp_results(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; concurrency is not executed. A rejected call is asserted to leave no queue row, no resource change and no level change.');

    if v_fail > 0 then
        raise exception 'RESEARCH BUILDING PREREQUISITES FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_rbp_results order by orden;

drop table if exists t_rbp_results;

ROLLBACK;
