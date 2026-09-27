-- AI BEHAVIOUR POLICY FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional fixture: it always ends in ROLLBACK (zero LIVE residue).
--
-- Contract under test (migrations 20260926290000_ai_behaviour_model + 20260926291000_ai_behaviour_policy):
--   1. deterministic daily activity (same player+date -> same schedule, different dates differ)
--   2. activity between 3 h and 6 h per day, in 2..5 windows
--   3. windows ordered, non-overlapping; ai_is_active_at true inside and false in the gaps
--   4. persistent personality (assigned once, never re-rolled)
--   5. persistent planet template + deterministic per-planet variation, biased by personality
--   6. cooldown ranges per family, monotone in the tick roll
--   7. an AI younger than 24 h never attacks (P(attack human) = 0, no exception)
--   8. espionage runs through the certified dispatcher before any attack
--   9. power estimation reuses the certified combat helpers (and the documented 1.15 uncertainty factor)
--  10. attack probability per zone/personality + a favourable deterministic roll really attacks
--  11. colonisation through start_colonize_fleet
--  12. colonisation FROM A MOON is usable by the AI (the route LGI already allows)
--  13. fleet slots respected (no fleet family without a free slot)
--  14. colony cap respected
--  15. an inactive window executes NOTHING
--  16. the worker runs inside the certified AI actor contract
--
-- LIMITATION: single-session harness with ROLLBACK, like every other fixture of this repository. The daily
-- schedule is deterministic, so the fixture selects concrete instants instead of waiting for real time.

begin;

drop table if exists t_ai;
create temp table t_ai(orden serial, resultado text, prueba text);

do $test$
declare
    v_ai uuid; v_ai_planet uuid; v_ai_universe uuid;
    v_human uuid; v_human_planet uuid;
    v_date date;
    v_w record;
    v_windows integer; v_total integer;
    v_start integer; v_active timestamptz; v_inactive timestamptz;
    v_i integer; v_ok boolean; v_fail integer := 0;
    v_txt text; v_txt2 text; v_num numeric; v_cnt integer; v_diff integer;
    v_moon uuid; v_fleet uuid; v_near uuid;
    v_decision record; v_rows integer;
begin
    /* ------------------------------------------------------------------ SETUP */
    select pl.id, pl.universe_id into v_ai, v_ai_universe
      from public.players pl
      join public.universes u on u.id = pl.universe_id and u.is_active
     where pl.player_type = 'AI' and pl.user_id is null
     order by pl.created_at, pl.id
     limit 1;

    select p.id into v_ai_planet
      from public.planets p
     where p.player_id = v_ai and p.kind = 'PLANET' and not p.is_destroyed
     order by p.is_homeworld desc, p.created_at, p.id
     limit 1;

    select pl.id into v_human from public.players pl where pl.user_id is not null order by pl.created_at limit 1;
    select p.id into v_human_planet from public.planets p
     where p.player_id = v_human and not p.is_destroyed order by p.created_at limit 1;

    if v_ai is null or v_ai_planet is null or v_human_planet is null then
        raise exception 'TEST_ABORT: an AI player with a planet and a human planet are required';
    end if;

    v_date := (now() at time zone 'utc')::date;

    /* a HUMAN neighbour body as close as possible to the AI: the closest legal human target, so it ranks at
       the top of the espionage candidates and the protection assertions are deterministic. */
    insert into public.planets(universe_id, player_id, name, galaxy, system, position, kind, is_homeworld)
    select c.universe_id, v_human, 'Human neighbour', c.g, c.s, c.p, 'PLANET', false
      from (
        select p.universe_id, g as g, s as s, pos as p, row_number() over (order by
                 case when g <> p.galaxy then 20000 * abs(g - p.galaxy)
                      when s <> p.system then 2700 + 95 * abs(s - p.system)
                      else 1000 + 5 * abs(pos - p.position) end, g, s, pos) as rn
          from public.planets p
          cross join generate_series(1, 3) g
          cross join generate_series(1, 15) s
          cross join generate_series(1, 15) pos
         where p.id = v_ai_planet
           and not exists (select 1 from public.planets x
                            where x.universe_id = p.universe_id and x.galaxy = g
                              and x.system = s and x.position = pos and not x.is_destroyed)
      ) c
     where c.rn = 1
    returning id into v_near;

    if v_near is null then
        raise exception 'TEST_ABORT: no free coordinate to place the human neighbour';
    end if;

    insert into public.planet_resources(planet_id, metal, crystal, deuterium) values (v_near, 1000, 1000, 1000);
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_near, 'light_fighter', 1);

    /* the fixture starts from a clean profile state for this player */
    delete from public.ai_player_profiles where player_id = v_ai;
    delete from public.ai_planet_profiles where planet_id = v_ai_planet;

    /* NEW (2026-09-26): AI players are DORMANT by default (20260926295000). This fixture certifies the ACTIVE
       policy, so the tested AI is explicitly activated — the DORMANT path has its own fixture
       (ai_bootstrap_and_dormant.sql). */
    insert into public.ai_player_profiles (player_id, personality, status)
    values (v_ai, 'INDUSTRIAL', 'ACTIVE')
    on conflict (player_id) do update set status = 'ACTIVE';

    /* ------------------------------------------------- 1. DETERMINISTIC SCHEDULE */
    v_ok := (select count(*) from (
                select * from public.ai_daily_activity(v_ai, v_date)
                except
                select * from public.ai_daily_activity(v_ai, v_date)
             ) d) = 0;
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '1a. the same (AI player, UTC date) always yields the same schedule');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_diff := 0;
    for v_i in 1..3 loop
        if exists (
            select * from public.ai_daily_activity(v_ai, v_date)
            except
            select * from public.ai_daily_activity(v_ai, v_date + v_i)
        ) then
            v_diff := v_diff + 1;
        end if;
    end loop;
    v_ok := v_diff >= 1;
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1b. different dates produce different schedules (%s of 3 days differed)', v_diff));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------- 2. 3..6 h PER DAY IN 2..5 WINDOWS */
    v_ok := true; v_cnt := 0;
    for v_txt in select pl.id::text from public.players pl
                 join public.universes u on u.id = pl.universe_id and u.is_active
                where pl.player_type = 'AI' and pl.user_id is null
                order by pl.created_at, pl.id limit 20 loop
        for v_i in 0..2 loop
            select coalesce(sum(w.end_minute - w.start_minute), 0), count(*) into v_total, v_windows
              from public.ai_daily_activity(v_txt::uuid, v_date + v_i) w;
            v_cnt := v_cnt + 1;
            if v_total < 180 or v_total > 360 or v_windows < 2 or v_windows > 5 then
                v_ok := false;
                insert into t_ai(resultado, prueba) values ('FAIL',
                  format('2. player %s on %s -> %s min in %s windows', v_txt, v_date + v_i, v_total, v_windows));
            end if;
        end loop;
    end loop;
    v_fail := v_fail + case when v_ok then 0 else 1 end;
    if v_ok then
        insert into t_ai(resultado, prueba) values ('PASS',
          format('2. %s generated day schedules are between 3 h and 6 h and use 2..5 windows', v_cnt));
    end if;

    /* ------------------------------- 3. ORDERED, NON-OVERLAPPING, ACTIVE/INACTIVE */
    v_ok := not exists (
        select 1
          from public.ai_daily_activity(v_ai, v_date) a
          join public.ai_daily_activity(v_ai, v_date) b on b.window_index = a.window_index + 1
         where a.end_minute > b.start_minute
    );

    select min(w.start_minute) into v_start from public.ai_daily_activity(v_ai, v_date) w;
    v_active := ((v_date::timestamp + make_interval(mins => v_start + 1)) at time zone 'utc');
    v_inactive := ((v_date::timestamp + make_interval(mins => v_start - 1)) at time zone 'utc');

    v_ok := v_ok
            and public.ai_is_active_at(v_ai, v_active)
            and not public.ai_is_active_at(v_ai, v_inactive);
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. windows ordered and disjoint; ai_is_active_at inside the window = %s, in the gap = %s',
             public.ai_is_active_at(v_ai, v_active), public.ai_is_active_at(v_ai, v_inactive)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------ 4. PERSISTENT PERSONALITY */
    select * into v_decision from public.ai_ensure_player_profile(v_ai);
    v_txt := v_decision.personality;
    select * into v_decision from public.ai_ensure_player_profile(v_ai);
    v_ok := v_txt in ('INDUSTRIAL','SCIENTIST','MILITARY','PREDATOR') and v_decision.personality = v_txt;

    update public.ai_player_profiles set personality = 'SCIENTIST' where player_id = v_ai;
    select * into v_decision from public.ai_ensure_player_profile(v_ai);
    v_ok := v_ok and v_decision.personality = 'SCIENTIST';
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4a. the personality is assigned once (%s) and a stored one is never re-rolled (%s)',
             v_txt, v_decision.personality));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := false;
    begin
        perform 1 from public.ai_ensure_player_profile(v_human);
    exception when others then
        v_ok := sqlerrm like 'AI_PROFILE_TARGET_NOT_AI%';
    end;
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '4b. a human player is refused: profiles only exist for AI players');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------- 5. PLANET TEMPLATE + VARIATION (persistent) */
    update public.ai_player_profiles set personality = 'INDUSTRIAL' where player_id = v_ai;
    select template, variation into v_txt, v_num from public.ai_planet_profile(v_ai_planet);
    v_ok := v_txt in ('MINING_WORLD','EXPANSION_WORLD') and v_num >= 0 and v_num < 1;
    v_txt2 := v_txt;
    select template, variation into v_txt, v_num from public.ai_planet_profile(v_ai_planet);
    v_ok := v_ok and v_txt = v_txt2;
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. template %s (variation %s) persists for the planet and follows the INDUSTRIAL personality',
             v_txt, v_num));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------------- 6. COOLDOWN RANGES */
    v_ok := true;
    for v_w in
        select * from (values
            ('building', 10, 35), ('research', 30, 120), ('production', 20, 90),
            ('fleet', 20, 90), ('espionage', 15, 60), ('attack', 45, 180), ('colonization', 120, 360)
        ) as t(kind, lo, hi)
    loop
        for v_txt in select unnest(array['INDUSTRIAL','SCIENTIST','MILITARY','PREDATOR']) loop
            if public.ai_cooldown_minutes(v_w.kind, v_txt, 0) < greatest(1, floor(v_w.lo * 0.70))
               or public.ai_cooldown_minutes(v_w.kind, v_txt, 1) > ceil(v_w.hi * 1.30)
               or public.ai_cooldown_minutes(v_w.kind, v_txt, 0) > public.ai_cooldown_minutes(v_w.kind, v_txt, 1)
            then
                v_ok := false;
                insert into t_ai(resultado, prueba) values ('FAIL',
                  format('6. %s / %s -> roll 0 = %s, roll 1 = %s (expected %s..%s scaled by personality)',
                         v_w.kind, v_txt, public.ai_cooldown_minutes(v_w.kind, v_txt, 0),
                         public.ai_cooldown_minutes(v_w.kind, v_txt, 1), v_w.lo, v_w.hi));
            end if;
        end loop;
    end loop;
    v_fail := v_fail + case when v_ok then 0 else 1 end;
    if v_ok then
        insert into t_ai(resultado, prueba) values ('PASS',
          '6. every family/personality combination stays inside its documented range and is monotone in the roll');
    end if;

    /* ------------- 7. A YOUNG AI NEVER ATTACKS (P(attack human) = 0 for 24 h) ------------- */
    perform public.ai_actor_begin(v_ai);

    update public.players set created_at = now() - interval '1 hour' where id = v_ai;
    update public.planet_resources set metal = 0, crystal = 0, deuterium = 20000 where planet_id = v_ai_planet;
    delete from public.planet_ships where planet_id = v_ai_planet;
    delete from public.planet_defenses where planet_id = v_ai_planet;
    delete from public.player_research where player_id = v_ai;
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_ai_planet, 'light_fighter', 40);
    insert into public.planet_buildings(planet_id, building_id, level) values (v_ai_planet, 'shipyard', 12)
      on conflict (planet_id, building_id) do update set level = 12;
    delete from public.ai_player_profiles where player_id = v_ai;
    insert into public.ai_player_profiles(player_id, personality, status) values (v_ai, 'PREDATOR', 'ACTIVE');

    /* the AI owns a report about the human planet: it knows a weak target and would like to attack it */
    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at, status)
    values (v_ai, v_ai_planet, 'ESPIONAGE', now() - interval '2 hours', now() - interval '1 hour', 'COMPLETED')
    returning id into v_fleet;
    insert into public.espionage_reports(fleet_id, player_id, target_planet_id, espionage_level,
                                         target_espionage_level, metal, crystal, deuterium, energy, fleet, defenses)
    values (v_fleet, v_ai, v_near, 5, 0, 0, 0, 0, 0, '{"light_fighter": 1}'::jsonb, '{}'::jsonb);

    for v_w in select * from public.ai_espionage_candidates(v_ai, v_ai_planet, 5) loop
        insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at, status)
        values (v_ai, v_ai_planet, 'ESPIONAGE', now() - interval '2 hours', now() - interval '1 hour', 'COMPLETED')
        returning id into v_fleet;
        insert into public.espionage_reports(fleet_id, player_id, target_planet_id, espionage_level,
                                             target_espionage_level, metal, crystal, deuterium, energy, fleet, defenses)
        values (v_fleet, v_ai, v_w.target_planet_id, 5, 0, 0, 0, 0, 0, '{"light_fighter": 1}'::jsonb, '{}'::jsonb);
    end loop;

    /* the human neighbour IS a legal, known and weak attack candidate: the 24 h protection is the only
       reason the AI does not attack it */
    v_ok := exists (select 1 from public.ai_attack_candidates(v_ai, v_ai_planet, 60, 20) c
                     where c.target_planet_id = v_near and c.relative_power >= 0.75);
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '7a. the human neighbour is a legal, known and weak attack candidate');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select * into v_decision from public.ai_decide_and_act(v_ai, 60, v_active);
    select count(*) into v_rows from public.fleet_movements
     where player_id = v_ai and mission_type = 'ATTACK' and created_at > now() - interval '1 minute';
    perform public.ai_actor_end();

    v_ok := v_decision.action = 'none' and v_decision.result = 'AI_PROTECTION_24H' and v_rows = 0;
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. a 1-hour-old AI with a known human target does not attack: action=%s result=%s attack_movements=%s',
             v_decision.action, v_decision.result, v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------- 8. ESPIONAGE RUNS THROUGH THE CERTIFIED DISPATCHER ------------------- */
    perform public.ai_actor_begin(v_ai);
    update public.players set created_at = now() - interval '3 days' where id = v_ai;
    update public.fleet_movements set status = 'COMPLETED'
     where player_id = v_ai and status not in ('COMPLETED','CANCELLED');
    insert into public.player_research(player_id, research_id, level) values (v_ai, 'espionage_technology', 4)
      on conflict (player_id, research_id) do update set level = 4;
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_ai_planet, 'espionage_probe', 5)
      on conflict (planet_id, ship_id) do update set quantity = 5;
    /* no warships: the espionage family must be the only legal one */
    delete from public.planet_ships where planet_id = v_ai_planet and ship_id in ('light_fighter');
    update public.planet_resources set deuterium = 20000 where planet_id = v_ai_planet;

    select * into v_decision from public.ai_decide_and_act(v_ai, 60, v_active);
    select count(*) into v_rows from public.fleet_movements
     where player_id = v_ai and mission_type = 'ESPIONAGE' and destination_planet_id = v_decision.target::uuid
       and status not in ('COMPLETED','CANCELLED');
    perform public.ai_actor_end();

    v_ok := v_decision.action = 'espionage' and v_rows = 1;
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. with only probes available the AI spies first: action=%s target=%s (ESPIONAGE movement created: %s)',
             v_decision.action, v_decision.target, v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------- 9. POWER ESTIMATION REUSES THE CERTIFIED COMBAT HELPERS ---------------- */
    v_num := public.ai_composition_power('{"light_fighter": 10}'::jsonb, '{}'::jsonb, v_ai);
    v_ok := v_num = round(10 * (
                  coalesce(public.get_combat_ship_attack(v_ai, 'light_fighter'), 0)
                + coalesce(public.get_combat_ship_shield(v_ai, 'light_fighter'), 0)
                + coalesce(public.get_combat_ship_hull(v_ai, 'light_fighter'), 0)), 2);

    v_num := public.ai_composition_power('{"light_fighter": 10}'::jsonb, '{}'::jsonb, null);
    v_ok := v_ok and v_num = round(10 * (
                  (select sd.attack from public.ship_definitions sd where sd.id = 'light_fighter')
                + (select sd.shield from public.ship_definitions sd where sd.id = 'light_fighter')
                + (select sd.hull / 10 from public.ship_definitions sd where sd.id = 'light_fighter')) * 1.15, 2);

    insert into public.player_research(player_id, research_id, level) values (v_ai, 'weapons_technology', 1)
      on conflict (player_id, research_id) do update set level = 1;
    v_num := public.ai_composition_power('{"light_fighter": 10}'::jsonb, '{}'::jsonb, v_ai);
    v_ok := v_ok and v_num = round(10 * (
                  coalesce(public.get_combat_ship_attack(v_ai, 'light_fighter'), 0)
                + coalesce(public.get_combat_ship_shield(v_ai, 'light_fighter'), 0)
                + coalesce(public.get_combat_ship_hull(v_ai, 'light_fighter'), 0)), 2);

    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. power equals the certified helper sum (weapons 1 -> %s) and the unknown owner adds exactly 1.15', v_num));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* --------------------- 10. ATTACK PROBABILITY + A FAVOURABLE ROLL REALLY ATTACKS --------- */
    v_ok := abs(public.ai_attack_probability(0.50, 'PREDATOR') - 0.026) < 1e-9
        and abs(public.ai_attack_probability(0.80, 'PREDATOR') - 0.195) < 1e-9
        and abs(public.ai_attack_probability(1.00, 'PREDATOR') - 0.455) < 1e-9
        and abs(public.ai_attack_probability(1.30, 'PREDATOR') - 0.78) < 1e-9
        and public.ai_attack_probability(0.50, 'SCIENTIST') < public.ai_attack_probability(0.50, 'MILITARY')
        and public.ai_attack_probability(0.50, 'MILITARY') < public.ai_attack_probability(0.50, 'PREDATOR')
        and public.ai_attack_probability(0.50, 'INDUSTRIAL') < public.ai_attack_probability(0.50, 'PREDATOR')
        and public.ai_attack_probability(null, 'PREDATOR') = 0
        and public.ai_attack_probability(9.99, 'PREDATOR') = 0.85;
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10a. zones scale with the personality and never exceed 0.85 (predator 0.50 -> %s, 1.30 -> %s)',
             public.ai_attack_probability(0.50, 'PREDATOR'), public.ai_attack_probability(1.30, 'PREDATOR')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    perform public.ai_actor_begin(v_ai);
    update public.fleet_movements set status = 'COMPLETED'
     where player_id = v_ai and status not in ('COMPLETED','CANCELLED');
    update public.ai_player_profiles
       set next_action_at = null, last_action_at = null, personality = 'PREDATOR'
     where player_id = v_ai;
    update public.planet_resources set metal = 0, crystal = 0, deuterium = 200000 where planet_id = v_ai_planet;
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_ai_planet, 'light_fighter', 40)
      on conflict (planet_id, ship_id) do update set quantity = 40;
    insert into public.player_research(player_id, research_id, level) values (v_ai, 'combustion_drive', 6)
      on conflict (player_id, research_id) do update set level = 6;

    /* search a tick of the active window whose deterministic roll is below the attack probability */
    select w.end_minute into v_windows from public.ai_daily_activity(v_ai, v_date) w where w.window_index = 1;
    v_i := v_start + 1;
    loop
        v_active := ((v_date::timestamp + make_interval(mins => v_i)) at time zone 'utc');
        exit when public.ai_roll(v_ai, 'attack_roll|' || v_human_planet::text, v_active)
                 < public.ai_attack_probability(9.99, 'PREDATOR');
        v_i := v_i + 1;
        exit when v_i >= v_windows;
    end loop;

    select * into v_decision from public.ai_decide_and_act(v_ai, 60, v_active);
    select count(*) into v_rows from public.fleet_movements
     where player_id = v_ai and mission_type = 'ATTACK' and destination_planet_id = v_decision.target::uuid
       and status not in ('COMPLETED','CANCELLED');
    perform public.ai_actor_end();

    v_ok := v_decision.action = 'attack' and v_rows = 1;
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10b. an adult PREDATOR with a favourable roll attacks the espied target: action=%s (ATTACK movement: %s)',
             v_decision.action, v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------------------------- 11. COLONISATION ------------------------------- */
    perform public.ai_actor_begin(v_ai);
    update public.fleet_movements set status = 'COMPLETED'
     where player_id = v_ai and status not in ('COMPLETED','CANCELLED');
    insert into public.player_research(player_id, research_id, level) values (v_ai, 'impulse_drive', 4)
      on conflict (player_id, research_id) do update set level = 4;
    update public.ai_player_profiles
       set next_action_at = null, last_action_at = null, personality = 'INDUSTRIAL'
     where player_id = v_ai;
    delete from public.planet_ships where planet_id = v_ai_planet;
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_ai_planet, 'colony_ship', 1);
    update public.planet_resources set metal = 0, crystal = 0, deuterium = 500000 where planet_id = v_ai_planet;

    select * into v_decision from public.ai_decide_and_act(v_ai, 60, v_active);
    select count(*) into v_rows from public.fleet_movements
     where player_id = v_ai and mission_type = 'COLONIZE' and status not in ('COMPLETED','CANCELLED');
    perform public.ai_actor_end();

    v_ok := v_decision.action = 'colony' and v_rows = 1;
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11. with a colony ship and the cap allowed the AI colonises: action=%s target=%s (COLONIZE movement: %s)',
             v_decision.action, v_decision.target, v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------------- 12. COLONISATION FROM A MOON (route LGI already allows) ---- */
    perform public.ai_actor_begin(v_ai);
    update public.ai_player_profiles set next_action_at = null, last_action_at = null where player_id = v_ai;

    insert into public.planets(universe_id, player_id, name, galaxy, system, position, kind,
                               parent_planet_id, moon_diameter_km, fields_total, fields_used, is_homeworld)
    select p.universe_id, v_ai, 'AI probe moon', p.galaxy, p.system, p.position, 'MOON',
           p.id, 6000, 3, 0, false
      from public.planets p where p.id = v_ai_planet
    returning id into v_moon;
    insert into public.planet_resources(planet_id, metal, crystal, deuterium) values (v_moon, 0, 0, 500000);
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_moon, 'colony_ship', 1);
    insert into public.planet_buildings(planet_id, building_id, level) values (v_moon, 'shipyard', 4)
      on conflict (planet_id, building_id) do update set level = 4;
    update public.fleet_movements set status = 'COMPLETED'
     where player_id = v_ai and status not in ('COMPLETED','CANCELLED');

    /* the moon is the only living body: the focus body is therefore the moon, deterministically */
    update public.planets set is_destroyed = true where id = v_ai_planet;
    v_active := ((v_date::timestamp + make_interval(mins => v_start + 1)) at time zone 'utc');

    select * into v_decision from public.ai_decide_and_act(v_ai, 60, v_active);
    select count(*) into v_rows from public.fleet_movements fm
     where fm.player_id = v_ai and fm.mission_type = 'COLONIZE'
       and fm.origin_planet_id = v_moon and fm.status not in ('COMPLETED','CANCELLED');
    perform public.ai_actor_end();

    update public.planets set is_destroyed = false where id = v_ai_planet;

    v_ok := v_decision.action = 'colony' and v_rows = 1;
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('12. the AI colonises with a MOON as origin: action=%s target=%s (movement from the moon: %s)',
             v_decision.action, v_decision.target, v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------- 13. FLEET SLOTS ARE RESPECTED --------------------------- */
    perform public.ai_actor_begin(v_ai);
    update public.ai_player_profiles set next_action_at = null, last_action_at = null where player_id = v_ai;
    update public.fleet_movements set status = 'COMPLETED'
     where player_id = v_ai and status not in ('COMPLETED','CANCELLED');

    /* one in-flight movement with computer_technology 0 -> the single slot is occupied */
    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at, status)
    values (v_ai, v_ai_planet, 'TRANSPORT', now(), now() + interval '3 hours', 'OUTBOUND')
    returning id into v_fleet;

    insert into public.planet_ships(planet_id, ship_id, quantity)
    select p.id, 'espionage_probe', 3 from public.planets p where p.player_id = v_ai and not p.is_destroyed
    on conflict (planet_id, ship_id) do update set quantity = 3;
    insert into public.planet_ships(planet_id, ship_id, quantity)
    select p.id, 'colony_ship', 1 from public.planets p where p.player_id = v_ai and not p.is_destroyed
    on conflict (planet_id, ship_id) do update set quantity = 1;
    update public.planet_resources set deuterium = 500000
     where planet_id in (select id from public.planets where player_id = v_ai);

    select count(*) into v_rows from public.fleet_movements where player_id = v_ai;
    select * into v_decision from public.ai_decide_and_act(v_ai, 60, v_active);
    select count(*) into v_cnt from public.fleet_movements where player_id = v_ai;
    perform public.ai_actor_end();

    v_ok := v_decision.action not in ('espionage','attack','colony') and v_cnt = v_rows;
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('13. with 0 free fleet slots no fleet family is attempted: action=%s result=%s new movements=%s',
             v_decision.action, v_decision.result, v_cnt - v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------- 14. COLONY CAP IS RESPECTED ----------------------------- */
    perform public.ai_actor_begin(v_ai);
    update public.fleet_movements set status = 'COMPLETED' where id = v_fleet;
    update public.ai_player_profiles set next_action_at = null, last_action_at = null where player_id = v_ai;

    insert into public.planets(universe_id, player_id, name, galaxy, system, position, kind, is_homeworld)
    select c.universe_id, v_ai, 'AI overflow ' || c.rn, c.g, c.s, c.p, 'PLANET', false
      from (
        select p.universe_id, g as g, s as s, pos as p, row_number() over (order by g, s, pos) as rn
          from public.planets p
          cross join generate_series(1, 3) g
          cross join generate_series(1, 15) s
          cross join generate_series(1, 15) pos
         where p.id = v_ai_planet
           and not exists (select 1 from public.planets x
                            where x.universe_id = p.universe_id and x.galaxy = g
                              and x.system = s and x.position = pos and not x.is_destroyed)
      ) c
     where c.rn <= 2;

    insert into public.planet_resources(planet_id, metal, crystal, deuterium)
    select p.id, 0, 0, 500000 from public.planets p
     where p.player_id = v_ai and not p.is_destroyed
       and not exists (select 1 from public.planet_resources pr where pr.planet_id = p.id);

    select count(*) into v_windows from public.planets where player_id = v_ai and kind = 'PLANET' and not is_destroyed;
    select count(*) into v_rows from public.fleet_movements where player_id = v_ai and mission_type = 'COLONIZE';
    select * into v_decision from public.ai_decide_and_act(v_ai, 60, v_active);
    select count(*) into v_cnt from public.fleet_movements where player_id = v_ai and mission_type = 'COLONIZE';
    perform public.ai_actor_end();

    v_ok := v_windows > 2 and v_decision.action <> 'colony' and v_cnt = v_rows;
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('14. with %s planets over the cap the AI does not colonise: action=%s (COLONIZE movements: %s)',
             v_windows, v_decision.action, v_cnt - v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------- 15. AN INACTIVE WINDOW EXECUTES NOTHING ----------------------- */
    perform public.ai_actor_begin(v_ai);
    update public.ai_player_profiles set next_action_at = null, last_action_at = null where player_id = v_ai;

    select count(*) into v_rows from public.fleet_movements where player_id = v_ai;
    select * into v_decision from public.ai_decide_and_act(v_ai, 60, v_inactive);
    select count(*) into v_cnt from public.fleet_movements where player_id = v_ai;
    perform public.ai_actor_end();

    v_ok := v_decision.action = 'none' and v_decision.result = 'AI_INACTIVE_WINDOW'
            and v_decision.target is null and v_cnt = v_rows;
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('15. outside the activity window nothing happens: action=%s result=%s target=%s movements=%s',
             v_decision.action, v_decision.result, v_decision.target, v_cnt - v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------- 16. THE WORKER STAYS INSIDE THE AI ACTOR ---------------------- */
    select count(*) into v_rows from public.run_ai_policy_worker(3, 60, v_active);
    v_ok := v_rows >= 1 and coalesce(current_setting('lgi.ai_player', true), '') = ''
            and coalesce(current_setting('lgi.ai_worker', true), '') = '';
    insert into t_ai(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('16. the worker processed %s players and cleared the declared AI actor afterwards', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    if v_fail > 0 then
        raise exception 'AI BEHAVIOUR FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select case when count(*) filter (where resultado = 'FAIL') = 0 then 'PASS' else 'FAIL' end as final,
       count(*) filter (where resultado = 'PASS') as passed,
       count(*) as assertions
  from t_ai;

select orden, resultado, prueba from t_ai order by orden;

drop table if exists t_ai;

rollback;






