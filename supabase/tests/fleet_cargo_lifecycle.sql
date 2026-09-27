-- FLEET CARGO LIFECYCLE FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract under test (migration 20260925171816_complete_fleet_cargo_lifecycle_...):
--   DEPLOY     resolve_deploy_arrival    delivers the carried cargo to the destination planet and
--                                       completes the fleet with unloaded (zeroed) cargo.
--   COLONIZE   resolve_colonize_arrival  seeds the new colony with the carried cargo.
--   EXPEDITION resolve_expedition_arrival (outcome RESOURCES) ADDS the find to the carried cargo;
--                                       the expedition_results row keeps recording ONLY the find.
--   load_fleet_cargo admits DEPLOY / COLONIZE / EXPEDITION in its mission whitelist.
--
-- Technique for a deterministic RESOURCES expedition: the outcome stream is deterministic per fleet id
-- (`expedition_event_random(fleet_id,'outcome')` × Σ weights → `select_expedition_outcome`). The fixture
-- inserts a candidate fleet and evaluates that chain, discarding non-RESOURCES ids, until one resolves
-- to RESOURCES. No game setting is modified to force it.
--
-- LIMITATION: single-session harness. True concurrency is not executed; idempotency is exercised
-- sequentially (replays) instead, and the row locks (FOR UPDATE) are asserted by the deployed bodies.

begin;

/* FLEET SLOTS PREREQUISITE (2026-09-26): the engine now enforces 1 + computer_technology simultaneous fleets
   on every fleet_movements insert (trigger trg_enforce_fleet_slots). This fixture needs several live
   movements at once, so it grants a high computer_technology level to every player before exercising its
   contract. See supabase/tests/fleet_slots_enforcement.sql for the enforcement fixture. */
insert into public.player_research(player_id, research_id, level)
select pl.id, 'computer_technology', 60
from public.players pl
on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, excluded.level);


drop table if exists t_cargo_lifecycle_results;
create temp table t_cargo_lifecycle_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth_a uuid; v_player_a uuid; v_planet_a uuid; v_universe uuid;
    v_player_b uuid; v_planet_b uuid;
    v_dep uuid; v_dep0 uuid; v_dep2 uuid; v_col uuid; v_col0 uuid; v_exp uuid; v_exp0 uuid;
    v_gal integer; v_sys integer; v_gal2 integer; v_sys2 integer;
    v_total numeric; v_outcome text; v_tries integer := 0;
    v_new1 uuid; v_new2 uuid;
    v_bm numeric; v_bc numeric; v_bd numeric; v_bships bigint;
    v_am numeric; v_ac numeric; v_ad numeric;
    v_r1 numeric; v_r2 numeric; v_r3 numeric;
    v_rec record; v_status text; v_cargo numeric;
    v_ok boolean; v_fail integer := 0; v_msg text;
begin
    /* ------------------------------------------------------------------ FIXTURE */
    select pl.id, pl.user_id into v_player_a, v_auth_a
      from public.players pl where pl.user_id is not null order by pl.created_at limit 1;
    select p.id, p.universe_id into v_planet_a, v_universe
      from public.planets p where p.player_id = v_player_a and not p.is_destroyed
      order by p.created_at, p.id limit 1;
    select p.player_id, p.id into v_player_b, v_planet_b
      from public.planets p join public.players pl on pl.id = p.player_id
     where not p.is_destroyed and pl.player_type = 'AI' and p.player_id <> v_player_a
     order by p.created_at, p.id limit 1;

    if v_player_a is null or v_player_b is null or v_planet_a is null or v_planet_b is null then
        raise exception 'TEST_ABORT: one auth-linked player with a planet and one AI player with a planet are required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_a)::text, true);

    /* an empty coordinate pair for the two colonisation cases (positions 7 and 8) */
    select ug.galaxy, s.system into v_gal, v_sys
      from public.universe_galaxies ug
      cross join lateral generate_series(1, ug.system_count) s(system)
     where ug.universe_id = v_universe
       and not exists (select 1 from public.planets p
                        where p.universe_id = ug.universe_id and p.galaxy = ug.galaxy
                          and p.system = s.system and p.position = 7)
     order by ug.galaxy, s.system limit 1;

    select ug.galaxy, s.system into v_gal2, v_sys2
      from public.universe_galaxies ug
      cross join lateral generate_series(1, ug.system_count) s(system)
     where ug.universe_id = v_universe
       and not exists (select 1 from public.planets p
                        where p.universe_id = ug.universe_id and p.galaxy = ug.galaxy
                          and p.system = s.system and p.position = 8)
     order by ug.galaxy, s.system limit 1;

    if v_gal is null or v_gal2 is null then
        raise exception 'TEST_ABORT: the universe needs two free coordinates';
    end if;

    /* -------------------------------------------------------- DEPLOY fixtures */
    insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status,metal,crystal,deuterium)
    values (v_player_a,v_planet_a,v_planet_b,'DEPLOY',now()-interval '1 hour',now(),'ARRIVED',1000,500,250)
    returning id into v_dep;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_dep, 'large_cargo', 2);

    insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status,metal,crystal,deuterium)
    values (v_player_a,v_planet_a,v_planet_b,'DEPLOY',now()-interval '1 hour',now(),'ARRIVED',0,0,0)
    returning id into v_dep0;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_dep0, 'small_cargo', 1);

    /* ------------------------------------------------------ COLONIZE fixtures */
    insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status,metal,crystal,deuterium,destination_galaxy,destination_system,destination_position)
    values (v_player_a,v_planet_a,NULL,'COLONIZE',now()-interval '1 hour',now(),'ARRIVED',2000,1000,500,v_gal,v_sys,7)
    returning id into v_col;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity)
    values (v_col, 'colony_ship', 1), (v_col, 'large_cargo', 1);

    insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status,metal,crystal,deuterium,destination_galaxy,destination_system,destination_position)
    values (v_player_a,v_planet_a,NULL,'COLONIZE',now()-interval '1 hour',now(),'ARRIVED',0,0,0,v_gal2,v_sys2,8)
    returning id into v_col0;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_col0, 'colony_ship', 1);

    /* ----------------------------------------------------- DEPLOY assertions */
    perform public.update_planet_resources_until(v_planet_b, (select arrives_at from public.fleet_movements where id = v_dep));
    select metal, crystal, deuterium into v_bm, v_bc, v_bd from public.planet_resources where planet_id = v_planet_b;
    select coalesce(quantity,0) into v_bships from public.planet_ships where planet_id = v_planet_b and ship_id = 'large_cargo';
    v_bships := coalesce(v_bships,0);

    select * into v_rec from public.resolve_deploy_arrival(v_dep);

    select metal, crystal, deuterium into v_am, v_ac, v_ad from public.planet_resources where planet_id = v_planet_b;
    select status, metal + crystal + deuterium into v_status, v_cargo from public.fleet_movements where id = v_dep;

    v_ok := v_am = v_bm + 1000 and v_ac = v_bc + 500 and v_ad = v_bd + 250;
    insert into t_cargo_lifecycle_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('DEPLOY-1 delivered cargo exactly: metal %s->%s (+1000), crystal %s->%s (+500), deuterium %s->%s (+250)',
             v_bm, v_am, v_bc, v_ac, v_bd, v_ad));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select coalesce(quantity,0) from public.planet_ships where planet_id = v_planet_b and ship_id = 'large_cargo') = v_bships + 2
        and v_rec.transferred_ships = 2;
    insert into t_cargo_lifecycle_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('DEPLOY-2 ships transferred (%s -> %s) and reported = %s', v_bships,
             (select coalesce(quantity,0) from public.planet_ships where planet_id = v_planet_b and ship_id = 'large_cargo'),
             v_rec.transferred_ships));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := v_status = 'COMPLETED' and v_cargo = 0;
    insert into t_cargo_lifecycle_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('DEPLOY-3 fleet %s with no pending cargo (total = %s)', v_status, v_cargo));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    begin
        select * into v_rec from public.resolve_deploy_arrival(v_dep);
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    select metal, crystal, deuterium into v_am, v_ac, v_ad from public.planet_resources where planet_id = v_planet_b;
    v_ok := v_msg like 'Deploy must be ARRIVED%'
        and v_am = v_bm + 1000 and v_ac = v_bc + 500 and v_ad = v_bd + 250;
    insert into t_cargo_lifecycle_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('DEPLOY-4 replay rejected [%s] and no double credit (metal still %s)', v_msg, v_am));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select * into v_rec from public.resolve_deploy_arrival(v_dep0);
    select metal, crystal, deuterium into v_am, v_ac, v_ad from public.planet_resources where planet_id = v_planet_b;
    v_ok := v_am = v_bm + 1000 and v_ac = v_bc + 500 and v_ad = v_bd + 250
        and (select status from public.fleet_movements where id = v_dep0) = 'COMPLETED';
    insert into t_cargo_lifecycle_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('DEPLOY-5 zero-cargo deploy completes without touching the destination (metal %s, ships-only fleet)', v_am));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* --------------------------------------------------- COLONIZE assertions */
    select * into v_rec from public.resolve_colonize_arrival(v_col);
    v_new1 := v_rec.new_planet_id;

    v_ok := v_new1 is not null
        and (select count(*) from public.planets
              where id = v_new1 and galaxy = v_gal and system = v_sys and position = 7
                and player_id = v_player_a and is_homeworld = false and is_destroyed = false) = 1;
    insert into t_cargo_lifecycle_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('COLONIZE-1 planet created at [%s:%s:7] owned by the coloniser (%s)', v_gal, v_sys, v_new1));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select metal = 2000 and crystal = 1000 and deuterium = 500
               from public.planet_resources where planet_id = v_new1);
    insert into t_cargo_lifecycle_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('COLONIZE-2 colony seeded with the exact carried cargo (metal %s, crystal %s, deuterium %s)',
             (select metal from public.planet_resources where planet_id = v_new1),
             (select crystal from public.planet_resources where planet_id = v_new1),
             (select deuterium from public.planet_resources where planet_id = v_new1)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select count(*) from public.fleet_movement_ships where fleet_id = v_col and ship_id = 'colony_ship') = 0
        and (select quantity from public.fleet_movement_ships where fleet_id = v_col and ship_id = 'large_cargo') = 1;
    insert into t_cargo_lifecycle_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'COLONIZE-3 colony ship consumed, the rest of the fleet untouched');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select status = 'COMPLETED' and destination_planet_id = v_new1 and metal + crystal + deuterium = 0
               from public.fleet_movements where id = v_col);
    insert into t_cargo_lifecycle_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'COLONIZE-4 fleet completed, destination recorded and cargo unloaded (not pending)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    begin
        select * into v_rec from public.resolve_colonize_arrival(v_col);
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'Colonize must be ARRIVED%'
        and (select metal = 2000 and crystal = 1000 and deuterium = 500
               from public.planet_resources where planet_id = v_new1);
    insert into t_cargo_lifecycle_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('COLONIZE-5 replay rejected [%s] and no double seed', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select * into v_rec from public.resolve_colonize_arrival(v_col0);
    v_new2 := v_rec.new_planet_id;
    v_ok := v_new2 is not null
        and (select metal = 0 and crystal = 0 and deuterium = 0
               from public.planet_resources where planet_id = v_new2)
        and (select status = 'COMPLETED' from public.fleet_movements where id = v_col0);
    insert into t_cargo_lifecycle_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('COLONIZE-6 zero-cargo colonisation creates a normal empty colony (%s)', v_new2));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------ EXPEDITION / RESOURCES */
    -- Deterministic search for a fleet id whose outcome stream resolves to RESOURCES: the fixture
    -- inserts a candidate fleet, evaluates the SAME chain the resolver uses and keeps it only if it is
    -- RESOURCES (no game setting is modified to force the outcome).
    /* -------------------------- EXPEDITION settings (fixture need, rolled back) */
    -- The auth-linked player's universe has NO expedition_settings row in LIVE, so the resolver would
    -- raise 'Invalid expedition weights'. A copy of the configured weights is created ONLY inside this
    -- transaction; the missing row is reported as an OPEN finding (which weights a universe should use
    -- is a configuration decision, not part of this mission).
    v_ok := exists (select 1 from public.expedition_settings where universe_id = v_universe);
    insert into t_cargo_lifecycle_results(resultado, prueba) values ('INFO',
      format('DATA (pre-existing, out of scope): expedition_settings exists for the fixture universe %s = %s', v_universe, v_ok));

    if not v_ok then
        insert into public.expedition_settings(universe_id, bonus_expedition_slots,
            reward_multiplier_resources, reward_multiplier_ships, reward_multiplier_dark_matter, reward_multiplier_items,
            weight_ships, weight_resources, weight_delay, weight_speedup, weight_nothing, weight_black_hole,
            weight_pirates, weight_aliens, weight_dark_matter, weight_merchant, weight_items)
        select v_universe, es.bonus_expedition_slots,
               es.reward_multiplier_resources, es.reward_multiplier_ships, es.reward_multiplier_dark_matter, es.reward_multiplier_items,
               es.weight_ships, es.weight_resources, es.weight_delay, es.weight_speedup, es.weight_nothing, es.weight_black_hole,
               es.weight_pirates, es.weight_aliens, es.weight_dark_matter, es.weight_merchant, es.weight_items
          from public.expedition_settings es
         where es.universe_id <> v_universe
         order by es.universe_id
         limit 1;
    end if;

    loop
        v_tries := v_tries + 1;
        insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status,metal,crystal,deuterium)
        values (v_player_a,v_planet_a,NULL,'EXPEDITION',now()-interval '2 hours',now(),'ARRIVED',1000,500,0)
        returning id into v_exp;
        insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_exp, 'large_cargo', 1);

        select (es.weight_ships+es.weight_resources+es.weight_delay+es.weight_speedup+es.weight_nothing
                +es.weight_black_hole+es.weight_pirates+es.weight_aliens+es.weight_dark_matter
                +es.weight_merchant+es.weight_items)
          into v_total
          from public.expedition_settings es where es.universe_id = v_universe;

        if v_total is null or v_total <= 0 then
            raise exception 'TEST_ABORT: expedition_settings missing for universe %', v_universe;
        end if;

        v_outcome := public.select_expedition_outcome(v_universe, public.expedition_event_random(v_exp,'outcome')*v_total);
        exit when v_outcome = 'RESOURCES' or v_tries >= 60;

        delete from public.fleet_movement_ships where fleet_id = v_exp;
        delete from public.fleet_movements where id = v_exp;
    end loop;

    v_ok := v_outcome = 'RESOURCES';
    insert into t_cargo_lifecycle_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('EXPEDITION-1 deterministic RESOURCES fleet found after %s candidate(s) [outcome=%s]', v_tries, v_outcome));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    if v_outcome <> 'RESOURCES' then
        raise exception 'TEST_ABORT: no RESOURCES expedition id found in % candidate(s)', v_tries;
    end if;

    v_outcome := public.resolve_expedition_arrival(v_exp);
    select metal, crystal, deuterium into v_am, v_ac, v_ad from public.fleet_movements where id = v_exp;
    select metal, crystal, deuterium into v_r1, v_r2, v_r3 from public.expedition_results where fleet_id = v_exp;
    select status into v_status from public.fleet_movements where id = v_exp;

    v_ok := v_am = 1000 + v_r1 and v_ac = 500 + v_r2 and v_ad = 0 + v_r3;
    insert into t_cargo_lifecycle_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('EXPEDITION-2 carried cargo preserved and find ADDED: 1000/500/0 + %s/%s/%s = %s/%s/%s',
             v_r1, v_r2, v_r3, v_am, v_ac, v_ad));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := v_status = 'RETURNING' and (v_r1 + v_r2 + v_r3) >= 0 and v_outcome = 'RESOURCES';
    insert into t_cargo_lifecycle_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('EXPEDITION-3 report records only the find and the fleet returns [%s, status=%s]', v_outcome, v_status));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    begin
        v_outcome := public.resolve_expedition_arrival(v_exp);
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg like 'Expedition % must be ARRIVED%'
        and (select metal = 1000 + v_r1 and crystal = 500 + v_r2 and deuterium = 0 + v_r3
               from public.fleet_movements where id = v_exp);
    insert into t_cargo_lifecycle_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('EXPEDITION-4 replay rejected [%s] and the find was not added twice', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* -------------------------- EXPEDITION with zero cargo (find still lands) */
    v_tries := 0;
    loop
        v_tries := v_tries + 1;
        insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status,metal,crystal,deuterium)
        values (v_player_a,v_planet_a,NULL,'EXPEDITION',now()-interval '2 hours',now(),'ARRIVED',0,0,0)
        returning id into v_exp0;
        insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_exp0, 'large_cargo', 1);

        v_outcome := public.select_expedition_outcome(v_universe, public.expedition_event_random(v_exp0,'outcome')*v_total);
        exit when v_outcome = 'RESOURCES' or v_tries >= 60;

        delete from public.fleet_movement_ships where fleet_id = v_exp0;
        delete from public.fleet_movements where id = v_exp0;
    end loop;

    if v_outcome <> 'RESOURCES' then
        raise exception 'TEST_ABORT: no zero-cargo RESOURCES expedition id found in % candidate(s)', v_tries;
    end if;

    v_outcome := public.resolve_expedition_arrival(v_exp0);
    v_ok := (select metal = (select metal from public.expedition_results where fleet_id = v_exp0)
                and crystal = (select crystal from public.expedition_results where fleet_id = v_exp0)
                and deuterium = (select deuterium from public.expedition_results where fleet_id = v_exp0)
               from public.fleet_movements where id = v_exp0);
    insert into t_cargo_lifecycle_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'EXPEDITION-5 zero-cargo expedition receives exactly the find (previous behaviour preserved)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------ WHITELIST: the three missions can now carry loaded cargo */
    update public.planet_resources set metal = greatest(metal, 10000) where planet_id = v_planet_a;

    insert into public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status)
    values (v_player_a,v_planet_a,v_planet_b,'DEPLOY',now(),now()+interval '1 hour','OUTBOUND')
    returning id into v_dep2;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_dep2, 'large_cargo', 1);

    begin
        perform public.load_fleet_cargo(v_dep2, 100, 0, 0);
        v_msg := 'NO_ERROR';
    exception when others then v_msg := sqlerrm;
    end;
    v_ok := v_msg = 'NO_ERROR'
        and (select metal from public.fleet_movements where id = v_dep2) = 100;
    insert into t_cargo_lifecycle_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('WHITELIST-1 DEPLOY is loadable by its owner [%s] and the fleet carries 100 metal after the call', v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select prosrc like '%''TRANSPORT'',''ESPIONAGE'',''ACS_HOLD'',''DEPLOY'',''COLONIZE'',''EXPEDITION''%'
               from pg_proc where pronamespace='public'::regnamespace and proname = 'load_fleet_cargo');
    insert into t_cargo_lifecycle_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'WHITELIST-2 the deployed load_fleet_cargo admits exactly TRANSPORT/ESPIONAGE/ACS_HOLD/DEPLOY/COLONIZE/EXPEDITION');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_cargo_lifecycle_results(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; true concurrency is not executed (replays cover idempotency) and the row locks are asserted by the deployed bodies');

    if v_fail > 0 then
        raise exception 'FLEET CARGO LIFECYCLE FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_cargo_lifecycle_results order by orden;

drop table if exists t_cargo_lifecycle_results;

ROLLBACK;
