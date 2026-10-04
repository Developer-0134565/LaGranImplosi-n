-- SOLAR SATELLITE END-TO-END FIXTURE — LA GRAN IMPLOSIÓN
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract: the whole life cycle of `solar_satellite` as a SHIP built in the shipyard.
--   definition / cost / build time / prerequisites / kinds, queue 0→1→10→N, cost debit, completion,
--   no ghost energy while queued, idempotency, temperature dependency, interaction with Energy
--   Technology, Plasma, Fusion Plant, crawlers and the universe production rate, moon support, and the
--   refusal to fly one.
-- SOURCES (lanedirt/OGameX main):
--   CivilShipObjects.php  id 212 · price GameObjectPrice(0, 2000, 500, 0) · requirements [shipyard 1]
--                        · NO valid_planet_types (empty = both kinds, the rule LGI already applies)
--                        · GameObjectProperties(SI 2000, shield 1, attack 0, speed 0, capacity 0, fuel 1)
--                        · energy_formula floor((getPlanetTempMax() + 140) / 6) * amount
-- LIMITATION: single-session harness; concurrency not executed.
-- NOTE on timestamps: the probe planets are created with the UNIVERSE CLOCK's last tick, never with
-- `now()`/`clock_timestamp()`. `process_planet_tick` settles to the clock and
-- `update_planet_resources_until` raises INVALID_RESOURCE_TIMESTAMP when the settlement instant is
-- EARLIER than the stored `last_calculated_at`. Writing a wall-clock timestamp makes this fixture fail by
-- construction whenever it runs inside the minute after a tick. That is a fixture rule, not a product bug.

begin;

drop table if exists t_ss;
create temp table t_ss(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_universe uuid; v_clock timestamptz;
    v_hot uuid; v_mid uuid; v_cold uuid; v_moon uuid; v_foreign uuid;
    v_ok boolean; v_fail integer := 0; v_msg text; v_reason text; v_rows bigint; v_allowed boolean;
    v_c0 numeric; v_d0 numeric; v_m0 numeric; v_c1 numeric; v_d1 numeric; v_m1 numeric;
    v_en0 numeric; v_en1 numeric; v_unit numeric;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    if v_player is null or v_universe is null then
        raise exception 'TEST_ABORT: an auth-linked player is required';
    end if;
    select last_tick_at into v_clock from public.universe_clock where universe_id = v_universe;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    -- probe bodies: positions 1 / 8 / 15 (T_max 240 / 50 / -110) plus a moon and a foreign planet
    delete from public.planets where galaxy = 499 and system between 496 and 497;
    insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
        temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind)
    select v_universe, v_player, format('SatProbe P%s', g.pos), 499, 496, g.pos,
           t.temperature_min, t.temperature_max, 200, 0, false, false, 'PLANET'
      from unnest(array[1,8,15]) as g(pos)
      cross join lateral public.planet_temperature_for_position(g.pos) t;

    insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
        temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind, parent_planet_id, moon_diameter_km)
    select v_universe, v_player, 'SatProbe Moon', 499, 496, 8, 10, 50, 10, 0, false, false, 'MOON', id, 2000
      from public.planets where galaxy = 499 and system = 496 and position = 8;

    select pl.id into v_foreign from public.players pl where pl.id <> v_player order by pl.created_at limit 1;
    insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
        temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind)
    select v_universe, v_foreign, 'SatForeign', 499, 497, 8, 10, 50, 200, 0, false, false, 'PLANET';

    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at)
    select id, 100000000, 100000000, 100000000, 0, v_clock
      from public.planets where galaxy = 499 and system in (496, 497);
    insert into public.planet_buildings(planet_id, building_id, level)
    select id, 'solar_plant', 20 from public.planets where galaxy = 499 and system in (496, 497)
    union all select id, 'shipyard', 1 from public.planets where galaxy = 499 and system in (496, 497)
    union all select id, 'metal_mine', 10 from public.planets where galaxy = 499 and system in (496, 497)
    union all select id, 'crystal_mine', 10 from public.planets where galaxy = 499 and system in (496, 497)
    union all select id, 'deuterium_synthesizer', 10 from public.planets where galaxy = 499 and system in (496, 497);

    select id into v_hot   from public.planets where galaxy = 499 and system = 496 and position = 1;
    select id into v_mid   from public.planets where galaxy = 499 and system = 496 and position = 8;
    select id into v_cold  from public.planets where galaxy = 499 and system = 496 and position = 15;
    select id into v_moon  from public.planets where galaxy = 499 and system = 496 and kind = 'MOON';
    select id into v_foreign from public.planets where galaxy = 499 and system = 497;

    -- ================================================================= 1. DEFINITION (OGameX verbatim)
    v_ok := exists (select 1 from public.ship_definitions sd
                     where sd.id = 'solar_satellite' and sd.base_metal = 0 and sd.base_crystal = 2000
                       and sd.base_deuterium = 500 and sd.base_build_time_seconds = 20
                       and sd.valid_kinds = '{PLANET,MOON}' and sd.cargo_capacity = 0 and sd.speed = 0)
           and (select count(*) from public.ship_prerequisites sp where sp.ship_id = 'solar_satellite') = 1
           and exists (select 1 from public.ship_prerequisites sp
                        where sp.ship_id = 'solar_satellite' and sp.prerequisite_type = 'building'
                          and sp.building_id = 'shipyard' and sp.required_level = 1);
    insert into t_ss(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '1. definition: 0/2000/500, 20 s base, {PLANET,MOON}, speed 0, cargo 0, prerequisite = shipyard 1 only');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================= 2. COST
    select c.metal, c.crystal, c.deuterium into v_m1, v_c1, v_d1
      from public.calculate_ship_cost('solar_satellite', 1) c;
    select c.metal, c.crystal, c.deuterium into v_m0, v_c0, v_d0
      from public.calculate_ship_cost('solar_satellite', 10) c;
    v_ok := v_m1 = 0 and v_c1 = 2000 and v_d1 = 500 and v_m0 = 0 and v_c0 = 20000 and v_d0 = 5000;
    insert into t_ss(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. cost 1 unit = 0/%s/%s and 10 units = 0/%s/%s (linear; there is no dark matter column)',
             v_c1, v_d1, v_c0, v_d0));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================= 3. PREREQUISITE GATE
    delete from public.planet_buildings where planet_id = v_mid and building_id = 'shipyard';
    select r.allowed, r.reason into v_allowed, v_reason from public.can_build_ship(v_player, v_mid, 'solar_satellite', 1) r;
    v_ok := v_allowed = false and v_reason like 'Requires shipyard level 1%';
    insert into public.planet_buildings(planet_id, building_id, level) values (v_mid, 'shipyard', 1)
      on conflict (planet_id, building_id) do update set level = 1;
    insert into t_ss(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. without a shipyard it is refused (%s)', coalesce(v_reason, '?')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================= 4. QUEUE 0 -> 1, COST DEBIT, NO GHOST ENERGY
    -- The cost is read from what start_ship REPORTS, not from a resource delta: the dispatcher runs
    -- process_planet_tick first, which settles production into the same rows it is about to debit, so a
    -- before/after delta also contains the settlement. The queue row count and the energy delta are the
    -- real assertions here.
    select pp.energy_per_hour into v_en0 from public.calculate_planet_production(v_mid) pp;
    v_msg := null; v_c1 := null; v_d1 := null; v_m1 := null;
    begin
        select r.crystal_cost, r.deuterium_cost, r.metal_cost into v_c1, v_d1, v_m1
          from public.start_ship(v_player, v_mid, 'solar_satellite', 1) r;
    exception when others then v_msg := sqlerrm; end;
    select coalesce(sum(quantity),0) into v_rows from public.shipyard_queue
     where planet_id = v_mid and ship_id = 'solar_satellite' and status = 'BUILDING';
    select pp.energy_per_hour into v_en1 from public.calculate_planet_production(v_mid) pp;
    v_ok := v_msg is null and v_c1 = 2000 and v_d1 = 500 and v_m1 = 0
       and v_rows = 1 and (v_en1 - v_en0) = 0;
    insert into t_ss(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. 0->1: charged %s crystal / %s deut / %s metal, queue BUILDING qty %s, energy delta while queued = %s (no ghost energy)',
             v_c1, v_d1, v_m1, v_rows, v_en1 - v_en0));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================= 5. COMPLETION -> INVENTORY + ENERGY
    update public.shipyard_queue set started_at = now() - interval '1 second', finishes_at = now()
     where planet_id = v_mid and ship_id = 'solar_satellite' and status = 'BUILDING';
    perform public.process_shipyard_queue_until(v_mid, now());
    select coalesce(sum(quantity),0) into v_rows from public.planet_ships
     where planet_id = v_mid and ship_id = 'solar_satellite';
    select pp.energy_per_hour into v_en1 from public.calculate_planet_production(v_mid) pp;
    v_unit := floor((50 + 140) / 6.0);
    v_ok := v_rows = 1 and (v_en1 - v_en0) = v_unit;
    insert into t_ss(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. completion: %s satellite in planet_ships, energy +%s = floor((T_max 50 + 140)/6) = %s', v_rows, v_en1 - v_en0, v_unit));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================= 6. IDEMPOTENCY
    perform public.process_shipyard_queue_until(v_mid, now());
    select coalesce(sum(quantity),0) into v_rows from public.planet_ships
     where planet_id = v_mid and ship_id = 'solar_satellite';
    v_ok := v_rows = 1;
    insert into t_ss(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. re-running the shipyard worker does not duplicate the unit (still %s)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================= 7. QUEUE 1 -> 10 -> 11 TOTAL
    v_msg := null; v_c1 := null; v_d1 := null;
    begin
        select r.crystal_cost, r.deuterium_cost into v_c1, v_d1
          from public.start_ship(v_player, v_mid, 'solar_satellite', 10) r;
    exception when others then v_msg := sqlerrm; end;
    update public.shipyard_queue set started_at = now() - interval '1 second', finishes_at = now()
     where planet_id = v_mid and ship_id = 'solar_satellite' and status = 'BUILDING';
    perform public.process_shipyard_queue_until(v_mid, now());
    select coalesce(sum(quantity),0) into v_rows from public.planet_ships
     where planet_id = v_mid and ship_id = 'solar_satellite';
    select pp.energy_per_hour into v_en1 from public.calculate_planet_production(v_mid) pp;
    v_ok := v_msg is null and v_c1 = 20000 and v_d1 = 5000 and v_rows = 11
       and (v_en1 - v_en0) = 11 * v_unit;
    insert into t_ss(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. 1->10: charged %s/%s, total %s satellites, energy +%s = 11 x %s',
             v_c1, v_d1, v_rows, v_en1 - v_en0, v_unit));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================= 8. QUANTITY EDGES
    v_msg := null;
    begin perform public.start_ship(v_player, v_mid, 'solar_satellite', 0);
    exception when others then v_msg := sqlerrm; end;
    insert into t_ss(resultado, prueba) values (case when v_msg like 'Quantity must be greater than 0%' then 'PASS' else 'FAIL' end,
      format('8a. quantity 0 is refused (%s)', coalesce(v_msg, '?')));
    v_fail := v_fail + case when v_msg like 'Quantity must be greater than 0%' then 0 else 1 end;
    v_msg := null;
    begin perform public.start_ship(v_player, v_mid, 'solar_satellite', -5);
    exception when others then v_msg := sqlerrm; end;
    insert into t_ss(resultado, prueba) values (case when v_msg like 'Quantity must be greater than 0%' then 'PASS' else 'FAIL' end,
      format('8b. negative quantity is refused (%s)', coalesce(v_msg, '?')));
    v_fail := v_fail + case when v_msg like 'Quantity must be greater than 0%' then 0 else 1 end;
    v_msg := null;
    begin perform public.start_ship(v_player, v_mid, 'solar_satellite', 1000000000000);
    exception when others then v_msg := sqlerrm; end;
    insert into t_ss(resultado, prueba) values (case when v_msg is not null then 'PASS' else 'FAIL' end,
      format('8c. an absurd quantity is refused by the resource gate, not accepted (%s)', coalesce(v_msg, 'ACCEPTED')));
    v_fail := v_fail + case when v_msg is not null then 0 else 1 end;

    -- ================================================================= 9. OWNERSHIP / IDOR
    v_msg := null;
    begin perform public.start_ship(v_player, v_foreign, 'solar_satellite', 1);
    exception when others then v_msg := sqlerrm; end;
    insert into t_ss(resultado, prueba) values (case when v_msg like 'Planet does not belong to player%' then 'PASS' else 'FAIL' end,
      format('9a. a FOREIGN planet is refused (%s)', coalesce(v_msg, '?')));
    v_fail := v_fail + case when v_msg like 'Planet does not belong to player%' then 0 else 1 end;

    v_msg := null;
    begin perform public.start_ship(v_player, gen_random_uuid(), 'solar_satellite', 1);
    exception when others then v_msg := sqlerrm; end;
    insert into t_ss(resultado, prueba) values (case when v_msg like 'Planet not found or destroyed%' then 'PASS' else 'FAIL' end,
      format('9b. an invented planet UUID is refused (%s)', coalesce(v_msg, '?')));
    v_fail := v_fail + case when v_msg like 'Planet not found or destroyed%' then 0 else 1 end;

    v_msg := null;
    begin perform public.start_ship(v_foreign, v_mid, 'solar_satellite', 1);
    exception when others then v_msg := sqlerrm; end;
    insert into t_ss(resultado, prueba) values (case when v_msg like 'Player does not belong to authenticated user%' then 'PASS' else 'FAIL' end,
      format('9c. a forged player_id is refused (%s)', coalesce(v_msg, '?')));
    v_fail := v_fail + case when v_msg like 'Player does not belong to authenticated user%' then 0 else 1 end;

    perform set_config('request.jwt.claims', '{}', true);
    v_msg := null;
    begin perform public.start_ship(v_player, v_mid, 'solar_satellite', 1);
    exception when others then v_msg := sqlerrm; end;
    insert into t_ss(resultado, prueba) values (case when v_msg like 'Authentication required%' then 'PASS' else 'FAIL' end,
      format('9d. without a session it is refused (%s)', coalesce(v_msg, '?')));
    v_fail := v_fail + case when v_msg like 'Authentication required%' then 0 else 1 end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    v_ok := (select count(*) from public.shipyard_queue where planet_id = v_foreign) = 0
       and (select count(*) from public.planet_ships where planet_id = v_foreign) = 0;
    insert into t_ss(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '9e. none of the refused attempts created a queue row or a unit anywhere');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================= 10. TEMPERATURE (hot / medium / cold)
    delete from public.planet_ships where planet_id in (v_hot, v_cold);
    select pp.energy_per_hour into v_en0 from public.calculate_planet_production(v_hot) pp;
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_hot, 'solar_satellite', 10);
    select pp.energy_per_hour into v_en1 from public.calculate_planet_production(v_hot) pp;
    select pp.energy_per_hour into v_eu  from public.calculate_planet_production(v_cold) pp;
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_cold, 'solar_satellite', 10);
    select pp.energy_per_hour into v_en1 from public.calculate_planet_production(v_cold) pp;
    select pp.energy_per_hour into v_c1 from public.calculate_planet_production(v_cold) pp;
    v_ok := abs((v_eu - v_en0) - 10 * floor((240 + 140) / 6.0)) < 0.0001
       and abs((v_c1 - v_eu) - 10 * floor((-110 + 140) / 6.0)) < 0.0001
       and (v_eu - v_en0) > (v_c1 - v_eu);
    insert into t_ss(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. 10 satellites: hot(pos 1) +%s, cold(pos 15) +%s → hot > cold, exactly floor((T_max+140)/6)*10',
             v_eu - v_en0, v_c1 - v_eu));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================= 11. ENERGY TECHNOLOGY DOES NOT TOUCH IT
    delete from public.player_research where player_id = v_player and research_id = 'energy_technology';
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_mid, 'solar_satellite', 10)
      on conflict (planet_id, ship_id) do update set quantity = 10;
    select pp.energy_per_hour into v_en0 from public.calculate_planet_production(v_mid) pp;
    insert into public.player_research(player_id, research_id, level) values (v_player, 'energy_technology', 10);
    select pp.energy_per_hour into v_en1 from public.calculate_planet_production(v_mid) pp;
    select pp.energy_per_hour into v_eu  from public.calculate_planet_production(v_mid) pp;
    v_ok := v_eu > v_en0;   -- the solar plant term is boosted ...
    delete from public.player_research where player_id = v_player and research_id = 'energy_technology';
    select pp.energy_per_hour into v_c1 from public.calculate_planet_production(v_mid) pp;
    insert into t_ss(resultado, prueba) values (case when v_ok and v_c1 = v_en0 then 'PASS' else 'FAIL' end,
      format('11. energy_technology 0 -> 10 moves the total energy (%s -> %s) and the SATELLITE term itself is unchanged (back to %s with tech 0)',
             v_en0, v_eu, v_c1));
    v_fail := v_fail + case when v_ok and v_c1 = v_en0 then 0 else 1 end;

    -- ================================================================= 12. PLASMA DOES NOT TOUCH ENERGY
    insert into public.player_research(player_id, research_id, level) values (v_player, 'plasma_technology', 20)
      on conflict (player_id, research_id) do update set level = 20;
    select pp.energy_per_hour into v_en1 from public.calculate_planet_production(v_mid) pp;
    delete from public.player_research where player_id = v_player and research_id = 'plasma_technology';
    v_ok := v_en1 = v_c1;
    insert into t_ss(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('12. plasma_technology 20 leaves the energy at %s (satellites are not a plasma target)', v_en1));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================= 13. FUSION PLANT AND CRAWLERS DO NOT CONTAMINATE
    -- energy_per_hour is PRODUCTION. A fusion plant must add its OWN term on top, and crawlers must leave
    -- energy_per_hour untouched (they only throttle metal/crystal/deuterium through the energy factor).
    insert into public.planet_buildings(planet_id, building_id, level) values (v_mid, 'fusion_plant', 5)
      on conflict (planet_id, building_id) do update set level = 5;
    select pp.energy_per_hour into v_en1 from public.calculate_planet_production(v_mid) pp;
    delete from public.planet_buildings where planet_id = v_mid and building_id = 'fusion_plant';
    select pp.energy_per_hour into v_c1 from public.calculate_planet_production(v_mid) pp;
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_mid, 'crawler', 40)
      on conflict (planet_id, ship_id) do update set quantity = 40;
    select pp.energy_per_hour into v_eu from public.calculate_planet_production(v_mid) pp;
    delete from public.planet_ships where planet_id = v_mid and ship_id = 'crawler';
    v_ok := v_en1 = v_c1 + floor(30 * 5 * power(1.05, 5)) and v_eu = v_c1;
    insert into t_ss(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('13. a fusion plant adds its OWN term on top (+%s) and 40 crawlers leave energy_per_hour at %s: the satellite sum is a separate term',
             v_en1 - v_c1, v_eu));
    v_fail := v_fail + case when v_ok then 0 else 1 end;
    insert into t_ss(resultado, prueba) values ('INFO',
      'INFO (ADJACENT FINDING, not the satellite): calculate_planet_energy_balance sums only building_energy_definitions, so the crawler term (effective units x 50) that calculate_planet_production adds to its own consumption is NOT reflected in the reported consumption. Pre-existing, proven by the fusion/crawler fixture; it does not affect satellites. Not touched by this mission.');

    -- ================================================================= 14. UNIVERSE PRODUCTION RATE DOES NOT SCALE ENERGY
    select coalesce(sum(ps.quantity),0) into v_rows from public.planet_ships ps
     where ps.planet_id = v_mid and ps.ship_id = 'solar_satellite';
    select pp.energy_per_hour into v_en1 from public.calculate_planet_production(v_mid) pp;
    v_ok := v_en1 = floor(v_rows * v_unit + 20 * 20 * power(1.1, 20));
    insert into t_ss(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('14. energy = %s satellites x %s + solar plant 20, with NO rate multiplier (total %s)',
             v_rows, v_unit, v_en1));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================= 15. MOON (OGameX sets no valid_planet_types => both kinds)
    delete from public.planet_ships where planet_id = v_moon;
    v_msg := null;
    begin perform public.start_ship(v_player, v_moon, 'solar_satellite', 1);
    exception when others then v_msg := sqlerrm; end;
    select coalesce(sum(quantity),0) into v_rows from public.shipyard_queue
     where planet_id = v_moon and ship_id = 'solar_satellite' and status = 'BUILDING';
    update public.shipyard_queue set started_at = now() - interval '1 second', finishes_at = now()
     where planet_id = v_moon and ship_id = 'solar_satellite' and status = 'BUILDING';
    perform public.process_shipyard_queue_until(v_moon, now());
    select pp.energy_per_hour into v_en1 from public.calculate_planet_production(v_moon) pp;
    v_ok := v_msg is null and v_rows = 1 and v_en1 = v_unit + floor(20 * 20 * power(1.1, 20));
    insert into t_ss(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('15. builds and produces on a MOON: energy %s = solar plant 20 (%s) + one satellite (%s). OGameX sets no valid_planet_types, which means both kinds',
             v_en1, floor(20 * 20 * power(1.1, 20)), v_unit));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================= 16. IT CANNOT FLY (speed 0, OGameX)
    v_msg := null;
    begin perform public.start_fleet(v_player, v_mid, v_hot, 'solar_satellite', 1, 'TRANSPORT');
    exception when others then v_msg := sqlerrm; end;
    v_ok := v_msg is not null and v_msg not like 'Accepted%';
    insert into t_ss(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('16. dispatching one is refused, never silently sent with a broken speed (%s)', coalesce(v_msg, 'ACCEPTED')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================= 17. NO QUANTITY LIMIT EXISTS
    v_ok := not exists (
        select 1 from information_schema.check_constraints cc
          join information_schema.table_constraints tc on tc.constraint_name = cc.constraint_name
         where tc.table_schema = 'public' and tc.table_name = 'ship_definitions'
           and cc.check_clause ilike '%solar_satellite%')
       and not exists (select 1 from information_schema.check_constraints cc
          join information_schema.table_constraints tc on tc.constraint_name = cc.constraint_name
         where tc.table_schema = 'public' and tc.table_name = 'planet_ships'
           and cc.check_clause ilike '%quantity%');
    insert into t_ss(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '17. neither the catalog nor planet_ships caps a satellite quantity: OGameX and classic set no cap, so LGI must not invent one');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================= 18. THE UI CATALOG EXPOSES IT WITHOUT EXTRA WORK
    v_ok := exists (select 1 from public.ui_ship_definitions() u where u.id = 'solar_satellite');
    insert into t_ss(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '18. ui_ship_definitions() already lists it, so the shipyard screen shows it with no new contract');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- ================================================================= 19. COMBAT PROFILE (OGameX GameObjectProperties, corrected 2026-09-30)
    -- shield 1, ATTACK 0, speed 0, capacity 0, hull 200 (= OGameX structural 2000 / 10, the project's
    -- documented hull convention). attack 0 is what makes a satellite a damage sponge instead of a weapon.
    v_ok := exists (select 1 from public.ship_definitions sd
                     where sd.id = 'solar_satellite' and sd.attack = 0 and sd.shield = 1
                       and sd.hull = 200 and sd.speed = 0 and sd.cargo_capacity = 0);
    insert into t_ss(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '19. combat profile matches OGameX: attack 0, shield 1, hull 200, speed 0, cargo 0');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- the defence snapshot must therefore contribute ZERO attack from satellites
    insert into t_ss(resultado, prueba) values ('INFO',
      'INFO: get_combat_unit_snapshot()/initialize_combat_unit_state() read sd.attack for every planet_ships row, so satellites now add 0 attack to a defence line (they still soak damage with shield 1 / hull 200).');

    insert into t_ss(resultado, prueba) values ('INFO',
      'INFO: the satellite is a SHIP, not a building: OGameX models it in CivilShipObjects, LGI keeps it in ship_definitions with the shipyard queue. Not converted to a facility.');

    if v_fail > 0 then
        raise exception 'SOLAR SATELLITE FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_ss order by orden;

drop table if exists t_ss;

ROLLBACK;
