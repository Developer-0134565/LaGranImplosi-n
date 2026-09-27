-- FLEET CARGO LOADING FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract under test (migration 20260925154234_expose_fleet_cargo_loading_to_owner):
--   load_fleet_cargo(p_fleet_id, p_metal, p_crystal, p_deuterium)
--     * mandatory auth.uid(); the fleet must belong to a player owned by that user;
--     * the fleet's origin planet must belong to the same player (defence in depth);
--     * status must be OUTBOUND; mission must be TRANSPORT / ESPIONAGE / ACS_HOLD;
--     * capacity = calculate_fleet_cargo_capacity (per-ship cargo_capacity + hyperspace 5%/level);
--     * availability is checked against the origin planet; the debit and the fleet credit are
--       additive and atomic (FOR UPDATE on fleet_movements + planet_resources).
--
-- Fixture isolation: everything below runs inside this transaction and is rolled back. Planet
-- buildings and hyperspace research of the fixture player are cleared so that production is 0
-- (exact resource deltas) and cargo capacity is deterministic (25000 for one large_cargo).
--
-- LIMITATION: this harness is single-session. True concurrent loading is NOT executed here; the
-- row locks (FOR UPDATE) and the additive/capacity checks are asserted on the sequential path.

begin;

/* FLEET SLOTS PREREQUISITE (2026-09-26): the engine now enforces 1 + computer_technology simultaneous fleets
   on every fleet_movements insert (trigger trg_enforce_fleet_slots). This fixture needs several live
   movements at once, so it grants a high computer_technology level to every player before exercising its
   contract. See supabase/tests/fleet_slots_enforcement.sql for the enforcement fixture. */
insert into public.player_research(player_id, research_id, level)
select pl.id, 'computer_technology', 60
from public.players pl
on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, excluded.level);


drop table if exists t_cargo_results;
create temp table t_cargo_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth_a uuid;
    v_player_a uuid; v_player_b uuid;
    v_planet_a uuid; v_planet_b uuid;
    v_f1 uuid; v_f2 uuid; v_f3 uuid; v_f4 uuid; v_f5 uuid; v_f6 uuid; v_f7 uuid;
    v_capacity numeric;
    v_metal_planet_after numeric;
    v_rec record;
    v_ok boolean;
    v_fail integer := 0;
    v_msg text;
begin
    /* ------------------------------------------------------------------ FIXTURE */
    /* authenticated actor = the existing auth-linked player; no players row is mutated */
    select pl.id, pl.user_id into v_player_a, v_auth_a
      from public.players pl where pl.user_id is not null
     order by pl.created_at limit 1;

    select p.id into v_planet_a
      from public.planets p
     where p.player_id = v_player_a and not p.is_destroyed
     order by p.created_at, p.id limit 1;

    select p.player_id, p.id into v_player_b, v_planet_b
      from public.planets p join public.players pl on pl.id = p.player_id
     where not p.is_destroyed and pl.player_type = 'AI' and p.player_id <> v_player_a
     order by p.created_at, p.id limit 1;

    if v_player_a is null or v_player_b is null or v_planet_a is null or v_planet_b is null then
        raise exception 'TEST_ABORT: one auth-linked player with a planet and one AI player with a planet are required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_a)::text, true);

    delete from public.planet_buildings where planet_id = v_planet_a;
    delete from public.player_research
     where player_id = v_player_a and research_id = 'hyperspace_technology';
    delete from public.planet_ships where planet_id = v_planet_a;
    insert into public.planet_ships(planet_id, ship_id, quantity)
    values (v_planet_a, 'large_cargo', 1);

    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at)
    values (v_planet_a, 100000, 100000, 100000, 0, now())
    on conflict (planet_id) do update
       set metal = 100000, crystal = 100000, deuterium = 100000,
           energy = 0, last_calculated_at = now();

    /* fixture-only: the write guard is BEFORE INSERT and player B stays unowned on purpose */
    alter table public.fleet_movements disable trigger trg_enforce_player_write_fleet_movements;

    insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,arrives_at)
    values (v_player_a,v_planet_a,v_planet_b,'TRANSPORT',now()+interval '1 hour') returning id into v_f1;
    insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,arrives_at)
    values (v_player_a,v_planet_a,v_planet_b,'TRANSPORT',now()+interval '1 hour') returning id into v_f2;
    insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,arrives_at)
    values (v_player_a,v_planet_a,v_planet_b,'RECYCLE',now()+interval '1 hour') returning id into v_f3;
    insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,arrives_at)
    values (v_player_b,v_planet_b,v_planet_a,'TRANSPORT',now()+interval '1 hour') returning id into v_f4;
    insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,arrives_at)
    values (v_player_a,v_planet_b,v_planet_a,'TRANSPORT',now()+interval '1 hour') returning id into v_f5;
    insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,arrives_at)
    values (v_player_a,v_planet_a,v_planet_b,'ESPIONAGE',now()+interval '1 hour') returning id into v_f6;
    insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,arrives_at,status)
    values (v_player_a,v_planet_a,v_planet_b,'TRANSPORT',now()+interval '1 hour','ARRIVED') returning id into v_f7;

    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity)
    values (v_f1, 'large_cargo', 1), (v_f2, 'large_cargo', 1), (v_f3, 'large_cargo', 1),
           (v_f4, 'large_cargo', 1), (v_f5, 'large_cargo', 1), (v_f6, 'espionage_probe', 5),
           (v_f7, 'large_cargo', 1);

    /* the write guard is restored BEFORE the contract calls, so the real path runs with it active */
    alter table public.fleet_movements enable trigger trg_enforce_player_write_fleet_movements;

    /* ------------------------------------------------------- 1-3: ACL SURFACE */
    v_ok := has_function_privilege('authenticated',
              'public.load_fleet_cargo(uuid,numeric,numeric,numeric)', 'EXECUTE');
    insert into t_cargo_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '1. EXECUTE granted to authenticated (client path is reachable)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := not has_function_privilege('anon',
              'public.load_fleet_cargo(uuid,numeric,numeric,numeric)', 'EXECUTE');
    insert into t_cargo_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '2. EXECUTE NOT granted to anon');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := has_function_privilege('service_role',
              'public.load_fleet_cargo(uuid,numeric,numeric,numeric)', 'EXECUTE');
    insert into t_cargo_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '3. EXECUTE still granted to service_role (internal callers preserved)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------- 4: NOT AUTHENTICATED */
    perform set_config('request.jwt.claims', '{}', true);
    begin
        select * into v_rec from public.load_fleet_cargo(v_f1, 10, 0, 0);
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'Authentication required%';
    insert into t_cargo_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. unauthenticated actor rejected [%s]', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_a)::text, true);

    /* ------------------------------------------- 5: FLEET NOT OWNED BY ACTOR */
    begin
        select * into v_rec from public.load_fleet_cargo(v_f4, 10, 0, 0);
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'Fleet does not belong to authenticated user%';
    insert into t_cargo_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. foreign fleet rejected [%s]', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------- 6: ORIGIN PLANET NOT OWNED BY FLEET */
    begin
        select * into v_rec from public.load_fleet_cargo(v_f5, 10, 0, 0);
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'CARGO_ORIGIN_NOT_OWNED%';
    insert into t_cargo_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. origin planet of another player rejected [%s]', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------- 7: LIFECYCLE (ARRIVED) */
    begin
        select * into v_rec from public.load_fleet_cargo(v_f7, 10, 0, 0);
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'Cargo can only be loaded while fleet is OUTBOUND%';
    insert into t_cargo_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. non-OUTBOUND fleet rejected [%s]', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* --------------------------------------------- 8: MISSION NOT COMPATIBLE */
    begin
        select * into v_rec from public.load_fleet_cargo(v_f3, 10, 0, 0);
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'CARGO_MISSION_NOT_SUPPORTED%';
    insert into t_cargo_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. RECYCLE mission rejected [%s]', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------------------------------------- 9: NEGATIVE AMOUNT */
    begin
        select * into v_rec from public.load_fleet_cargo(v_f1, -1, 0, 0);
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'Cargo cannot be negative%';
    insert into t_cargo_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. negative amount rejected [%s]', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* -------------------------------------- 10: NO MUTATION AFTER REJECTIONS */
    select coalesce(sum(metal + crystal + deuterium), 0) into v_capacity
      from public.fleet_movements where id in (v_f1, v_f3, v_f4, v_f5, v_f7);
    v_ok := v_capacity = 0
        and (select metal from public.planet_resources where planet_id = v_planet_a) = 100000
        and (select crystal from public.planet_resources where planet_id = v_planet_a) = 100000
        and (select deuterium from public.planet_resources where planet_id = v_planet_a) = 100000;
    insert into t_cargo_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. rejected calls left cargo=%s and the planet untouched', v_capacity));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------- 11: VALID LOAD, MULTIPLE RESOURCES */
    select * into v_rec from public.load_fleet_cargo(v_f1, 1000, 500, 250);
    v_ok := v_rec.metal = 1000 and v_rec.crystal = 500 and v_rec.deuterium = 250
        and v_rec.total_cargo = 1750 and v_rec.cargo_capacity = 25000;
    insert into t_cargo_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11. valid multi-resource load returns %s/%s/%s total=%s capacity=%s',
             v_rec.metal, v_rec.crystal, v_rec.deuterium, v_rec.total_cargo, v_rec.cargo_capacity));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* -------------------------------- 12: EXACT PER-RESOURCE PLANET DEBIT */
    v_metal_planet_after := (select metal from public.planet_resources where planet_id = v_planet_a);
    v_ok := (select metal from public.fleet_movements where id = v_f1) = 1000
        and (select crystal from public.fleet_movements where id = v_f1) = 500
        and (select deuterium from public.fleet_movements where id = v_f1) = 250
        and v_metal_planet_after = 99000
        and (select crystal from public.planet_resources where planet_id = v_planet_a) = 99500
        and (select deuterium from public.planet_resources where planet_id = v_planet_a) = 99750;
    insert into t_cargo_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('12. fleet credited and planet debited exactly (planet metal = %s)', v_metal_planet_after));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* -------------------------------------------- 13: INSUFFICIENT RESOURCES */
    update public.planet_resources set metal = 10 where planet_id = v_planet_a;
    begin
        select * into v_rec from public.load_fleet_cargo(v_f1, 1000, 0, 0);
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'Insufficient metal%';
    insert into t_cargo_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('13. insufficient metal rejected [%s]', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;
    update public.planet_resources set metal = 99000 where planet_id = v_planet_a;

    /* ---------------------------------- 14: ESPIONAGE IS A WHITELISTED MISSION */
    select * into v_rec from public.load_fleet_cargo(v_f6, 2, 1, 0);
    v_ok := v_rec.metal = 2 and v_rec.crystal = 1 and v_rec.cargo_capacity = 25;
    insert into t_cargo_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('14. ESPIONAGE cargo allowed (5 probes x 5 cargo -> capacity = %s)', v_rec.cargo_capacity));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* --------------------------------------------- 15: EXACTLY AT CAPACITY */
    select * into v_rec from public.load_fleet_cargo(v_f2, 8333, 8333, 8334);
    v_ok := v_rec.total_cargo = 25000 and v_rec.cargo_capacity = 25000;
    insert into t_cargo_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('15. load exactly at capacity accepted (total = %s / %s)', v_rec.total_cargo, v_rec.cargo_capacity));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* -------------------------------------------------- 16: CAPACITY OVERFLOW */
    begin
        select * into v_rec from public.load_fleet_cargo(v_f2, 1, 0, 0);
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'Cargo exceeds fleet capacity%';
    insert into t_cargo_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('16. overflow rejected [%s]', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* --------------------------- 17: REPEATED CALLS ARE ADDITIVE, NOT DUPLICATED */
    perform public.load_fleet_cargo(v_f1, 100, 0, 0);
    perform public.load_fleet_cargo(v_f1, 100, 0, 0);
    v_ok := (select metal from public.fleet_movements where id = v_f1) = 1200
        and (select metal from public.planet_resources where planet_id = v_planet_a) = 90465;
    insert into t_cargo_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('17. two extra calls credit exactly 200 (fleet metal = %s, planet metal = %s)',
             (select metal from public.fleet_movements where id = v_f1),
             (select metal from public.planet_resources where planet_id = v_planet_a)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------- 18: CONSERVATION (CARGO + CAPACITY + SHIPS + RESOURCES) */
    v_ok := public.calculate_fleet_cargo_capacity(v_f1) = 25000
        and (select quantity from public.planet_ships where planet_id = v_planet_a and ship_id = 'large_cargo') = 1
        and (select metal + crystal + deuterium from public.planet_resources where planet_id = v_planet_a) = 273047
        and (select sum(metal + crystal + deuterium) from public.fleet_movements
              where id in (v_f1, v_f2, v_f6)) = 26953;
    insert into t_cargo_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('18. conservation: planet total = %s, cargo total = %s, capacity = %s',
             (select metal + crystal + deuterium from public.planet_resources where planet_id = v_planet_a),
             (select sum(metal + crystal + deuterium) from public.fleet_movements where id in (v_f1, v_f2, v_f6)),
             public.calculate_fleet_cargo_capacity(v_f1)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* LIMITATION: no true concurrent load is executed in this single-session harness. */
    insert into t_cargo_results(resultado, prueba)
    values ('INFO', 'concurrency: not executed (single-session harness); FOR UPDATE row locks and the capacity check are asserted on the sequential path');

    if v_fail > 0 then
        raise exception 'FLEET CARGO FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_cargo_results order by orden;

drop table if exists t_cargo_results;

ROLLBACK;
