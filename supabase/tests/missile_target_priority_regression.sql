-- MISSILE TARGET PRIORITY: the `expensive` branch was a silent no-op — 2026-10-01
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- THE DEFECT THIS CERTIFIES
--   `order_defenses_for_missile_attack` ordered by `s.sort_price ASC` unconditionally, so
--   `s.is_expensive DESC` only separated the GROUPS and never inverted the order INSIDE them.
--   Mode 1 (`expensive`) therefore returned byte-identical output to mode 0 (`cheapest`):
--
--       before: light_laser(2000) > heavy_laser(8000) > small_shield_dome(20000)   <- WRONG
--       after : small_shield_dome(20000) > heavy_laser(8000) > light_laser(2000)   <- OGameX
--
--   `start_missile_attack(..., p_target_priority => 1)` validated fine, launched, and
--   silently destroyed the CHEAPEST defense first. OGameX `sortDefensesByPriority()` uses
--   `priceB <=> priceA` (DESC) for that branch.
--
-- LIMITATION: sequential, inside ROLLBACK.

begin;

drop table if exists t_mis_prio;
create temp table t_mis_prio(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid; v_player uuid; v_origin uuid; v_target uuid;
    v_now timestamptz := now();
    v_fleet uuid; v_res record;
    v_ok boolean; v_fail integer := 0;
    v_order text; v_baseline text; v_run text;
begin
    select pl.id, pl.user_id into v_player, v_auth
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;

    select p.id into v_origin
      from public.planets p where p.player_id = v_player and not p.is_destroyed
     order by p.created_at, p.id limit 1;

    -- a REAL enemy body already in the same galaxy and within reach
    select d.id into v_target
      from public.planets h
      join public.planets d on d.galaxy = h.galaxy and abs(d.system - h.system) between 1 and 3
      join public.players pl on pl.id = d.player_id
     where h.id = v_origin and pl.player_type = 'AI' and not d.is_destroyed
     order by abs(d.system - h.system) limit 1;

    if v_player is null or v_origin is null or v_target is null then
        raise exception 'TEST_ABORT: need one auth-linked player and one reachable AI body';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    update public.planet_resources
       set metal = 10000000, crystal = 10000000, deuterium = 10000000,
           last_calculated_at = v_now - interval '10 minutes'
     where planet_id in (v_origin, v_target);

    insert into public.planet_buildings(planet_id, building_id, level) values (v_origin, 'missile_silo', 4)
    on conflict (planet_id, building_id) do update set level = 4;

    insert into public.player_research(player_id, research_id, level) values (v_player, 'impulse_drive', 5)
    on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, excluded.level);

    insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_origin, 'interplanetary_missile', 40)
    on conflict (planet_id, defense_id) do update set quantity = 40;

    -- A REAL spread of prices, plus light_laser and rocket_launcher which share the SAME
    -- metal+crystal price: that absolute tie is what makes D4 observable.
    insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_target, 'light_laser', 50)
    on conflict (planet_id, defense_id) do update set quantity = 50;
    insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_target, 'rocket_launcher', 30)
    on conflict (planet_id, defense_id) do update set quantity = 30;
    insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_target, 'heavy_laser', 30)
    on conflict (planet_id, defense_id) do update set quantity = 30;
    insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_target, 'small_shield_dome', 40)
    on conflict (planet_id, defense_id) do update set quantity = 40;

    -- no ABM: otherwise the salvo would be intercepted before reaching any defense
    delete from public.planet_defenses
     where planet_id = v_target and defense_id = 'anti_ballistic_missile';

    /* ================ ANTI-VACUITY: the fixture is not empty ================ */
    v_ok := (select count(*) = 4 from public.order_defenses_for_missile_attack(v_target, 0) o);
    insert into t_mis_prio(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       'Q1. ANTI-VACUITY: four real target defenses are actually in play');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select count(*) = 1 from public.planet_defenses
              where planet_id = v_origin and defense_id = 'interplanetary_missile' and quantity = 40);
    insert into t_mis_prio(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       'Q2. ANTI-VACUITY: the attacker really holds 40 IPM');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ================ D3: mode 0 (cheapest) is byte-identical ================ */
    select string_agg(o.defense_id, ' > ') into v_baseline
      from public.order_defenses_for_missile_attack(v_target, 0) o;

    v_ok := v_baseline = 'light_laser > rocket_launcher > heavy_laser > small_shield_dome';
    insert into t_mis_prio(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       format('D3. mode 0 (cheapest) is UNCHANGED and cheapest-first [%s]', v_baseline));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ================ THE REGRESSION: mode 1 is genuinely DESC ================ */
    select string_agg(o.defense_id, ' > ') into v_order
      from public.order_defenses_for_missile_attack(v_target, 1) o;

    v_ok := v_order = 'small_shield_dome > heavy_laser > light_laser > rocket_launcher';
    insert into t_mis_prio(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       format('R1. THE REGRESSION: mode 1 (expensive) is now MOST-expensive-first [%s]', v_order));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := v_order <> v_baseline;
    insert into t_mis_prio(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       'R2. mode 1 is no longer identical to mode 0 (it was a silent no-op)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ================ D4: determinism under an ABSOLUTE price tie ================
       light_laser and rocket_launcher both cost 2000 (metal+crystal). The tie must always
       resolve the same way, never by physical row order. Five consecutive reads must
       return the identical sequence. */
    v_ok := true;
    for i in 1..5 loop
      select string_agg(o.defense_id, ' > ') into v_run
        from public.order_defenses_for_missile_attack(v_target, 0) o;
      v_ok := v_ok and v_run = v_baseline;
    end loop;

    insert into t_mis_prio(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       format('D4. the absolute price tie resolves identically across 5 reads [%s]', v_baseline));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ================ EXPLICIT-TYPE MODES STILL PUT THE CHOSEN TYPE FIRST ============ */
    select string_agg(o.defense_id, ' > ') into v_order
      from public.order_defenses_for_missile_attack(v_target, 2) o;
    v_ok := v_order like 'rocket_launcher > %';
    insert into t_mis_prio(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       format('R3. mode 2 puts rocket_launcher first [%s]', v_order));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select string_agg(o.defense_id, ' > ') into v_order
      from public.order_defenses_for_missile_attack(v_target, 8) o;
    v_ok := v_order like 'small_shield_dome > %';
    insert into t_mis_prio(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       format('R4. mode 8 puts small_shield_dome first [%s]', v_order));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ================ MISSILES ARE NEVER TARGETS ================ */
    v_ok := not exists (select 1 from public.order_defenses_for_missile_attack(v_target, 0) o
                         where o.defense_id in ('anti_ballistic_missile','interplanetary_missile'));
    insert into t_mis_prio(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       'G1. ABM and IPM are never valid targets');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- Heavy dome: 500 x armour 200 = 100000 power, while 1 IPM carries 12000 (60 kills).
    -- The stock therefore CANNOT be wiped, so the missile spends its whole power on the FIRST
    -- target and the ORDER becomes observable in the resulting quantities. The cheap laser
    -- (armour 20) is the mirror probe: if the order is honoured it is never touched.
    insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_target, 'small_shield_dome', 500)
    on conflict (planet_id, defense_id) do update set quantity = 500;

    /* ================ THE PRIORITY REACHES REAL DESTRUCTION ================
       Not just the ordering helper: a real attack must spend its power on the FIRST target.
       1 IPM destroys 60 domes (500 -> 440) and nothing else, in either mode. */
    v_fleet := public.start_missile_attack(v_player, v_origin, v_target, 1, 1);
    select * into v_res from public.resolve_missile_attack_arrival(v_fleet);

    v_ok := (select pd.quantity = 440 from public.planet_defenses pd
              where pd.planet_id = v_target and pd.defense_id = 'small_shield_dome');
    insert into t_mis_prio(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       'J1. an `expensive` attack spends its power on the MOST EXPENSIVE defense (500 -> 440)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select pd.quantity = 50 from public.planet_defenses pd
              where pd.planet_id = v_target and pd.defense_id = 'light_laser');
    insert into t_mis_prio(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       'J2. the cheap laser is NOT touched by the `expensive` attack');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ================ AND THE MIRROR: cheapest really hits the cheapest ============ */
    insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_target, 'small_shield_dome', 500)
    on conflict (planet_id, defense_id) do update set quantity = 500;

    v_fleet := public.start_missile_attack(v_player, v_origin, v_target, 1, 0);
    select * into v_res from public.resolve_missile_attack_arrival(v_fleet);

    v_ok := (select pd.quantity = 0 from public.planet_defenses pd
              where pd.planet_id = v_target and pd.defense_id = 'light_laser');
    insert into t_mis_prio(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       'J3. a `cheapest` attack wipes the cheap laser first (50 -> 0)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- 1 IPM = 12000 power. Cheapest order: light_laser(a20) 50, rocket_launcher(a20) 30,
    -- heavy_laser(a80) 30, then the dome (a200). The missile therefore clears the three cheap
    -- types (1000 + 600 + 2400 = 4000) and reaches the dome with 8000 -> floor(8000/200)=40,
    -- leaving 500 - 40 = 460. The CASCADE through the cheap types is the CERTIFIED destruction
    -- loop, not a defect; what matters is that it walked cheapest-first.
    v_ok := (select pd.quantity = 460 from public.planet_defenses pd
              where pd.planet_id = v_target and pd.defense_id = 'small_shield_dome');
    insert into t_mis_prio(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       'J4. `cheapest` cleared all cheap types FIRST; the dome only took the cascade (500 -> 460)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ================ ACL: the ordering helper stays server-side ================ */
    v_ok := not has_function_privilege('authenticated', 'public.order_defenses_for_missile_attack(uuid,integer)', 'EXECUTE')
       and not has_function_privilege('anon', 'public.order_defenses_for_missile_attack(uuid,integer)', 'EXECUTE');
    insert into t_mis_prio(resultado, prueba) values
      (case when v_ok then 'PASS' else 'FAIL' end,
       'SEC. the ordering helper remains closed to the client');
    v_fail := v_fail + case when v_ok then 0 else 1 end;
end $test$;

select resultado, prueba from t_mis_prio order by orden;

do $summary$
declare v_fail integer; v_total integer;
begin
    select count(*) filter (where resultado = 'FAIL'), count(*)
      into v_fail, v_total from t_mis_prio;
    raise notice 'RESULT: % / % PASS', v_total - v_fail, v_total;
    if v_fail > 0 then
        raise exception 'FIXTURE FAILED: % of % assertions failed', v_fail, v_total;
    end if;
end $summary$;

rollback;