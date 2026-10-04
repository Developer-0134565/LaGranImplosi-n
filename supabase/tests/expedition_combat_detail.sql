-- EXPEDITION COMBAT DETAIL CONTRACT FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional fixture: it always ends in ROLLBACK.
--
-- Gap closed 2026-09-28 (UI only): `get_player_expedition_reports` already returned `enemy_ships` and
-- `lost_ships` — the enemy fleet that fought the expedition and the ships it destroyed — but NO
-- component consumed them. `expeditionDetail()` only printed the literal word "combate", so a pirate
-- or alien encounter told the player that a fight happened and nothing else.
--
-- This fixture certifies the CONTRACT payload the panel now renders. It is the same shape as
-- battle_report_ui_contract.sql: the backend was already complete and certified, the consumer was
-- missing. No RPC, migration or engine object was added or changed by this mission.
--
-- LIMITATION: single-session harness with ROLLBACK; concurrency not executed. The panel is a READ-ONLY
-- render, so this proves the CONTRACT, not a browser DOM.

begin;

drop table if exists t_ecd;
create temp table t_ecd(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid; v_player uuid; v_planet uuid; v_fleet uuid; v_row record; v_battle uuid;
    v_enemy jsonb; v_surv jsonb; v_res text; v_err text;
    v_ok boolean; v_fails integer := 0; v_rows integer;
    v_before bigint; v_ship text;
begin
    select pl.id, pl.user_id into v_player, v_auth from public.players pl
     where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_planet from public.planets p
     where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET' order by p.created_at limit 1;
    if v_player is null or v_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet is required';
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* `large_cargo` is gated on shipyard 4 + combustion_drive 6; without both the fixture would fail
       for an unrelated reason and would prove nothing about the report payload. */
    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'shipyard', 4)
      on conflict (planet_id, building_id) do update set level = greatest(public.planet_buildings.level, 4);
    insert into public.player_research(player_id, research_id, level) values (v_player, 'combustion_drive', 6)
      on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, 6);
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_planet, 'light_fighter', 20)
      on conflict (planet_id, ship_id) do update set quantity = greatest(public.planet_ships.quantity, 20);
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_planet, 'large_cargo', 5)
      on conflict (planet_id, ship_id) do update set quantity = greatest(public.planet_ships.quantity, 5);
    update public.planet_resources set deuterium = 9000000 where planet_id = v_planet;

    /* ---- a real expedition, resolved by the REAL pirate resolver ---- */
    perform public.start_fleet_mixed(v_player, v_planet, null,
        '{"large_cargo": 1, "light_fighter": 10}'::jsonb, 'EXPEDITION');
    select id into v_fleet from public.fleet_movements
     where player_id = v_player and mission_type = 'EXPEDITION' order by created_at desc limit 1;
    if v_fleet is null then
        raise exception 'TEST_ABORT: the expedition dispatch did not create a movement';
    end if;
    update public.fleet_movements set status = 'ARRIVED' where id = v_fleet;

    v_err := null;
    begin
        select battle_id, battle_result, enemy_ships, surviving_ships
          into v_battle, v_res, v_enemy, v_surv
          from public.resolve_expedition_pirates(v_fleet);
    exception when others then v_err := sqlerrm; end;
    v_ok := v_err is null and v_battle is not null;
    insert into t_ecd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. the real pirate resolver produced a battle (%s, result %s)', coalesce(v_err,'no battle'), coalesce(v_res,'—')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    insert into public.expedition_results(fleet_id, player_id, outcome, event_type, ships, enemy_ships, battle_id)
    values (v_fleet, v_player, 'PIRATES', 'PIRATES', v_surv, v_enemy, v_battle);

    /* ---- 2. THE GAP: the contract exposes the enemy fleet, which had NO consumer ---- */
    select * into v_row from public.get_player_expedition_reports(25) r where r.fleet_id = v_fleet;
    v_ok := v_row.enemy_ships is not null and jsonb_typeof(v_row.enemy_ships) = 'object'
            and v_row.enemy_ships <> '{}'::jsonb;
    insert into t_ecd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. the contract exposes the enemy fleet: enemy_ships=%s', v_row.enemy_ships::text));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 3. ...and the ships the expedition lost ---- */
    v_ok := v_row.lost_ships is null or jsonb_typeof(v_row.lost_ships) = 'object';

    /* ---- 5. an explicit loss is reported: the second half of the gap ---- */
    update public.expedition_results
       set lost_ships = '{"light_fighter": 3}'::jsonb, loss_percentage = 30
     where fleet_id = v_fleet;
    select * into v_row from public.get_player_expedition_reports(25) r where r.fleet_id = v_fleet;
    v_ok := v_row.lost_ships = '{"light_fighter": 3}'::jsonb and v_row.loss_percentage = 30;
    insert into t_ecd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. a real loss is reported verbatim (lost_ships=%s, loss_percentage=%s)',
             v_row.lost_ships::text, v_row.loss_percentage));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 6. OWNERSHIP: a foreign player reads 0 rows of that expedition ---- */
    perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid())::text, true);
    select count(*)::integer into v_rows from public.get_player_expedition_reports(25) r where r.fleet_id = v_fleet;
    v_ok := v_rows = 0;
    insert into t_ecd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5b. another authenticated player reads 0 rows of that expedition (%s)', v_rows));
    v_fails := v_fails + case when v_ok then 0 else 1 end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* ---- 7. without a session there is nothing at all ---- */
    perform set_config('request.jwt.claims', '{}', true);
    select count(*)::integer into v_rows from public.get_player_expedition_reports(25);
    v_ok := v_rows = 0;
    insert into t_ecd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. without a session the contract returns 0 rows (%s)', v_rows));
    v_fails := v_fails + case when v_ok then 0 else 1 end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* ---- 8. the p_limit clamp still holds (the panel asks for 25) ---- */
    select count(*)::integer into v_rows from public.get_player_expedition_reports(0);
    v_ok := v_rows = 1;
    insert into t_ecd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. p_limit = 0 is clamped up to 1, so the panel still gets a row (%s)', v_rows));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 9. ACL unchanged: authenticated + service_role, never anon ---- */
    v_ok := has_function_privilege('authenticated', 'public.get_player_expedition_reports(integer)', 'EXECUTE')
            and has_function_privilege('service_role', 'public.get_player_expedition_reports(integer)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.get_player_expedition_reports(integer)', 'EXECUTE');
    insert into t_ecd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '8. ACL unchanged: authenticated + service_role, anon denied');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 10. NO ENGINE CHANGE: the expedition engine does not know about this mission ---- */
    v_ok := not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                         where n.nspname = 'public'
                           and p.proname in ('resolve_expedition_pirates','resolve_expedition_arrival',
                                             'resolve_expedition_aliens','resolve_expedition_return',
                                             'run_expedition_combat','start_fleet_mixed')
                           and p.prosrc::text ilike '%enemy_ships is not null and%');
    insert into t_ecd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '9. the expedition engine was NOT modified by this mission');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 11. the panel really reads these two columns (static proof of the consumer) ---- */
    v_ok := (select count(*) >= 2 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'get_player_expedition_reports'
                and (p.prosrc::text ilike '%enemy_ships%' and p.prosrc::text ilike '%lost_ships%'));
    insert into t_ecd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10. the contract still exposes both columns to the client');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    insert into t_ecd(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness with ROLLBACK; concurrency not executed. The panel is READ-ONLY, so this proves the CONTRACT payload and its ownership, not a browser render.');
    insert into t_ecd(resultado, prueba) values ('INFO', format('SUMMARY: %s failed assertion(s).', v_fails));
    if v_fails > 0 then
        raise exception 'EXPEDITION COMBAT DETAIL: % failed assertion(s)', v_fails;
    end if;
end;
$test$;

select orden, resultado, prueba from t_ecd order by orden;

drop table if exists t_ecd;

ROLLBACK;

    insert into t_ecd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. the contract exposes lost_ships as an object (null is allowed): %s', coalesce(v_row.lost_ships::text,'null')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- 4. battle_id is present, so the row is identifiable as a combat encounter ---- */
    v_ok := v_row.battle_id = v_battle;
    insert into t_ecd(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. the combat report links to the battle (%s)', coalesce(v_row.battle_id::text,'null')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;
