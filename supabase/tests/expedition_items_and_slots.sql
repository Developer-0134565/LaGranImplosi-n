-- EXPEDITION ITEMS & SLOTS FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract under test (migrations 20260925202506 + 20260925202529):
--   * `expedition_settings` exists for the ACTIVE universe (the block replicated the project's own configured
--     weights there), so `resolve_expedition_arrival` can resolve;
--   * `use_expedition_item` is owner-gated (auth.uid() → players.user_id → player; optional planet ownership)
--     and reachable by `authenticated`;
--   * activating an item consumes the stack and creates an ACTIVE effect row (`expedition_item_uses`);
--   * `get_active_expedition_item_effect` therefore returns the effects and the consumers use them
--     (production, storage, research time, expedition slots, fleet speed, building speed);
--   * `get_player_expedition_slots` = 1 + settings bonus + active item slots;
--   * the new read contracts are owner-scoped and the tables stay closed to clients.
--
-- LIMITATION: single-session harness. Reward/replay safety is asserted through the resolver's idempotency
-- guard, not through true concurrency.

begin;

/* FLEET SLOTS PREREQUISITE (2026-09-26): the engine now enforces 1 + computer_technology simultaneous fleets
   on every fleet_movements insert (trigger trg_enforce_fleet_slots). This fixture needs several live
   movements at once, so it grants a high computer_technology level to every player before exercising its
   contract. See supabase/tests/fleet_slots_enforcement.sql for the enforcement fixture. */
insert into public.player_research(player_id, research_id, level)
select pl.id, 'computer_technology', 60
from public.players pl
on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, excluded.level);


drop table if exists t_exp_item_results;
create temp table t_exp_item_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth_a uuid; v_player uuid; v_planet uuid; v_universe uuid;
    v_player_b uuid; v_planet_b uuid;
    v_info record; v_slot record; v_item record;
    v_prod_before record; v_prod_after record;
    v_stor_before numeric; v_stor_after numeric;
    v_can record; v_canonical numeric;
    v_fleet uuid; v_fleet2 uuid; v_fleet3 uuid; v_tries integer := 0; v_outcome text; v_total numeric;
    v_items_before integer; v_item_id text;
    v_json jsonb; v_msg text; v_ok boolean; v_fail integer := 0;
begin
    /* ------------------------------------------------------------------ FIXTURE */
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth_a, v_universe
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

    delete from public.expedition_item_uses where player_id = v_player;
    delete from public.player_expedition_items where player_id = v_player;
    delete from public.expedition_results where player_id = v_player;
    delete from public.research_queue where player_id = v_player;

    -- enough energy and a visible mine so item production bonuses are measurable
    delete from public.planet_buildings where planet_id = v_planet;
    insert into public.planet_buildings(planet_id, building_id, level)
    values (v_planet, 'crystal_mine', 5), (v_planet, 'metal_mine', 5), (v_planet, 'solar_plant', 30)
    on conflict (planet_id, building_id) do update set level = excluded.level;

    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at)
    values (v_planet, 100000, 100000, 100000, 0, now())
    on conflict (planet_id) do update
       set metal = 100000, crystal = 100000, deuterium = 100000, energy = 0, last_calculated_at = now();

    /* ---------------------------------------- 1. CONFIG: el universo activo puede resolver */
    select count(*) into v_items_before from public.expedition_settings where universe_id = v_universe;
    v_ok := v_items_before = 1;
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. the active universe %s has a configured expedition_settings row (rows=%s)', v_universe, v_items_before));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select (es.weight_ships+es.weight_resources+es.weight_delay+es.weight_speedup+es.weight_nothing
            +es.weight_black_hole+es.weight_pirates+es.weight_aliens+es.weight_dark_matter
            +es.weight_merchant+es.weight_items) into v_total
      from public.expedition_settings es where es.universe_id = v_universe;
    v_ok := v_total is not null and v_total > 0;
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. the configured weight total is usable (sum = %s)', v_total));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* --------------------------------------------- 3. SLOTS: base sin objetos */
    select * into v_slot from public.get_player_expedition_slot_status();
    v_ok := v_slot.base_slots = 1 and v_slot.settings_bonus = 0 and v_slot.item_bonus = 0
        and v_slot.total_slots = 1 and v_slot.used_slots = 0 and v_slot.available_slots = 1;
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. slot status without items [base=%s settings=%s items=%s total=%s available=%s]',
             v_slot.base_slots, v_slot.settings_bonus, v_slot.item_bonus, v_slot.total_slots, v_slot.available_slots));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ----------------------------------- 4. ACTIVACIÓN de un objeto de slots */
    insert into public.player_expedition_items(player_id, item_id, quantity, active)
    values (v_player, 'expedition_slots_1', 1, true);

    v_json := public.use_expedition_item(v_player, 'expedition_slots_1', v_planet);
    select * into v_item from public.player_expedition_items
     where player_id = v_player and item_id = 'expedition_slots_1';
    v_ok := (v_json->>'effect_key') = 'expedition_slots'
        and (v_json->>'effect_value')::numeric = 1
        and (v_json->>'expires_at') is not null
        and v_item.quantity = 0 and v_item.active = false
        and (select count(*) from public.expedition_item_uses
              where player_id = v_player and item_id = 'expedition_slots_1') = 1;
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. activation consumes the stack (qty=%s active=%s) and creates one active effect row [%s]',
             v_item.quantity, v_item.active, v_json));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------------------------------- 5. EFECTO: slots + 1 */
    v_ok := public.get_player_expedition_slots(v_player) = 2
        and public.get_active_expedition_item_effect(v_player, v_planet, 'expedition_slots') = 1;
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. slots = 1 + settings + item = %s and the effect reader returns 1',
             public.get_player_expedition_slots(v_player)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select * into v_slot from public.get_player_expedition_slot_status();
    v_ok := v_slot.item_bonus = 1 and v_slot.total_slots = 2 and v_slot.available_slots = 2;
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '6. the owner-scoped slot status reflects the active item bonus');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select * into v_item from public.get_player_expedition_item_status()
     where kind = 'EFFECT' and item_id = 'expedition_slots_1';
    v_ok := v_item.item_id is not null and v_item.effect_key = 'expedition_slots'
        and v_item.remaining_seconds is not null and v_item.remaining_seconds > 0;
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. the item status contract exposes the active effect with %s s remaining', v_item.remaining_seconds));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------ 8. CONSUMO: un stack agotado no puede reutilizarse */
    begin
        v_json := public.use_expedition_item(v_player, 'expedition_slots_1', v_planet);
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'Item % not available%';
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. an exhausted stack cannot be activated again [%s]', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ----------------------------------- 9. EFECTO DE PRODUCCIÓN (+10 %) */
    select * into v_prod_before from public.calculate_planet_production(v_planet);
    insert into public.player_expedition_items(player_id, item_id, quantity, active)
    values (v_player, 'resource_boost_10', 1, true);
    perform public.use_expedition_item(v_player, 'resource_boost_10', v_planet);
    select * into v_prod_after from public.calculate_planet_production(v_planet);
    v_ok := abs(v_prod_after.metal_per_hour - v_prod_before.metal_per_hour * 1.1) < 0.0001
        and abs(v_prod_after.crystal_per_hour - v_prod_before.crystal_per_hour * 1.1) < 0.0001
        and abs(v_prod_after.deuterium_per_hour - v_prod_before.deuterium_per_hour * 1.1) < 0.0001;
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. production +10%% applies to M/C/D [metal %s -> %s, crystal %s -> %s]',
             v_prod_before.metal_per_hour, v_prod_after.metal_per_hour,
             v_prod_before.crystal_per_hour, v_prod_after.crystal_per_hour));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------- 10. EFECTO DE ALMACÉN (+25 %) */
    select metal_capacity into v_stor_before from public.calculate_planet_storage(v_planet);
    insert into public.player_expedition_items(player_id, item_id, quantity, active)
    values (v_player, 'storage_boost_25', 1, true);
    perform public.use_expedition_item(v_player, 'storage_boost_25', v_planet);
    select metal_capacity into v_stor_after from public.calculate_planet_storage(v_planet);
    v_ok := v_stor_before > 0 and abs(v_stor_after - v_stor_before * 1.25) < 0.0001;
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. storage +25%% applies [capacity %s -> %s]', v_stor_before, v_stor_after));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ----------------------------- 11. EFECTO DE INVESTIGACIÓN (+10 % de velocidad) */
    insert into public.player_expedition_items(player_id, item_id, quantity, active)
    values (v_player, 'research_boost_10', 1, true);
    perform public.use_expedition_item(v_player, 'research_boost_10', v_planet);
    select * into v_can from public.can_start_research(v_player, v_planet, 'energy_technology');
    v_canonical := public.calculate_research_time('energy_technology', v_can.target_level, v_universe);
    v_ok := v_can.item_bonus_percent = 10
        and abs(v_can.research_seconds - round(v_canonical / 1.1, 4)) < 0.0001;
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11. research +10%% shortens the authoritative time [%s vs canonical %s, bonus %s%%]',
             v_can.research_seconds, v_canonical, v_can.item_bonus_percent));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* --------------- 12. EFECTOS DE FLOTA Y CONSTRUCCIÓN: lector + consumo real verificado */
    insert into public.player_expedition_items(player_id, item_id, quantity, active)
    values (v_player, 'fleet_boost_10', 1, true), (v_player, 'building_boost_10', 1, true);
    perform public.use_expedition_item(v_player, 'fleet_boost_10', v_planet);
    perform public.use_expedition_item(v_player, 'building_boost_10', v_planet);
    v_ok := public.get_active_expedition_item_effect(v_player, v_planet, 'fleet_speed_percent') = 10
        and public.get_active_expedition_item_effect(v_player, v_planet, 'building_speed_percent') = 10
        and (select prosrc like '%''fleet_speed_percent''%' from pg_proc where proname = 'start_fleet_mixed')
        and (select prosrc like '%''building_speed_percent''%' from pg_proc where proname = 'start_building');
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '12. fleet/building item effects are readable AND consumed by start_fleet_mixed / start_building');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* -------------------------------- 13. EXPIRACIÓN de un efecto de investigación */
    update public.expedition_item_uses
       set effect_snapshot = jsonb_set(effect_snapshot, '{expires_at}',
                                       to_jsonb((now() - interval '1 second')::text))
     where player_id = v_player and item_id = 'research_boost_10';
    v_ok := public.get_active_expedition_item_effect(v_player, v_planet, 'research_speed_percent') = 0
        and not exists (select 1 from public.get_player_expedition_item_status()
                         where kind = 'EFFECT' and item_id = 'research_boost_10');
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '13. an expired effect is neither returned by the reader nor listed as active');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------------------------- 14. EXPIRACIÓN del bonus de slots */
    update public.expedition_item_uses
       set effect_snapshot = jsonb_set(effect_snapshot, '{expires_at}',
                                       to_jsonb((now() - interval '1 second')::text))
     where player_id = v_player and item_id = 'expedition_slots_1';
    select * into v_slot from public.get_player_expedition_slot_status();
    v_ok := public.get_player_expedition_slots(v_player) = 1 and v_slot.item_bonus = 0 and v_slot.total_slots = 1;
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('14. an expired slot bonus returns the total to base [slots=%s items=%s]',
             public.get_player_expedition_slots(v_player), v_slot.item_bonus));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------------------ 15-19. SEGURIDAD */
    insert into public.player_expedition_items(player_id, item_id, quantity, active)
    values (v_player, 'expedition_slots_1', 2, true);

    begin
        v_json := public.use_expedition_item(v_player_b, 'expedition_slots_1', v_planet);
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'Player does not belong to authenticated user%';
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('15. a player cannot activate items for another player [%s]', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    perform set_config('request.jwt.claims', '{}', true);
    begin
        v_json := public.use_expedition_item(v_player, 'expedition_slots_1', v_planet);
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'Authentication required%';
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('16. unauthenticated activation rejected [%s]', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_a)::text, true);

    begin
        v_json := public.use_expedition_item(v_player, 'item_that_does_not_exist', v_planet);
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'Unknown or inactive item%';
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('17. unknown item rejected [%s]', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    begin
        v_json := public.use_expedition_item(v_player, 'expedition_slots_1', v_planet_b);
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'PLANET_NOT_FOUND_OR_NOT_OWNED%';
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('18. a foreign planet cannot host the effect [%s]', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select coalesce(sum(quantity),0) from public.player_expedition_items
              where player_id = v_player and item_id = 'expedition_slots_1') = 2
        and (select count(*) from public.expedition_item_uses
              where player_id = v_player and item_id = 'expedition_slots_1'
                and (effect_snapshot->>'expires_at')::timestamptz > now()) = 0;
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '19. every rejected activation left the stack and the effect table untouched (stack 2, no active row)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* -------------------- 20. RECOMPENSA: la vía de premio crea el objeto y lo registra */
    insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status)
    values (v_player,v_planet,NULL,'EXPEDITION',now()-interval '2 hours',now(),'ARRIVED')
    returning id into v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'large_cargo', 1);
    insert into public.expedition_results(fleet_id, player_id, outcome, event_type)
    values (v_fleet, v_player, 'ITEMS', 'ITEMS');

    select coalesce(sum(quantity),0) into v_items_before
      from public.player_expedition_items where player_id = v_player;
    perform public.resolve_expedition_item(v_fleet);
    v_ok := (select coalesce(sum(quantity),0) from public.player_expedition_items where player_id = v_player) = v_items_before + 1
        and (select item_id from public.expedition_results where fleet_id = v_fleet) is not null
        and (select count(*) from public.expedition_item_definitions d
              where d.id = (select item_id from public.expedition_results where fleet_id = v_fleet)) = 1;
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('20. the reward path stores exactly one item [%s] and records it in expedition_results',
             (select item_id from public.expedition_results where fleet_id = v_fleet)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ----------------- 21. REPLAY: una expedición ya liquidada no vuelve a premiar */
    insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status)
    values (v_player,v_planet,NULL,'EXPEDITION',now()-interval '2 hours',now(),'ARRIVED')
    returning id into v_fleet2;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet2, 'large_cargo', 1);
    insert into public.expedition_results(fleet_id, player_id, outcome, metal, crystal, deuterium)
    values (v_fleet2, v_player, 'RESOURCES', 111, 222, 333);

    v_ok := public.resolve_expedition_arrival(v_fleet2) = 'RESOURCES'
        and (select metal + crystal + deuterium from public.fleet_movements where id = v_fleet2) = 0
        and (select count(*) from public.expedition_results where fleet_id = v_fleet2) = 1;
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '21. a replay of a settled expedition returns the recorded outcome and awards nothing again');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------- 22. RESOLUCIÓN REAL en el universo activo (prueba de la configuración aplicada) */
    loop
        v_tries := v_tries + 1;
        insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status,metal,crystal,deuterium)
        values (v_player,v_planet,NULL,'EXPEDITION',now()-interval '2 hours',now(),'ARRIVED',0,0,0)
        returning id into v_fleet3;
        insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet3, 'large_cargo', 1);

        select (es.weight_ships+es.weight_resources+es.weight_delay+es.weight_speedup+es.weight_nothing
                +es.weight_black_hole+es.weight_pirates+es.weight_aliens+es.weight_dark_matter
                +es.weight_merchant+es.weight_items) into v_total
          from public.expedition_settings es where es.universe_id = v_universe;

        v_outcome := public.select_expedition_outcome(v_universe, public.expedition_event_random(v_fleet3,'outcome')*v_total);
        exit when v_outcome = 'RESOURCES' or v_tries >= 60;

        delete from public.fleet_movement_ships where fleet_id = v_fleet3;
        delete from public.fleet_movements where id = v_fleet3;
    end loop;

    if v_outcome <> 'RESOURCES' then
        raise exception 'TEST_ABORT: no RESOURCES expedition id found in % candidate(s)', v_tries;
    end if;

    v_outcome := public.resolve_expedition_arrival(v_fleet3);
    v_ok := v_outcome = 'RESOURCES'
        and (select status from public.fleet_movements where id = v_fleet3) = 'RETURNING'
        and (select count(*) from public.expedition_results where fleet_id = v_fleet3) = 1;
    insert into t_exp_item_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('22. the active universe resolves a real expedition end-to-end [%s] (impossible before the config row)', v_outcome));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_exp_item_results(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; true concurrency and full RNG coverage are not executed. Replay safety is asserted through the resolver idempotency guard.');

    if v_fail > 0 then
        raise exception 'EXPEDITION ITEMS & SLOTS FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_exp_item_results order by orden;

drop table if exists t_exp_item_results;

ROLLBACK;
