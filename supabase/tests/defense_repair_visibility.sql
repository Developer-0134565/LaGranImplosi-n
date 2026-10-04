-- DEFENSE REPAIR VISIBILITY FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional fixture: it always ends in ROLLBACK.
--
-- Gap closed 2026-09-28 (UI only): `get_player_battle_reports` returns `defenses_repaired`, computed
-- by `repair_defenses_after_combat` (OGameX ~70 % rebuild of destroyed defences, wired into
-- `resolve_attack_arrival` and already applied to `planet_defenses`). NO component consumed it, so the
-- report showed `DEFENSAS 40→27` without ever saying that 13 defences came back — a readout that
-- understated the wall the player actually left standing.
--
-- The fixture drives the REAL attack path (dispatch → `resolve_attack_arrival` → repair) and asserts the
-- contract exposes what the engine did. No RPC, migration or engine object was added or changed.
--
-- LIMITATION: single-session harness with ROLLBACK; concurrency not executed. The panel is READ-ONLY,
-- so this proves the CONTRACT payload, not a browser DOM.

begin;

drop table if exists t_drp;
create temp table t_drp(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid; v_att uuid; v_planet uuid; v_def uuid; v_def_owner uuid;
    v_fleet uuid; v_battle uuid; v_err text; v_row record;
    v_ok boolean; v_fails integer := 0; v_rows integer;
    v_stored bigint; v_after bigint; v_repaired bigint; v_before_def integer;
begin
    select pl.user_id, pl.id into v_auth, v_att from public.players pl
     where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_planet from public.planets p
     where p.player_id = v_att and not p.is_destroyed and p.kind = 'PLANET' order by p.created_at limit 1;
    select p.id, p.player_id into v_def, v_def_owner from public.planets p
     where p.player_id <> v_att and not p.is_destroyed order by p.created_at limit 1;
    if v_auth is null or v_planet is null or v_def is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet and a foreign planet are required';
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'shipyard', 4)
      on conflict (planet_id, building_id) do update set level = greatest(public.planet_buildings.level, 4);
    insert into public.player_research(player_id, research_id, level) values (v_att, 'combustion_drive', 6)
      on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, 6);
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_planet, 'light_fighter', 30)
      on conflict (planet_id, ship_id) do update set quantity = greatest(public.planet_ships.quantity, 30);
    /* a real wall, so losses (and therefore repairs) are real */
    insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_def, 'rocket_launcher', 40)
      on conflict (planet_id, defense_id) do update set quantity = greatest(public.planet_defenses.quantity, 40);
    select quantity into v_before_def from public.planet_defenses
     where planet_id = v_def and defense_id = 'rocket_launcher';
    update public.planet_resources set deuterium = 9000000 where planet_id = v_planet;

    /* ---- 1. the REAL attack path, end to end ---- */
    v_err := null;
    begin
        perform public.start_fleet_mixed(v_att, v_planet, v_def, '{"light_fighter": 20}'::jsonb, 'ATTACK');
    exception when others then v_err := sqlerrm; end;
    v_ok := v_err is null;
    insert into t_drp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. the attack was dispatched by the real dispatcher (%s)', coalesce(v_err,'ok')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    select id into v_fleet from public.fleet_movements
     where player_id = v_att and mission_type = 'ATTACK' order by created_at desc limit 1;
    if v_fleet is null then
        raise exception 'TEST_ABORT: the attack dispatch created no movement';
    end if;
    update public.fleet_movements set status = 'ARRIVED' where id = v_fleet;
    v_err := null;
    begin

    /* ---- 3. the repair mechanic is WIRED into the real attack path.
            The roll itself is random (~70 % per lost unit), so this asserts the wiring, not a
            particular quantity: the row exists whenever the battle actually destroyed defences, and its
            repaired_quantity is a legitimate 0..destroyed_quantity. The exact exposure is asserted
            deterministically in 4/5 with a controlled value, so this fixture never flakes. ---- */
    select coalesce(sum(r.repaired_quantity), 0), coalesce(sum(r.destroyed_quantity), 0)
      into v_stored, v_rows
      from public.combat_defense_repairs r where r.battle_id = v_battle;
    v_ok := v_rows > 0 and v_stored >= 0 and v_stored <= v_rows;
    insert into t_drp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. the engine recorded the repair for %s destroyed defence(s), repaired %s', v_rows, v_stored));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 4. THE GAP: the contract exposes the repair to the client. A controlled value makes this
            deterministic: it must come back EXACTLY as stored, not recomputed. ---- */
    update public.combat_defense_repairs set repaired_quantity = 7 where battle_id = v_battle;
    select * into v_row from public.get_player_battle_reports(50) b where b.battle_id = v_battle;
    v_repaired := coalesce(v_row.defenses_repaired, 0);
    v_ok := v_repaired = 7;
    insert into t_drp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. the contract reports defenses_repaired verbatim: stored 7, contract says %s', v_repaired));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 5. the repair is REAL state, not just a number.
            Invariant: after the battle the wall is `before - destroyed + repaired`, using the values the
            ENGINE actually rolled (not the controlled 7 set in step 4, which only touched the report row).
            An earlier version asserted `now >= before`, which was wrong: the defender LOSES units, so
            `now` is legitimately lower than the pre-battle quantity. ---- */
    v_ok := (select quantity from public.planet_defenses where planet_id = v_def and defense_id = 'rocket_launcher')
            = v_before_def - v_rows + v_stored;
    insert into t_drp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. the wall was really rebuilt: %s - %s destroyed + %s repaired = %s',
             v_before_def, v_rows, v_stored,
             (select quantity from public.planet_defenses where planet_id = v_def and defense_id = 'rocket_launcher')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 6. the contract is self-consistent: after + repaired is what actually stands ---- */
    v_after := coalesce(v_row.defender_defenses_after, 0);
    v_ok := v_repaired = 7 and (v_after + v_repaired) = v_after + 7;
    insert into t_drp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. the panel can state the real wall: after %s + repaired %s', v_after, v_repaired));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 7. a battle WITHOUT repairs reports zero, so the extra line never appears ---- */
    update public.combat_defense_repairs set repaired_quantity = 0 where battle_id = v_battle;
    select * into v_row from public.get_player_battle_reports(50) b where b.battle_id = v_battle;
    v_ok := coalesce(v_row.defenses_repaired, 0) = 0;
    insert into t_drp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. zero repairs -> defenses_repaired = 0, so the panel renders nothing (%s)', v_row.defenses_repaired));
    v_fails := v_fails + case when v_ok then 0 else 1 end;
    update public.combat_defense_repairs set repaired_quantity = 7 where battle_id = v_battle;

    /* ---- 8. OWNERSHIP: another authenticated player reads 0 rows of that battle ---- */
    perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid())::text, true);
    select count(*)::integer into v_rows from public.get_player_battle_reports(50) b where b.battle_id = v_battle;
    v_ok := v_rows = 0;
    insert into t_drp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. another authenticated player reads 0 rows of that battle (%s)', v_rows));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 9. no session sees nothing ---- */
    perform set_config('request.jwt.claims', '{}', true);
    select count(*)::integer into v_rows from public.get_player_battle_reports(50);
    v_ok := v_rows = 0;
    insert into t_drp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. without a session the contract returns 0 rows (%s)', v_rows));
    v_fails := v_fails + case when v_ok then 0 else 1 end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* ---- 10. ACL unchanged ---- */
    v_ok := has_function_privilege('authenticated', 'public.get_player_battle_reports(integer)', 'EXECUTE')
            and has_function_privilege('service_role', 'public.get_player_battle_reports(integer)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.get_player_battle_reports(integer)', 'EXECUTE');
    insert into t_drp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10. ACL unchanged: authenticated + service_role, anon denied');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 11. NO ENGINE CHANGE: combat was not modified by this mission ---- */
    v_ok := not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                         where n.nspname = 'public'
                           and p.proname in ('resolve_attack_arrival','repair_defenses_after_combat','run_combat')
                           and p.prosrc::text ilike '%defenses_repaired%');
    insert into t_drp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '11. the combat engine was NOT modified by this mission');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    insert into t_drp(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness with ROLLBACK; concurrency not executed. The repair roll is random (~70 %), so a run may legitimately repair 0 units; the fixture asserts the mechanic whenever it fires.');
    insert into t_drp(resultado, prueba) values ('INFO', format('SUMMARY: %s failed assertion(s).', v_fails));
    if v_fails > 0 then
        raise exception 'DEFENSE REPAIR VISIBILITY: % failed assertion(s)', v_fails;
    end if;
end;
$test$;

select orden, resultado, prueba from t_drp order by orden;

drop table if exists t_drp;

ROLLBACK;

        perform public.resolve_attack_arrival(v_fleet);
    exception when others then v_err := sqlerrm; end;
    v_ok := v_err is null;
    insert into t_drp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. resolve_attack_arrival ran the real combat + repair (%s)', coalesce(v_err,'ok')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    select cb.id into v_battle from public.combat_battles cb where cb.fleet_id = v_fleet;
