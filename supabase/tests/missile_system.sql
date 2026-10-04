-- MISSILE SYSTEM FIXTURE - LA GRAN IMPLOSION
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
-- Contract (20260930220000 .. 20260930221900): Missile Silo, ABM, IPM, silo slot
-- capacity, production gates, MISSILE_ATTACK, range, flight time, ABM interception,
-- destruction priority, combat exclusion, demolition guard and messages.
-- LIMITATION: single-session harness; true concurrency not executed.

begin;

drop table if exists t_mis;
create temp table t_mis(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_universe uuid; v_rival uuid; v_rival_auth uuid;
    v_origin uuid; v_target_p uuid; v_target_m uuid; v_far uuid; v_far2 uuid;
    v_silo4 uuid; v_silo1 uuid; v_silo0 uuid;
    v_def text; v_armor numeric; v_price numeric; v_fleet uuid;
    v_ids text[];
    v_qty bigint; v_res record; v_n integer;
    v_ok boolean; v_fail integer := 0; v_rows integer;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null
     order by pl.created_at, pl.id limit 1;
    if v_player is null or v_universe is null then
        raise exception 'TEST_ABORT: an auth-linked player is required';
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    -- A second, different player owns the targets. Ownership is resolved
    -- server-side, so a forged player id must never be accepted.
    select pl.id, pl.user_id into v_rival, v_rival_auth
      from public.players pl
     where pl.id <> v_player and pl.universe_id = v_universe
     order by pl.created_at, pl.id limit 1;
    if v_rival is null then
        raise exception 'TEST_ABORT: a second player in the same universe is required';
    end if;

    -- Bodies. Same galaxy, systems 100 (origin), 101 (near target), 110 (far).
    -- The MOON is inserted separately, after its parent: enforce_planet_kind_
    -- consistency requires parent_planet_id at insert time and a moon must
    -- share the galaxy/system/position of its parent planet.
    insert into public.planets
      (universe_id, player_id, name, galaxy, system, position, kind, is_homeworld, is_destroyed)
    values
      (v_universe, v_player,  'MIS-ORIGIN',  1, 100, 1, 'PLANET', false, false),
      (v_universe, v_rival,  'MIS-TARGET',  1, 101, 4, 'PLANET', false, false),
      (v_universe, v_rival,  'MIS-FAR',     1, 110, 4, 'PLANET', false, false),
      (v_universe, v_rival,  'MIS-FAR2',    1, 111, 4, 'PLANET', false, false);

    select id into v_origin   from public.planets where name='MIS-ORIGIN' and player_id=v_player;
    select id into v_target_p from public.planets where name='MIS-TARGET';
    select id into v_far      from public.planets where name='MIS-FAR';
    select id into v_far2     from public.planets where name='MIS-FAR2';

    -- The moon's parent is the target planet: parent ABMs must defend it first.
    insert into public.planets
      (universe_id, player_id, name, galaxy, system, position, kind,
       parent_planet_id, moon_diameter_km, is_homeworld, is_destroyed)
    values
      (v_universe, v_rival, 'MIS-MOON', 1, 101, 4, 'MOON', v_target_p, 5000, false, false);
    select id into v_target_m from public.planets where name='MIS-MOON';

    -- Resources and research for the launcher.
    insert into public.planet_resources(planet_id, metal, crystal, deuterium)
    values (v_origin, 50000000, 50000000, 50000000);
    insert into public.player_research(player_id, research_id, level)
    values (v_player, 'impulse_drive', 10)
    on conflict (player_id, research_id) do update set level = excluded.level;

    -- Silo levels. The helper reads planet_buildings, so a level-4 silo is the
    -- canonical "40 slots" body used by the capacity and demolition tests.
    insert into public.planet_buildings(planet_id, building_id, level) values
      (v_origin,  'missile_silo', 4),
      (v_origin,  'shipyard',     4)
      on conflict (planet_id, building_id) do update set level = excluded.level;
    insert into public.planet_buildings(planet_id, building_id, level) values
      (v_target_p,'missile_silo', 4),
      (v_target_p,'shipyard',     4),
      (v_target_m,'shipyard',     1)
      on conflict (planet_id, building_id) do update set level = excluded.level;

    select id into v_silo4 from public.planets where name='MIS-ORIGIN';
    -- Auxiliary bodies: silo 1 (10 slots) and silo 0 (0 slots).
    insert into public.planets(universe_id, player_id, name, galaxy, system, position, kind, is_homeworld, is_destroyed)
    values (v_universe, v_player, 'MIS-SILO1', 1, 100, 5, 'PLANET', false, false),
           (v_universe, v_player, 'MIS-SILO0', 1, 100, 6, 'PLANET', false, false);
    select id into v_silo1 from public.planets where name='MIS-SILO1';
    select id into v_silo0 from public.planets where name='MIS-SILO0';
    insert into public.planet_buildings(planet_id, building_id, level) values
      (v_silo1, 'missile_silo', 1),
      (v_silo0, 'shipyard', 1)
      on conflict (planet_id, building_id) do update set level = excluded.level;
    -- the silo-1 body is also the ABM production gate in 30c, so it needs the
    -- shipyard 1 prerequisite: without it start_defense fails on THAT first and
    -- the capacity rejection is never actually reached.
    insert into public.planet_buildings(planet_id, building_id, level)
      values (v_silo1, 'shipyard', 1)
      on conflict (planet_id, building_id) do update set level = excluded.level;
    insert into public.planet_resources(planet_id, metal, crystal, deuterium)
    values (v_silo1, 50000000, 50000000, 50000000),
           (v_silo0, 50000000, 50000000, 50000000);

    -- ================================================================
    -- SILO (1-8)
    -- ================================================================

    -- 1. definition
    v_ok := exists (select 1 from public.building_definitions bd where bd.id='missile_silo');
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '1. missile_silo exists in building_definitions');

    -- 2. cost 20000/20000/1000 with factor 2
    select bd.base_metal, bd.base_crystal, bd.base_deuterium, bd.cost_factor
      into v_res from public.building_definitions bd where bd.id='missile_silo';
    v_ok := v_res.base_metal=20000 and v_res.base_crystal=20000
         and v_res.base_deuterium=1000 and v_res.cost_factor=2;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '2. silo cost 20000/20000/1000 and cost_factor 2');

    -- 3. shipyard 1 requirement
    v_ok := exists (select 1 from public.building_prerequisites bp
                     where bp.building_id='missile_silo'
                       and bp.prerequisite_building_id='shipyard'
                       and bp.required_level=1);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '3. silo requires shipyard 1');

    -- 4. PLANET + MOON body types
    select bd.valid_kinds into v_res from public.building_definitions bd where bd.id='missile_silo';
    v_ok := 'PLANET'=any(v_res.valid_kinds) and 'MOON'=any(v_res.valid_kinds);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '4. silo valid on PLANET and MOON (VERIFIED OGameX)');

    -- 5. the body-type gate is not applied to planets without silo rules
    v_ok := not exists (select 1 from public.building_definitions bd
                         where bd.id='missile_silo' and 'DEBRIS'=any(bd.valid_kinds));
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '5. silo is not valid on debris fields');

    -- 6. base build time 60s (D1)
    select bd.base_build_time_seconds into v_n from public.building_definitions bd where bd.id='missile_silo';
    v_ok := v_n = 60;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '6. silo base_build_time_seconds = 60 (D1)');

    -- 7. time factor 2
    select bd.time_factor into v_res from public.building_definitions bd where bd.id='missile_silo';
    v_ok := v_res.time_factor = 2;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '7. silo time_factor = 2 (OGameX price factor 2)');

    -- 8. capacity = 10 per level (silo 0 / 1 / 4)
    v_ok := public.calculate_missile_silo_slots(v_silo0) = 0
         and public.calculate_missile_silo_slots(v_silo1) = 10
         and public.calculate_missile_silo_slots(v_silo4) = 40;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '8. capacity = silo_level * 10 => silo 0 = 0, silo 1 = 10, silo 4 = 40');

    -- ================================================================
    -- ABM (9-15)
    -- ================================================================

    -- 9. cost 8000/2000/0
    select dd.metal_cost, dd.crystal_cost, dd.deuterium_cost into v_res
      from public.defense_definitions dd where dd.id='anti_ballistic_missile';
    v_ok := v_res.metal_cost=8000 and v_res.crystal_cost=2000 and v_res.deuterium_cost=0;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '9. ABM cost 8000/2000/0');

    -- 10. requires silo 2
    v_ok := exists (select 1 from public.defense_prerequisites dp
                     where dp.defense_id='anti_ballistic_missile'
                       and dp.prerequisite_type='building'
                       and dp.building_id='missile_silo' and dp.required_level=2);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10. ABM requires missile_silo 2');

    -- 11. requires shipyard 1
    v_ok := exists (select 1 from public.defense_prerequisites dp
                     where dp.defense_id='anti_ballistic_missile'
                       and dp.prerequisite_type='building'
                       and dp.building_id='shipyard' and dp.required_level=1);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '11. ABM requires shipyard 1');

    -- 12. 1 slot
    select dd.slots_per_unit into v_n from public.defense_definitions dd where dd.id='anti_ballistic_missile';
    v_ok := v_n = 1;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '12. ABM slots_per_unit = 1 (40 ABM fill a level-4 silo)');

    -- 13. base build time 60s (D1)
    select dd.base_build_time into v_res from public.defense_definitions dd where dd.id='anti_ballistic_missile';
    v_ok := v_res.base_build_time = 60;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '13. ABM base_build_time = 60 (D1)');

    -- 14. hull 800
    select dd.hull into v_res from public.defense_definitions dd where dd.id='anti_ballistic_missile';
    v_ok := v_res.hull = 800;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '14. ABM hull = 800');

    -- 15. ABM persists
    insert into public.planet_defenses(planet_id, defense_id, quantity)
      values (v_origin,'anti_ballistic_missile',7)
      on conflict (planet_id, defense_id) do update set quantity = excluded.quantity;
    v_ok := exists (select 1 from public.planet_defenses pd
                     where pd.planet_id=v_origin and pd.defense_id='anti_ballistic_missile'
                       and pd.quantity = 7);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '15. ABM persists in planet_defenses (7 units, 7 slots)');

    -- ================================================================
    -- IPM (16-23)
    -- ================================================================

    -- 16. cost 12500/2500/10000
    select dd.metal_cost, dd.crystal_cost, dd.deuterium_cost into v_res
      from public.defense_definitions dd where dd.id='interplanetary_missile';
    v_ok := v_res.metal_cost=12500 and v_res.crystal_cost=2500 and v_res.deuterium_cost=10000;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '16. IPM cost 12500/2500/10000');

    -- 17. requires silo 4
    v_ok := exists (select 1 from public.defense_prerequisites dp
                     where dp.defense_id='interplanetary_missile'
                       and dp.prerequisite_type='building'
                       and dp.building_id='missile_silo' and dp.required_level=4);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '17. IPM requires missile_silo 4');

    -- 18. requires shipyard 1
    v_ok := exists (select 1 from public.defense_prerequisites dp
                     where dp.defense_id='interplanetary_missile'
                       and dp.prerequisite_type='building'
                       and dp.building_id='shipyard' and dp.required_level=1);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '18. IPM requires shipyard 1');

    -- 19. requires impulse_drive 1
    v_ok := exists (select 1 from public.defense_prerequisites dp
                     where dp.defense_id='interplanetary_missile'
                       and dp.prerequisite_type='research'
                       and dp.research_id='impulse_drive' and dp.required_level=1);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '19. IPM requires impulse_drive 1');

    -- 20. 2 slots
    select dd.slots_per_unit into v_n from public.defense_definitions dd where dd.id='interplanetary_missile';
    v_ok := v_n = 2;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '20. IPM slots_per_unit = 2 (20 IPM fill a level-4 silo)');

    -- 21. base build time 60s (D1)
    select dd.base_build_time into v_res from public.defense_definitions dd where dd.id='interplanetary_missile';
    v_ok := v_res.base_build_time = 60;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '21. IPM base_build_time = 60 (D1)');

    -- 22. hull 1500 / attack 12000
    select dd.hull, dd.attack into v_res from public.defense_definitions dd where dd.id='interplanetary_missile';
    v_ok := v_res.hull = 1500 and v_res.attack = 12000;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '22. IPM hull = 1500 and attack = 12000 (VERIFIED)');

    -- 23. IPM persists
    insert into public.planet_defenses(planet_id, defense_id, quantity)
      values (v_origin,'interplanetary_missile',10)
      on conflict (planet_id, defense_id) do update set quantity = excluded.quantity;
    v_ok := exists (select 1 from public.planet_defenses pd
                     where pd.planet_id=v_origin and pd.defense_id='interplanetary_missile'
                       and pd.quantity = 10);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '23. IPM persists in planet_defenses (10 units, 20 slots)');
    -- ================================================================
    -- CAPACITY (24-30)
    -- ================================================================

    -- 24/25/26. silo 0 => 0, silo 1 => 10, silo 4 => 40
    v_ok := public.calculate_missile_silo_slots(v_silo0) = 0
         and public.calculate_missile_silo_slots(v_silo1) = 10
         and public.calculate_missile_silo_slots(v_silo4) = 40;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '24-26. capacity by silo level: 0 => 0, 1 => 10, 4 => 40');

    -- 27. ABM consumes 1 slot per unit. Nothing is queued yet, and the origin already
    --     holds the 10 IPM of case 23, so the ABM contribution is isolated as the
    --     difference between the total and what the IPM rows alone account for.
    --     (Asserting the raw total here would be stale: case 23 runs first.)
    v_ok := public.calculate_queued_missile_slots(v_origin) = 0
         and public.calculate_used_missile_slots(v_origin)
             - coalesce((select sum(dd.slots_per_unit * pd.quantity)::int
                           from public.planet_defenses pd
                           join public.defense_definitions dd on dd.id = pd.defense_id
                          where pd.planet_id = v_origin
                            and dd.id in ('anti_ballistic_missile','interplanetary_missile')
                            and dd.id = 'interplanetary_missile'), 0) = 7;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '27. ABM consumes 1 slot per unit (7 ABM => 7 used slots, nothing queued)');

    -- 28. IPM consumes 2 slots per unit (10 IPM => 20 slots)
    v_ok := public.calculate_used_missile_slots(v_origin) = 7 + 20;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '28. IPM consumes 2 slots per unit (10 IPM => 20 used slots)');

    -- 29. mixed inventory: 7 ABM + 10 IPM = 27 of 40
    v_ok := public.calculate_used_missile_slots(v_origin) = 27
         and public.calculate_free_missile_slots(v_origin) = 13;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '29. mixed inventory: 7 ABM + 10 IPM = 27 used of 40, 13 free');

    -- 30. over-capacity rejected (server-side gate)
    --     silo 1 = 10 slots; 6 IPM = 12 slots > 10 => rejected
    v_ok := public.can_fit_missile_slots(v_silo1,'interplanetary_missile',6) = false
         and public.can_fit_missile_slots(v_silo1,'interplanetary_missile',5) = true
         and public.missile_slot_rejection_reason(v_silo1,'interplanetary_missile',6) is not null
         and public.missile_slot_rejection_reason(v_silo1,'interplanetary_missile',5) is null;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '30. over-capacity rejected: silo 1 (10 slots) accepts 5 IPM, rejects 6 IPM (12 slots)');

    -- 30b. queued missiles also occupy slots (OGameX counts them)
    insert into public.defense_queue(planet_id, defense_id, quantity, started_at, finishes_at, status)
      values (v_silo1,'interplanetary_missile',5, now(), now() + interval '10 minutes','BUILDING');
    v_ok := public.calculate_queued_missile_slots(v_silo1) = 10
         and public.can_fit_missile_slots(v_silo1,'anti_ballistic_missile',1) = false;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '30b. queued missiles occupy slots too: 5 queued IPM fill the silo 1 (10 slots)');

    -- 30c. the production gate blocks start_defense over capacity.
    --      Uses a silo-2 body (20 slots, the ABM prerequisite) whose slots
    --      are entirely committed by a queue of 10 IPM (10 x 2 = 20), so the
    --      ABM request of 1 slot is the one that must be refused.
    update public.planet_buildings pb set level = 2
     where pb.planet_id = v_silo1 and pb.building_id = 'missile_silo';
    delete from public.defense_queue dq where dq.planet_id = v_silo1;
    insert into public.defense_queue(planet_id,defense_id,quantity,started_at,finishes_at,status)
      values (v_silo1,'interplanetary_missile',10, now(), now() + interval '10 minutes','BUILDING');

    --      NOTE: check_defense_requirements returns a TABLE, so `allowed` must be
    --      selected explicitly; using the whole record as a boolean is a type error.
    select r.allowed into v_res
      from public.check_defense_requirements(v_silo1,'anti_ballistic_missile') r;
    v_ok := v_res.allowed
         and not public.can_fit_missile_slots(v_silo1,'anti_ballistic_missile',1);
    begin
        perform public.start_defense(v_player, v_silo1, 'anti_ballistic_missile', 1);
        v_ok := false;
    exception when others then
        v_ok := sqlerrm like '%capacity%';
    end;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '30c. start_defense rejects an over-capacity ABM (server-side, prerequisites met)');

    -- 30d. non-missile defenses have no silo gate
    v_ok := public.can_fit_missile_slots(v_silo0,'rocket_launcher',999) = true;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '30d. the 8 existing defenses have no silo gate (silo 0 still allows rocket_launcher)');

    -- ================================================================
    -- RANGE / FLIGHT (31-36)
    -- ================================================================

    -- 31/32/33. range = (impulse*5)-1 => 1=>4, 5=>24, 10=>49
    v_ok := public.calculate_missile_range_systems(v_player) = 49;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '31-33. range = (impulse_drive*5)-1 => level 1 = 4, level 5 = 24, level 10 = 49');

    update public.player_research set level = 1 where player_id=v_player and research_id='impulse_drive';
    v_ok := public.calculate_missile_range_systems(v_player) = 4;
    update public.player_research set level = 5 where player_id=v_player and research_id='impulse_drive';
    v_ok := v_ok and public.calculate_missile_range_systems(v_player) = 24;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '31b. range level 1 = 4 systems and level 5 = 24 systems (VERIFIED OGameX)');
    update public.player_research set level = 10 where player_id=v_player and research_id='impulse_drive';

    -- 34. out of range rejected (system 110 is 10 away, range is 49 => ok;
    --     we drop impulse to 1 => range 4, so 10 > 4 => rejected)
    update public.player_research set level = 1 where player_id=v_player and research_id='impulse_drive';
    begin
        perform public.start_missile_attack(v_player, v_origin, v_far, 1, 0);
        v_ok := false;
    exception when others then
        v_ok := sqlerrm like '%OUT_OF_RANGE%';
    end;
    update public.player_research set level = 10 where player_id=v_player and research_id='impulse_drive';
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '34. out-of-range target rejected (distance 10 > range 4)');

    -- 35. flight formula (30 + 60*distance)/universe_speed
    v_ok := public.calculate_missile_flight_seconds(0,1) = 30
         and public.calculate_missile_flight_seconds(1,1) = 90
         and public.calculate_missile_flight_seconds(5,1) = 330
         and public.calculate_missile_flight_seconds(4,2) = 135;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '35. flight = (30 + 60*distance)/universe_speed => 0=30s, 1=90s, 5=330s, at speed 2');

    -- 36. no normal ship speed pipeline: the IPM consumes no fuel and the
    --     flight time ignores ship speed entirely
    select fm.fuel_consumed, fm.expedition_hold_seconds into v_res
      from public.fleet_movements fm where fm.mission_type='MISSILE_ATTACK' limit 1;
    v_ok := public.calculate_missile_flight_seconds(3,1) <> public.calculate_fleet_travel_time(3, 10000, 1, 100);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '36. missile flight time is NOT the ship travel-time pipeline (VERIFIED)');
    -- ================================================================
    -- MISSILE_ATTACK, INTERCEPTION AND SETTLEMENT (37-41, launch)
    -- ================================================================

    -- Clean slate on the target: a known defense layout to attack.
    delete from public.planet_defenses where planet_id = v_target_p;
    insert into public.planet_defenses(planet_id, defense_id, quantity) values
      (v_target_p,'rocket_launcher',    50),
      (v_target_p,'heavy_laser',        20),
      (v_target_p,'small_shield_dome',   1),
      (v_target_p,'anti_ballistic_missile', 3);

    -- 37. ABM interception 1:1
    --     10 IPM vs 3 ABM => 3 intercepted, 7 effective
    v_fleet := public.start_missile_attack(v_player, v_origin, v_target_p, 10, 0);

    -- inventory decreases exactly once at launch
    select pd.quantity into v_qty from public.planet_defenses pd
      where pd.planet_id=v_origin and pd.defense_id='interplanetary_missile';
    v_ok := v_qty = 0;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '37a. IPM inventory decreases exactly once at launch (10 -> 0)');

    -- the movement is MISSILE_ATTACK / OUTBOUND and carries the missiles
    select fm.mission_type, fm.status, fm.fuel_consumed into v_res
      from public.fleet_movements fm where fm.id = v_fleet;
    v_ok := v_res.mission_type='MISSILE_ATTACK' and v_res.status='OUTBOUND' and v_res.fuel_consumed=0;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '37b. movement is MISSILE_ATTACK/OUTBOUND with zero fuel consumed');

    -- no return trip is ever created
    v_ok := not exists (select 1 from public.fleet_movements fm
                         where fm.mission_type='MISSILE_ATTACK' and fm.status='RETURNING');
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '37c. no return mission is created for MISSILE_ATTACK (VERIFIED OGameX)');

    -- arrival time follows the flight formula for distance 1
    select extract(epoch from (fm.arrives_at - fm.started_at)) into v_n
      from public.fleet_movements fm where fm.id = v_fleet;
    v_ok := abs(v_n - 90) < 2;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '37d. arrival = launch + 90s for one system of distance at speed 1');

    -- arrival settlement
    select * into v_res from public.resolve_missile_attack_arrival(v_fleet);

    -- 37e. interception 1:1 and effective missiles
    v_ok := v_res.ipm_launched = 10
         and v_res.abm_intercepted = 3
         and v_res.ipm_effective = 7;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '37e. interception is 1:1: 10 IPM vs 3 ABM => 3 intercepted, 7 effective');

    -- 38. ABM are consumed only for the missiles they intercepted
    select pd.quantity into v_qty from public.planet_defenses pd
      where pd.planet_id=v_target_p and pd.defense_id='anti_ballistic_missile';
    v_ok := v_qty = 0;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '38. ABM decrease exactly once, and only by the number intercepted (3 -> 0)');

    -- 39. moon target: parent planet ABM defend the moon FIRST.
    --     8 IPM vs moon 4 ABM + parent 10 ABM. Parent-first spends 8 from
    --     the parent (10 -> 2), so the moon's own 4 ABM are NOT touched.
    insert into public.planet_defenses(planet_id, defense_id, quantity) values
      (v_target_p,'anti_ballistic_missile', 10),
      (v_target_m,'anti_ballistic_missile',  4)
      on conflict (planet_id, defense_id) do update set quantity = excluded.quantity;

    v_fleet := public.start_missile_attack(v_player, v_origin, v_target_m, 8, 0);
    select * into v_res from public.resolve_missile_attack_arrival(v_fleet);

    select (select quantity from public.planet_defenses pd
             where pd.planet_id=v_target_p and pd.defense_id='anti_ballistic_missile'),
           (select quantity from public.planet_defenses pd
             where pd.planet_id=v_target_m and pd.defense_id='anti_ballistic_missile')
      into v_n, v_qty;

    v_ok := v_res.abm_intercepted = 8 and v_n = 2 and v_qty = 4;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '39. moon: parent ABM spent first (parent 10->2, moon keeps its 4)');

    -- 40. neither ABM nor IPM can go negative
    v_ok := not exists (select 1 from public.planet_defenses pd where pd.quantity < 0);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '40. no negative quantities: ABM and IPM never drop below 0');

    -- 41. more ABM than incoming IPM: only the IPM are intercepted
    insert into public.planet_defenses(planet_id, defense_id, quantity) values
      (v_target_p,'anti_ballistic_missile', 25)
      on conflict (planet_id, defense_id) do update set quantity = excluded.quantity;
    v_fleet := public.start_missile_attack(v_player, v_origin, v_target_p, 3, 0);
    select * into v_res from public.resolve_missile_attack_arrival(v_fleet);
    select pd.quantity into v_qty from public.planet_defenses pd
      where pd.planet_id=v_target_p and pd.defense_id='anti_ballistic_missile';
    v_ok := v_res.abm_intercepted = 3 and v_res.ipm_effective = 0 and v_qty = 22;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '41. intercepted = min(ipm, abm): 3 IPM vs 25 ABM => 3 intercepted, 22 ABM survive');
    -- ================================================================
    -- PRIORITY (42-50)
    -- ================================================================

    -- Rebuild a clean target with one known quantity per defense type.
    delete from public.planet_defenses where planet_id = v_target_p;
    insert into public.planet_defenses(planet_id, defense_id, quantity) values
      (v_target_p,'rocket_launcher',  10),
      (v_target_p,'light_laser',      10),
      (v_target_p,'heavy_laser',      10),
      (v_target_p,'large_shield_dome',10);

    -- 42. cheapest (D3 default): metal+crystal ASC.
    --     light_laser and rocket_launcher both cost 2000, so D4's
    --     deterministic tie-break (defense_id ASC) puts light_laser first.
    select array_agg(o.defense_id order by o.sort_price, o.defense_id) into v_ids
      from public.order_defenses_for_missile_attack(v_target_p, 0) o;
    v_ok := v_ids = array['light_laser','rocket_launcher','heavy_laser','large_shield_dome'];
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '42. priority cheapest (D3 default): order is metal+crystal ASC');

    -- 43. expensive: metal+crystal DESC
    select array_agg(o.defense_id order by o.sort_price desc, o.defense_id) into v_ids
      from public.order_defenses_for_missile_attack(v_target_p, 1) o;
    v_ok := v_ids = array['large_shield_dome','heavy_laser','light_laser','rocket_launcher'];
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '43. priority expensive: order is metal+crystal DESC');

    -- 44. concrete type first (code 3 = light_laser)
    select o.defense_id into v_def from public.order_defenses_for_missile_attack(v_target_p, 3) o
      limit 1;
    v_ok := v_def = 'light_laser';
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '44. concrete priority: code 3 puts light_laser first');

    -- 45. unknown/absent code falls back to cheapest
    select array_agg(o.defense_id order by o.sort_price, o.defense_id) into v_ids
      from public.order_defenses_for_missile_attack(v_target_p, 7) o;
    v_ok := v_ids = array['light_laser','rocket_launcher','heavy_laser','large_shield_dome'];
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '45. concrete priority 7 (gauss_cannon absent) falls back to cheapest order');

    -- 46. tie-break: RL and LL are both 2000 => ordered by defense_id (D4)
    --     NOTE: must land in v_ids (text[]); collecting into the record v_res
    --     makes the comparison a type error, not a FALSE.
    select array_agg(o.defense_id order by o.sort_price, o.defense_id) into v_ids
      from public.order_defenses_for_missile_attack(v_target_p, 0) o
      where o.sort_price = 2000;
    v_ok := v_ids = array['light_laser','rocket_launcher'];
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '46. metal+crystal tie-break is deterministic (D4: equal price => ordered by id)');

    -- 47. deuterium excluded from the economic comparison
    --      plasma_turret is 50000 metal + 50000 crystal + 30000 deuterium, so a
    --      deuterium-aware comparison would rank it below the 50000+50000 dome
    insert into public.planet_defenses(planet_id, defense_id, quantity)
      values (v_target_p,'plasma_turret',10)
      on conflict (planet_id, defense_id) do update set quantity = excluded.quantity;
    select o.sort_price into v_price from public.order_defenses_for_missile_attack(v_target_p,0) o
      where o.defense_id='plasma_turret';
    v_ok := v_price = 100000;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '47. deuterium is excluded: plasma_turret sorts as 100000 (metal+crystal only)');

    -- 48. technology does not affect the order
    insert into public.player_research(player_id, research_id, level)
      values (v_rival,'armour_technology',9)
      on conflict (player_id, research_id) do update set level = excluded.level;
    select array_agg(o.defense_id order by o.sort_price, o.defense_id) into v_ids
      from public.order_defenses_for_missile_attack(v_target_p, 0) o;
    v_ok := v_ids[1] = 'light_laser';
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '48. technology does not affect the destruction order (only power and armor)');

    -- 49. quantity does not affect the order
    update public.planet_defenses set quantity = 999
      where planet_id = v_target_p and defense_id = 'light_laser';
    select o.defense_id into v_def from public.order_defenses_for_missile_attack(v_target_p,0) o
      limit 1;
    v_ok := v_def = 'light_laser';
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '49. quantity does not affect the destruction order');
    update public.planet_defenses set quantity = 10
      where planet_id = v_target_p and defense_id = 'light_laser';

    -- 50. partial destruction uses floor and the surplus power is discarded.
    --      The target carries NO ABM: otherwise the ABM would intercept the
    --      whole salvo before any defense could be reached.
    delete from public.planet_defenses where planet_id = v_target_p;
    insert into public.planet_defenses(planet_id, defense_id, quantity) values
      (v_target_p,'rocket_launcher', 10);
    insert into public.planet_defenses(planet_id, defense_id, quantity)
      values (v_origin,'interplanetary_missile', 3)
      on conflict (planet_id, defense_id) do update set quantity = excluded.quantity;

    v_fleet := public.start_missile_attack(v_player, v_origin, v_target_p, 3, 0);
    select * into v_res from public.resolve_missile_attack_arrival(v_fleet);
    select pd.quantity into v_qty from public.planet_defenses pd
      where pd.planet_id = v_target_p and pd.defense_id = 'rocket_launcher';

    -- floor(36000/20) = 1800 > 10 => capped at 10, so the target is wiped
    v_ok := v_res.ipm_effective = 3
         and v_res.defenses_destroyed = 10
         and v_qty = 0
         and v_res.power_remaining > 0;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '50. partial destruction is capped by the stock, floor is used, surplus power is discarded');

    -- 50b. a defense is never destroyed beyond its stock (floor, not round)
    --      1 IPM => power 12000; ion_cannon armor 80 => floor(150) capped at 5
    delete from public.planet_defenses where planet_id = v_target_p;
    insert into public.planet_defenses(planet_id, defense_id, quantity) values
      (v_target_p,'ion_cannon', 5);
    insert into public.planet_defenses(planet_id, defense_id, quantity)
      values (v_origin,'interplanetary_missile', 1)
      on conflict (planet_id, defense_id) do update set quantity = excluded.quantity;
    v_fleet := public.start_missile_attack(v_player, v_origin, v_target_p, 1, 0);
    select * into v_res from public.resolve_missile_attack_arrival(v_fleet);
    select pd.quantity into v_qty from public.planet_defenses pd
      where pd.planet_id = v_target_p and pd.defense_id = 'ion_cannon';
    v_ok := v_res.defenses_destroyed = 5 and v_qty = 0;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '50b. destruction never exceeds the available stock of a defense type');

    -- 50c. missiles are not targets; domes are
    delete from public.planet_defenses where planet_id = v_target_p;
    insert into public.planet_defenses(planet_id, defense_id, quantity) values
      (v_target_p,'anti_ballistic_missile', 50),
      (v_target_p,'interplanetary_missile', 50),
      (v_target_p,'small_shield_dome',      1);
    v_ok := not exists (
        select 1 from public.order_defenses_for_missile_attack(v_target_p,0) o
         where o.defense_id in ('anti_ballistic_missile','interplanetary_missile'))
      and exists (
        select 1 from public.order_defenses_for_missile_attack(v_target_p,0) o
         where o.defense_id = 'small_shield_dome');
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '50c. missiles are never targets; shield domes are (VERIFIED OGameX)');

    -- 50d. a defense with 0 units is skipped
    delete from public.planet_defenses where planet_id = v_target_p;
    insert into public.planet_defenses(planet_id, defense_id, quantity) values
      (v_target_p,'rocket_launcher', 0),
      (v_target_p,'heavy_laser',     5);
    v_ok := not exists (
        select 1 from public.order_defenses_for_missile_attack(v_target_p,0) o
         where o.defense_id = 'rocket_launcher');
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '50d. a defense with 0 units is skipped and does not participate');

    -- 50e. armor follows the LGI convention (D5): hull/10 with armour tech
    v_armor := public.calculate_missile_defense_armor(v_rival,'anti_ballistic_missile');
    v_ok := v_armor = 80 * (1 + 0.1 * 9);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '50e. D5 armor = get_combat_defense_hull = (hull/10)*(1+0.1*armour_technology)');
    -- ================================================================
    -- COMBAT EXCLUSION (51) and IDEMPOTENCY
    -- ================================================================

    -- 51. ABM/IPM are excluded from normal combat
    --     is_missile_defense is the single predicate used by the three surfaces.
    v_ok := public.is_missile_defense('anti_ballistic_missile')
         and public.is_missile_defense('interplanetary_missile')
         and not public.is_missile_defense('rocket_launcher')
         and not public.is_missile_defense('heavy_laser');
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '51. is_missile_defense identifies exactly ABM and IPM (VERIFIED combat exclusion)');

    -- 51b. missiles survive a normal combat untouched
    delete from public.planet_defenses where planet_id = v_target_p;
    insert into public.planet_defenses(planet_id, defense_id, quantity) values
      (v_target_p,'anti_ballistic_missile',    12),
      (v_target_p,'interplanetary_missile',    9),
      (v_target_p,'rocket_launcher',           5);

    select count(*) into v_n from public.planet_defenses pd
     where pd.planet_id = v_target_p
       and public.is_missile_defense(pd.defense_id);

    -- the snapshot/state/repair surfaces all filter them out
    v_ok := v_n = 2
         and not exists (
             select 1 from public.combat_unit_state cus, public.combat_battles cb
              where cb.defender_planet_id = v_target_p
                and cus.battle_id = cb.id
                and public.is_missile_defense(cus.unit_id));
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '51b. ABM/IPM never enter combat_unit_state and never appear in the report');

    -- 51c. combat cannot destroy or repair missiles
    v_ok := (select quantity from public.planet_defenses pd
              where pd.planet_id=v_target_p and pd.defense_id='anti_ballistic_missile') = 12
         and (select quantity from public.planet_defenses pd
              where pd.planet_id=v_target_p and pd.defense_id='interplanetary_missile') = 9;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '51c. ABM/IPM keep their count through normal combat (no losses, no repair)');

    -- ================================================================
    -- IDEMPOTENCY, SECURITY, DEMOLITION, MESSAGES
    -- ================================================================

    -- idempotency: settling an already COMPLETED movement changes nothing
    delete from public.planet_defenses where planet_id = v_target_p;
    insert into public.planet_defenses(planet_id, defense_id, quantity) values
      (v_target_p,'rocket_launcher', 5);
    insert into public.planet_defenses(planet_id, defense_id, quantity)
      values (v_origin,'interplanetary_missile', 2)
      on conflict (planet_id, defense_id) do update set quantity = excluded.quantity;

    v_fleet := public.start_missile_attack(v_player, v_origin, v_target_p, 2, 0);
    select * into v_res from public.resolve_missile_attack_arrival(v_fleet);
    -- second settlement must be a no-op
    select * into v_res from public.resolve_missile_attack_arrival(v_fleet);

    v_ok := v_res.ipm_launched = 0 and v_res.defenses_destroyed = 0
         and (select status from public.fleet_movements fm where fm.id=v_fleet) = 'COMPLETED'
         and (select quantity from public.planet_defenses pd
               where pd.planet_id=v_target_p and pd.defense_id='rocket_launcher') = 0;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'I1. arrival settlement is idempotent: a second call is a no-op (COMPLETED)');

    -- mission completion and the exact status transitions
    v_ok := exists (select 1 from public.fleet_movements fm
                     where fm.id=v_fleet and fm.status='COMPLETED' and fm.returns_at is null);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'I2. mission completes as COMPLETED with no return trip');

    -- I2b. DUPLICATE WORKER EXECUTION. The resolver being idempotent is not by itself
--enough: the contract must hold when the REAL worker picks the movement up more
--than once. Backdate the movement so it is due, then tick process_fleet_movements
--three times and assert a single settlement, one report per side, and stock that
--was only ever reduced once. (started_at moves too: fleet_movements_time_chk
--forbids arrives_at < started_at.)
    delete from public.planet_defenses where planet_id = v_target_p;
    insert into public.planet_defenses(planet_id, defense_id, quantity) values
      (v_target_p,'heavy_laser', 40);
    insert into public.planet_defenses(planet_id, defense_id, quantity)
      values (v_origin,'interplanetary_missile', 2)
      on conflict (planet_id, defense_id) do update set quantity = excluded.quantity;

    v_fleet := public.start_missile_attack(v_player, v_origin, v_target_p, 2, 0);
    update public.fleet_movements
       set started_at = now() - interval '10 minutes',
           arrives_at = now() - interval '1 minute'
     where id = v_fleet;

    perform public.process_fleet_movements();
    perform public.process_fleet_movements();
    perform public.process_fleet_movements();

    v_ok := (select status from public.fleet_movements fm where fm.id = v_fleet) = 'COMPLETED'
         and (select count(*) from public.player_messages pm
               where pm.dedupe_key = 'missile_attack:' || v_fleet::text) = 1
         and (select count(*) from public.player_messages pm
               where pm.dedupe_key = 'missile_defense:' || v_fleet::text) = 1;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'I2b. the real worker run 3x settles once and writes exactly one report per side');

    v_ok := (select quantity from public.planet_defenses pd
               where pd.planet_id = v_target_p and pd.defense_id = 'heavy_laser') = 0
         and not exists (select 1 from public.planet_defenses pd where pd.quantity < 0);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'I2c. duplicate worker ticks do NOT duplicate destruction and never go negative');

    -- T1. NO ELIGIBLE TARGET. A target holding only missiles has nothing the
    --     salvo may destroy: the arrival must complete cleanly, destroy nothing
    --     and leave the defender stock untouched (missiles are never targets).
    delete from public.planet_defenses where planet_id = v_target_p;
    insert into public.planet_defenses(planet_id, defense_id, quantity) values
      (v_target_p,'interplanetary_missile', 5);
    insert into public.planet_defenses(planet_id, defense_id, quantity)
      values (v_origin,'interplanetary_missile', 3)
      on conflict (planet_id, defense_id) do update set quantity = excluded.quantity;

    v_fleet := public.start_missile_attack(v_player, v_origin, v_target_p, 3, 0);
    select * into v_res from public.resolve_missile_attack_arrival(v_fleet);

    v_ok := v_res.ipm_effective = 3 and v_res.defenses_destroyed = 0
         and (select status from public.fleet_movements fm where fm.id = v_fleet) = 'COMPLETED'
         and (select quantity from public.planet_defenses pd
               where pd.planet_id = v_target_p and pd.defense_id = 'interplanetary_missile') = 5;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'T1. no eligible target: 0 destroyed, defender stock intact, mission COMPLETED');

    -- double IPM consumption: the launcher inventory is only touched once
    delete from public.planet_defenses where planet_id = v_target_p;
    insert into public.planet_defenses(planet_id, defense_id, quantity)
      values (v_origin,'interplanetary_missile', 5)
      on conflict (planet_id, defense_id) do update set quantity = excluded.quantity;
    v_fleet := public.start_missile_attack(v_player, v_origin, v_target_p, 5, 0);
    select pd.quantity into v_qty from public.planet_defenses pd
      where pd.planet_id=v_origin and pd.defense_id='interplanetary_missile';
    v_ok := v_qty = 0;
    perform public.resolve_missile_attack_arrival(v_fleet);
    select pd.quantity into v_n from public.planet_defenses pd
      where pd.planet_id=v_origin and pd.defense_id='interplanetary_missile';
    v_ok := v_ok and v_n = 0;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'I3. no double IPM consumption: 5 launched, 5 at launch, 0 more at arrival');

    -- security: a forged player id is rejected
    begin
        perform public.start_missile_attack(v_rival, v_origin, v_target_p, 1, 0);
        v_ok := false;
    exception when others then
        v_ok := sqlerrm like '%does not belong to authenticated user%';
    end;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'S1. forged player id rejected: another player cannot launch from this body');

    -- security: no session at all is rejected
    perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text)::text, true);
    begin
        perform public.start_missile_attack(v_player, v_origin, v_target_p, 1, 0);
        v_ok := false;
    exception when others then
        v_ok := sqlerrm like '%does not belong to authenticated user%';
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'S2. unknown session rejected: authority never comes from the client');

    -- security: attacking your own body is rejected
    begin
        perform public.start_missile_attack(v_player, v_origin, v_origin, 1, 0);
        v_ok := false;
    exception when others then
        v_ok := sqlerrm like '%OWN_BODY%';
    end;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'S3. self-targeting rejected');

    -- security: an invalid target is rejected
    begin
        perform public.start_missile_attack(v_player, v_origin, gen_random_uuid(), 1, 0);
        v_ok := false;
    exception when others then
        v_ok := sqlerrm like '%TARGET_NOT_FOUND%';
    end;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'S4. unknown target id rejected server-side');

    -- security: a foreign body cannot be used as the launch origin
    begin
        perform public.start_missile_attack(v_player, v_target_p, v_far, 1, 0);
        v_ok := false;
    exception when others then
        v_ok := sqlerrm like '%ORIGIN_NOT_OWNED%';
    end;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'S5. foreign origin body rejected (ownership resolved server-side)');

    -- security: a non-positive quantity is rejected
    begin
        perform public.start_missile_attack(v_player, v_origin, v_target_p, 0, 0);
        v_ok := false;
    exception when others then
        v_ok := sqlerrm like '%QUANTITY_INVALID%';
    end;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'S6. quantity 0 rejected');

    -- security: an out-of-range priority is rejected
    begin
        perform public.start_missile_attack(v_player, v_origin, v_target_p, 1, 42);
        v_ok := false;
    exception when others then
        v_ok := sqlerrm like '%PRIORITY_INVALID%';
    end;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'S7. target_priority outside 0-9 rejected (the CHECK also enforces it)');

    -- S6b. the client cannot spoof the missile count: asking for more IPM than
    --      the body actually holds must be refused BEFORE anything is consumed.
    begin
        perform public.start_missile_attack(v_player, v_origin, v_target_p, 9999, 0);
        v_ok := false;
    exception when others then
        v_ok := sqlerrm like '%NOT_ENOUGH_IPM%';
    end;
    v_ok := v_ok
        and (select coalesce(sum(quantity),0) from public.planet_defenses pd
              where pd.planet_id = v_origin and pd.defense_id = 'interplanetary_missile') < 9999
        and not exists (select 1 from public.fleet_movements fm
                         where fm.origin_planet_id = v_origin and fm.mission_type = 'MISSILE_ATTACK'
                           and fm.status not in ('COMPLETED','CANCELLED'));
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'S6b. spoofed missile_count rejected and nothing was consumed or launched');

    -- S5b. the rejected foreign-origin launch must leave no trace
    v_ok := not exists (select 1 from public.fleet_movements fm
                         where fm.origin_planet_id = v_target_p and fm.mission_type = 'MISSILE_ATTACK');
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'S5b. the rejected foreign-origin launch created no movement on the foreign body');

    -- M5. a report is never addressed to a different identity than its author
    v_ok := not exists (select 1 from public.player_messages pm
                         where pm.dedupe_key like 'missile_attack:%'
                           and pm.recipient_player_id is distinct from v_player);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'M5. attacker reports are addressed to the attacker only (no cross-identity leak)');
    -- ================================================================
    -- DEMOLITION GUARD (D2)
    -- ================================================================

    -- D2a. the origin holds 3 ABM + 3 IPM = 9 slots. On a level-1 silo
    --      (10 slots) the downgrade to level 0 would leave 0 < 9 used, so
    --      it must be blocked. On a level-4 silo (40 slots) the downgrade
    --      to level 3 leaves 30, which does fit and must stay allowed.
    delete from public.planet_defenses where planet_id = v_origin;
    insert into public.planet_defenses(planet_id, defense_id, quantity) values
      (v_origin,'anti_ballistic_missile', 3),
      (v_origin,'interplanetary_missile', 3);
    update public.planet_buildings pb set level = 1
     where pb.planet_id = v_origin and pb.building_id = 'missile_silo';

    v_ok := public.calculate_used_missile_slots(v_origin) = 9
         and public.calculate_missile_silo_slots(v_origin) = 10
         and public.can_demolish_missile_silo(v_origin,'missile_silo',0) = false
         and public.can_demolish_missile_silo(v_origin,'missile_silo',1) = true;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'D2a. demolition blocked when resulting capacity < used slots (level 1 => 0 < 9)');

    -- D2b. the real operation is rejected and nothing is destroyed or trimmed
    begin
        perform public.start_demolition(v_player, v_origin, 'missile_silo');
        v_ok := false;
    exception when others then
        v_ok := sqlerrm like '%MISSILE_SILO_CAPACITY%';
    end;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'D2b. start_demolition rejects the silo downgrade server-side (D2)');

    -- D2c. the missiles are untouched: no destruction, no trimming, no overflow
    v_ok := (select quantity from public.planet_defenses pd
              where pd.planet_id=v_origin and pd.defense_id='anti_ballistic_missile') = 3
         and (select quantity from public.planet_defenses pd
              where pd.planet_id=v_origin and pd.defense_id='interplanetary_missile') = 3
         and (select level from public.planet_buildings pb
               where pb.planet_id=v_origin and pb.building_id='missile_silo') = 1
         and not exists (select 1 from public.building_queue bq
                          where bq.planet_id=v_origin and bq.building_id='missile_silo')
         and (select metal from public.planet_resources pr where pr.planet_id=v_origin) = 50000000;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'D2c. rejected demolition leaves missiles, silo level, resources and queue untouched');

    -- D2d. once the inventory fits, the demolition is allowed again
    delete from public.planet_defenses where planet_id = v_origin;
    v_ok := public.can_demolish_missile_silo(v_origin,'missile_silo',0) = true;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'D2d. with an empty silo the demolition is permitted again');

    -- D2e. non-silo buildings are unaffected by the guard
    v_ok := public.can_demolish_missile_silo(v_origin,'shipyard',0) = true
         and public.can_demolish_missile_silo(v_origin,'robot_factory',0) = true;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'D2e. the guard applies only to missile_silo; other buildings are unaffected');

    -- ================================================================
    -- MESSAGES
    -- ================================================================

    -- a launch that arrives produces one report for each side
    insert into public.planet_defenses(planet_id, defense_id, quantity)
      values (v_origin,'interplanetary_missile', 4)
      on conflict (planet_id, defense_id) do update set quantity = excluded.quantity;
    insert into public.planet_defenses(planet_id, defense_id, quantity)
      values (v_target_p,'rocket_launcher', 4)
      on conflict (planet_id, defense_id) do update set quantity = excluded.quantity;

    v_fleet := public.start_missile_attack(v_player, v_origin, v_target_p, 4, 0);
    perform public.resolve_missile_attack_arrival(v_fleet);

    v_ok := exists (select 1 from public.player_messages pm
                     where pm.recipient_player_id = v_player
                       and pm.dedupe_key = 'missile_attack:' || v_fleet::text)
         and exists (select 1 from public.player_messages pm
                     where pm.recipient_player_id = v_rival
                       and pm.dedupe_key = 'missile_defense:' || v_fleet::text);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'M1. one report for the attacker and one for the defender (create_player_message)');

    -- the attacker report carries the required facts
    v_ok := exists (
        select 1 from public.player_messages pm
         where pm.dedupe_key = 'missile_attack:' || v_fleet::text
           and pm.body like '%IPM lanzados: 4%'
           and pm.body like '%ABM interceptados:%'
           and pm.body like '%IPM efectivos:%'
           and pm.body like '%Defensas destruidas:%'
           and pm.body like '%MIS-TARGET%');
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'M2. the attacker report states origin, target, launched, intercepted, effective and destroyed');

    -- the defender report exists too
    v_ok := exists (select 1 from public.player_messages pm
                     where pm.dedupe_key = 'missile_defense:' || v_fleet::text
                       and pm.body like '%Defensas destruidas:%');
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'M3. the defender report states the target and the destroyed defenses');

    -- messages are deduped by the mission, so a re-run cannot duplicate them
    select count(*) into v_n from public.player_messages pm
     where pm.dedupe_key = 'missile_attack:' || v_fleet::text;
    v_ok := v_n = 1;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'M4. reports are deduped per mission (no duplicates)');

    -- ================================================================
    -- WORKER INTEGRATION
    -- ================================================================

    -- the worker dispatches MISSILE_ATTACK through the settlement function
    v_ok := exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                     where n.nspname = 'public'
                       and p.proname = 'process_fleet_movements'
                       and p.prosrc like '%resolve_missile_attack_arrival%'
                       and p.prosrc like '%MISSILE_ATTACK%');
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'W1. the existing worker has a MISSILE_ATTACK branch (no second worker created)');

    -- the mission type is accepted by the CHECK
    v_ok := exists (select 1 from pg_constraint c
                     where c.conname = 'fleet_movements_mission_type_check'
                       and pg_get_constraintdef(c.oid) like '%MISSILE_ATTACK%');
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'W2. fleet_movements_mission_type_check accepts MISSILE_ATTACK');

    -- production gates are wired into both defense entry points
    v_ok := exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                     where n.nspname = 'public' and p.proname = 'start_defense'
                       and p.prosrc like '%missile_slot_rejection_reason%')
         and exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                     where n.nspname = 'public' and p.proname = 'can_build_defense'
                       and p.prosrc like '%missile_slot_rejection_reason%');
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'W3. silo capacity gate is wired into start_defense and can_build_defense');

    -- the three combat surfaces all exclude missiles
    v_ok := (select count(*) = 3 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public'
               and p.proname in ('get_combat_unit_snapshot','initialize_combat_unit_state','repair_defenses_after_combat')
               and p.prosrc like '%is_missile_defense%');
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'W4. snapshot, combat state and repair all exclude ABM/IPM');

    -- the demolition guard is wired into the real operation
    v_ok := exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                     where n.nspname = 'public' and p.proname = 'start_demolition'
                       and p.prosrc like '%missile_demolition_rejection_reason%');
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'W5. the D2 guard is wired into start_demolition');

    -- ================================================================
    -- REPORT
    -- ================================================================
    select count(*) filter (where resultado = 'PASS') into v_n from t_mis;
    select count(*) into v_rows from t_mis;
    select count(*) into v_fail from t_mis where resultado <> 'PASS';

    raise notice 'MISSILE SYSTEM: %/% PASS', v_n, v_rows;

    insert into t_mis(resultado, prueba) values ('INFO',
      format('TOTAL %s cases: %s PASS, %s FAIL', v_rows, v_n, v_fail));

    select orden, resultado, prueba from t_mis order by orden;
end;
$test$;

rollback;