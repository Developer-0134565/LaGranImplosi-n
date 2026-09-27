-- QUEUE CANCELLATION FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract under test (migration 20260926082120_cancel_building_and_research_queue_contract):
--   * `cancel_building(queue_id)` / `cancel_research(queue_id)`: SECURITY DEFINER, EXECUTE only for
--     `authenticated`/`service_role`;
--   * ownership from `auth.uid()` → `players.user_id` → `planets.player_id`; foreign planet/player rejected;
--   * refund = EXACTLY the price the start path charged (same certified cost function, row's target_level);
--     OGameX parity: 100 %, no penalty;
--   * `COMPLETED` is terminal and refunds nothing;
--   * an already-due item is COMPLETED by the authoritative tick inside the call and then refused, so a row
--     can never be refunded AND granted;
--   * every rejection raises before mutating resources (no double refund, retry-safe);
--   * the shipyard/defence queues deliberately have NO cancellation (OGameX: "unit queue objects cannot be
--     canceled").
--
-- LIMITATION: single-session harness. Atomicity is asserted as "a rejected call leaves resources, queue
-- statuses and levels untouched"; true concurrency is not executed (declared, not faked).

begin;

drop table if exists t_cancel_results;
create temp table t_cancel_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid;
    v_player uuid;
    v_planet uuid;
    v_foreign_player uuid;
    v_foreign_planet uuid;
    v_other_auth uuid;
    v_queue uuid;
    v_queue2 uuid;
    v_cost record;
    v_refund record;
    v_mb numeric; v_cb numeric; v_db numeric;
    v_ma numeric; v_ca numeric; v_da numeric;
    v_status text;
    v_level integer;
    v_blocked boolean;
    v_err text;
    v_allowed boolean;
    v_auth_exec boolean;
    v_anon_exec boolean;
    v_ok boolean;
    v_fail integer := 0;
begin
    select pl.id, pl.user_id into v_player, v_auth
      from public.players pl where pl.user_id is not null
     order by pl.created_at, pl.id limit 1;

    select p.id into v_planet
      from public.planets p
     where p.player_id = v_player and not p.is_destroyed
     order by p.created_at, p.id limit 1;

    select pl.id, p.id into v_foreign_player, v_foreign_planet
      from public.planets p join public.players pl on pl.id = p.player_id
     where not p.is_destroyed and pl.id <> v_player
     order by p.created_at, p.id limit 1;

    if v_player is null or v_planet is null or v_foreign_player is null or v_foreign_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet and a foreign planet are required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* A synthetic authenticated identity that owns nothing: used to prove the ownership gate from the
       caller side. No live auth user is impersonated and no player row is modified. */
    v_other_auth := gen_random_uuid();

    /* Isolate: no buildings (zero production => resource assertions are exact), empty queues. */
    delete from public.planet_buildings where planet_id = v_planet;
    delete from public.building_queue where planet_id = v_planet;
    delete from public.research_queue where player_id = v_player;
    delete from public.player_research where player_id = v_player and research_id = 'energy_technology';
    update public.planets set fields_used = 0 where id = v_planet;

    /* Precondition of the certified research gate (migration 20260926180000, active since 2026-09-26): the
       fixture wipes every building, but `start_research` (line 3 of this suite) now requires a Research
       Laboratory on the planet that starts the research, so it was refused with
       RESEARCH_REQUIREMENTS_NOT_MET before exercising anything. The level is derived from the contract itself
       (`research_building_prerequisites`), never hardcoded. The laboratory produces no metal/crystal/deuterium,
       so the exact-refund assertions of this suite are unaffected. */
    insert into public.planet_buildings(planet_id, building_id, level)
    select v_planet, 'research_lab', max(rbp.required_level)
      from public.research_building_prerequisites rbp
     where rbp.research_id = 'energy_technology'
    on conflict (planet_id, building_id) do update set level = excluded.level;

    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at)
    values (v_planet, 100000, 100000, 100000, 0, now())
    on conflict (planet_id) do update
       set metal = 100000, crystal = 100000, deuterium = 100000, energy = 0, last_calculated_at = now();

    /* ------------------------------------------- 1. VALID BUILDING CANCEL */
    v_queue := public.start_building(v_player, v_planet, 'metal_mine');

    select c.metal, c.crystal, c.deuterium into v_cost
      from public.calculate_building_cost('metal_mine', 1) c;

    select metal, crystal, deuterium into v_mb, v_cb, v_db
      from public.planet_resources where planet_id = v_planet;

    select * into v_refund from public.cancel_building(v_queue);

    select metal, crystal, deuterium into v_ma, v_ca, v_da
      from public.planet_resources where planet_id = v_planet;

    select status into v_status from public.building_queue where id = v_queue;
    select count(*)::integer into v_level from public.planet_buildings
     where planet_id = v_planet and building_id = 'metal_mine' and level > 0;

    v_ok := v_refund.status = 'CANCELLED'
        and v_refund.refund_metal = v_cost.metal
        and v_refund.refund_crystal = v_cost.crystal
        and v_refund.refund_deuterium = v_cost.deuterium
        and v_status = 'CANCELLED' and v_level = 0
        and v_ma = v_mb + v_cost.metal and v_ca = v_cb + v_cost.crystal and v_da = v_db + v_cost.deuterium;
    insert into t_cancel_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. building cancel: exact refund %s/%s/%s, status %s, level %s',
             v_refund.refund_metal, v_refund.refund_crystal, v_refund.refund_deuterium, v_status, v_level));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------- 2. QUEUE RELEASED AFTER THE CANCEL */
    select bool_and(bq.status <> 'BUILDING') into v_ok
      from public.building_queue bq where bq.planet_id = v_planet;

    select c.allowed into v_allowed
      from public.can_start_building(v_player, v_planet, 'metal_mine') c;

    v_ok := v_ok and v_allowed;
    insert into t_cancel_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. queue released: no active row, can_start_building = %s', v_allowed));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------- 3. VALID RESEARCH CANCEL */
    v_queue := public.start_research(v_player, v_planet, 'energy_technology');

    select c.metal, c.crystal, c.deuterium into v_cost
      from public.calculate_research_cost('energy_technology', 1) c;

    select metal, crystal, deuterium into v_mb, v_cb, v_db
      from public.planet_resources where planet_id = v_planet;

    select * into v_refund from public.cancel_research(v_queue);

    select metal, crystal, deuterium into v_ma, v_ca, v_da
      from public.planet_resources where planet_id = v_planet;

    select status into v_status from public.research_queue where id = v_queue;
    select coalesce(max(level), 0) into v_level from public.player_research
     where player_id = v_player and research_id = 'energy_technology';

    v_ok := v_refund.status = 'CANCELLED'
        and v_refund.planet_id = v_planet
        and v_refund.refund_metal = v_cost.metal
        and v_refund.refund_crystal = v_cost.crystal
        and v_refund.refund_deuterium = v_cost.deuterium
        and v_status = 'CANCELLED' and v_level = 0
        and v_ma = v_mb + v_cost.metal and v_ca = v_cb + v_cost.crystal and v_da = v_db + v_cost.deuterium;
    insert into t_cancel_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. research cancel: exact refund %s/%s/%s to planet %s, status %s, level %s',
             v_refund.refund_metal, v_refund.refund_crystal, v_refund.refund_deuterium,
             v_refund.planet_id, v_status, v_level));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 4. DOUBLE CANCEL (building) REFUSED, NO EXTRA REFUND */
    insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status)
    values (v_planet, 'crystal_mine', 1, now(), now() + interval '1 hour', 'CANCELLED')
    returning id into v_queue;

    select metal, crystal, deuterium into v_mb, v_cb, v_db
      from public.planet_resources where planet_id = v_planet;

    v_blocked := false; v_err := null;
    begin
        perform * from public.cancel_building(v_queue);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;

    select metal, crystal, deuterium into v_ma, v_ca, v_da
      from public.planet_resources where planet_id = v_planet;

    v_ok := v_blocked and v_err like 'BUILDING_QUEUE_NOT_CANCELLABLE%'
        and v_ma = v_mb and v_ca = v_cb and v_da = v_db;
    insert into t_cancel_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. double cancel (building) refused with no refund [%s / %s]', v_blocked, v_err));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 5. DOUBLE CANCEL (research) REFUSED, NO EXTRA REFUND */
    insert into public.research_queue(player_id, planet_id, research_id, target_level, started_at, finishes_at, status)
    values (v_player, v_planet, 'energy_technology', 1, now(), now() + interval '1 hour', 'CANCELLED')
    returning id into v_queue2;

    v_blocked := false; v_err := null;
    begin
        perform * from public.cancel_research(v_queue2);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;

    select metal, crystal, deuterium into v_ma, v_ca, v_da
      from public.planet_resources where planet_id = v_planet;

    v_ok := v_blocked and v_err like 'RESEARCH_QUEUE_NOT_CANCELLABLE%'
        and v_ma = v_mb and v_ca = v_cb and v_da = v_db;
    insert into t_cancel_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. double cancel (research) refused with no refund [%s / %s]', v_blocked, v_err));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 6. FOREIGN CALLER CANNOT CANCEL AN OWNED PLANET'S ITEM */
    insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status)
    values (v_planet, 'metal_mine', 1, now(), now() + interval '1 hour', 'BUILDING')
    returning id into v_queue;

    v_blocked := false; v_err := null;
    begin
        perform set_config('request.jwt.claims', json_build_object('sub', v_other_auth)::text, true);

        select metal, crystal, deuterium into v_mb, v_cb, v_db
          from public.planet_resources where planet_id = v_planet;

        perform * from public.cancel_building(v_queue);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    select metal, crystal, deuterium into v_ma, v_ca, v_da
      from public.planet_resources where planet_id = v_planet;
    select status into v_status from public.building_queue where id = v_queue;

    v_ok := v_blocked and v_err = 'PLANET_NOT_FOUND_OR_NOT_OWNED' and v_status = 'BUILDING'
        and v_ma = v_mb and v_ca = v_cb and v_da = v_db;
    insert into t_cancel_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. foreign caller refused by the ownership gate, item still %s, no refund [%s / %s]',
             v_status, v_blocked, v_err));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 7. FOREIGN CALLER CANNOT CANCEL AN OWNED RESEARCH ITEM */
    insert into public.research_queue(player_id, planet_id, research_id, target_level, started_at, finishes_at, status)
    values (v_player, v_planet, 'energy_technology', 1, now(), now() + interval '1 hour', 'RESEARCHING')
    returning id into v_queue2;

    v_blocked := false; v_err := null;
    begin
        perform set_config('request.jwt.claims', json_build_object('sub', v_other_auth)::text, true);
        perform * from public.cancel_research(v_queue2);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    select status into v_status from public.research_queue where id = v_queue2;

    v_ok := v_blocked and v_err = 'PLAYER_NOT_OWNED' and v_status = 'RESEARCHING';
    insert into t_cancel_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. foreign caller refused for research, item still %s [%s / %s]', v_status, v_blocked, v_err));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 8. COMPLETED IS TERMINAL: REFUSED, NO REFUND */
    insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status)
    values (v_planet, 'solar_plant', 1, now() - interval '2 hours', now() - interval '1 hour', 'COMPLETED')
    returning id into v_queue;

    select metal, crystal, deuterium into v_mb, v_cb, v_db
      from public.planet_resources where planet_id = v_planet;

    v_blocked := false; v_err := null;
    begin
        perform * from public.cancel_building(v_queue);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;

    select metal, crystal, deuterium into v_ma, v_ca, v_da
      from public.planet_resources where planet_id = v_planet;
    select status into v_status from public.building_queue where id = v_queue;

    v_ok := v_blocked and v_err like 'BUILDING_QUEUE_NOT_CANCELLABLE%'
        and v_status = 'COMPLETED'
        and v_ma = v_mb and v_ca = v_cb and v_da = v_db;
    insert into t_cancel_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. COMPLETED row refused, status preserved, no refund [%s / %s]', v_blocked, v_err));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- 9. AN ALREADY-DUE ITEM IS COMPLETED BY THE TICK, THEN REFUSED (no double credit) */
    delete from public.planet_buildings where planet_id = v_planet;
    delete from public.building_queue where planet_id = v_planet;

    select metal, crystal, deuterium into v_mb, v_cb, v_db
      from public.planet_resources where planet_id = v_planet;

    /* shipyard produces no resources, so the post-charge values stay exact. */
    v_queue := public.start_building(v_player, v_planet, 'shipyard');

    select c.metal, c.crystal, c.deuterium into v_cost
      from public.calculate_building_cost('shipyard', 1) c;

    /* Due, without invalidating the settlement watermark (until >= last_calculated_at). */
    update public.building_queue
       set started_at = now() - interval '2 hours',
           finishes_at = (select pr.last_calculated_at from public.planet_resources pr
                           where pr.planet_id = v_planet)
     where id = v_queue;

    v_blocked := false; v_err := null;
    begin
        perform * from public.cancel_building(v_queue);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;

    select status into v_status from public.building_queue where id = v_queue;
    select coalesce(max(level), 0) into v_level from public.planet_buildings
     where planet_id = v_planet and building_id = 'shipyard';
    select metal, crystal, deuterium into v_ma, v_ca, v_da
      from public.planet_resources where planet_id = v_planet;

    v_ok := v_blocked and v_err like 'BUILDING_QUEUE_NOT_CANCELLABLE%'
        and v_status = 'BUILDING' and v_level = 0
        and v_ma = v_mb - v_cost.metal and v_ca = v_cb - v_cost.crystal and v_da = v_db - v_cost.deuterium;
    insert into t_cancel_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. due item: the tick completes it, the cancel is REFUSED and the refusal unwinds the tick [still %s, level %s, no refund; %s]',
             v_status, v_level, v_err));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- 9b. THE EVENTUAL SETTLEMENT GRANTS THE LEVEL EXACTLY ONCE AND REFUNDS NOTHING ---- */
    perform * from public.process_planet_tick(v_planet);

    select status into v_status from public.building_queue where id = v_queue;
    select coalesce(max(level), 0) into v_level from public.planet_buildings
     where planet_id = v_planet and building_id = 'shipyard';
    select metal, crystal, deuterium into v_ma, v_ca, v_da
      from public.planet_resources where planet_id = v_planet;

    v_ok := v_status = 'COMPLETED' and v_level = 1
        and v_ma = v_mb - v_cost.metal and v_ca = v_cb - v_cost.crystal and v_da = v_db - v_cost.deuterium;
    insert into t_cancel_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9b. the next settlement grants the level once (%s, %s) and still refunds nothing', v_status, v_level));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 10. UNAUTHENTICATED ACTOR REFUSED, NO MUTATION */
    perform set_config('request.jwt.claims', '{}', true);

    v_blocked := false; v_err := null;
    begin
        perform * from public.cancel_building(v_queue);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;
    v_ok := v_blocked and v_err = 'Authentication required';
    insert into t_cancel_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10a. unauthenticated cancel_building refused [%s / %s]', v_blocked, v_err));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_blocked := false; v_err := null;
    begin
        perform * from public.cancel_research(v_queue2);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;
    v_ok := v_blocked and v_err = 'Authentication required';
    insert into t_cancel_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10b. unauthenticated cancel_research refused [%s / %s]', v_blocked, v_err));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* ---------------------- 11. ACL + OGameX PARITY (no shipyard/defence cancellation) */
    select has_function_privilege('authenticated', 'public.cancel_building(uuid)', 'EXECUTE')
       and has_function_privilege('authenticated', 'public.cancel_research(uuid)', 'EXECUTE')
      into v_auth_exec;

    select has_function_privilege('anon', 'public.cancel_building(uuid)', 'EXECUTE')
        or has_function_privilege('anon', 'public.cancel_research(uuid)', 'EXECUTE')
      into v_anon_exec;

    select count(*)::integer into v_level
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like 'cancel\_%';

    v_ok := v_auth_exec and not v_anon_exec and v_level = 2;
    insert into t_cancel_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11. ACL authenticated=%s anon=%s; exactly %s cancel_* function(s) exist (shipyard/defence keep none)',
             v_auth_exec, v_anon_exec, v_level));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_cancel_results(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; concurrency is not executed. Rejections are asserted to leave resources, queue statuses and levels untouched.');

    if v_fail > 0 then
        raise exception 'QUEUE CANCELLATION FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_cancel_results order by orden;

drop table if exists t_cancel_results;

ROLLBACK;



