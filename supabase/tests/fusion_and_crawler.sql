-- FUSION PLANT + CRAWLER FIXTURE — LA GRAN IMPLOSIÓN
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
-- Contract (20260926140000/…40100/…40200): fusion energy + fuel burn + fuel gate, crawler bonus + cap + energy,
-- definition/prerequisite wiring, kind gates aligned with OGameX, and no regression when neither is present.
-- LIMITATION: single-session harness; concurrency not executed.

begin;

drop table if exists t_fc;
create temp table t_fc(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_planet uuid; v_universe uuid;
    v_energy0 numeric; v_energy_f numeric; v_deut0 numeric; v_deut_f numeric;
    v_eco numeric; v_prod numeric; v_expected_fuel numeric;
    v_metal0 numeric; v_metal1 numeric; v_metal2 numeric; v_metal3 numeric;
    v_ok boolean; v_fail integer := 0; v_rows integer; v_raised text;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_planet
      from public.planets p where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET'
      order by p.created_at limit 1;

    if v_player is null or v_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet is required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    insert into public.player_research(player_id, research_id, level)
    values (v_player, 'energy_technology', 3)
    on conflict (player_id, research_id) do update set level = 3;

    delete from public.planet_buildings where planet_id = v_planet;
    insert into public.planet_buildings(planet_id, building_id, level) values
        (v_planet, 'metal_mine', 10), (v_planet, 'crystal_mine', 10), (v_planet, 'deuterium_synthesizer', 10),
        (v_planet, 'solar_plant', 60);
    delete from public.planet_ships where planet_id = v_planet;

    update public.planet_resources set deuterium = 1000000, metal = 1000000, crystal = 1000000,
           last_calculated_at = clock_timestamp() where planet_id = v_planet;

    v_ok := exists (select 1 from public.building_definitions
                     where id = 'fusion_plant' and valid_kinds = '{PLANET}' and base_metal = 900 and cost_factor = 1.8)
            and exists (select 1 from public.building_prerequisites
                         where building_id = 'fusion_plant' and prerequisite_building_id = 'deuterium_synthesizer'
                           and required_level = 5)
            and exists (select 1 from public.building_research_prerequisites
                         where building_id = 'fusion_plant' and research_id = 'energy_technology'
                           and required_level = 3);
    insert into t_fc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '1. fusion_plant definition + deuterium_synthesizer 5 + energy_technology 3');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := exists (select 1 from public.ship_definitions
                     where id = 'crawler' and valid_kinds = '{PLANET}' and base_metal = 2000)
            and (select count(*) from public.ship_prerequisites where ship_id = 'crawler') = 4
            and exists (select 1 from public.ship_prerequisites
                         where ship_id = 'crawler' and prerequisite_type = 'building'
                           and building_id = 'shipyard' and required_level = 4)
            and exists (select 1 from public.ship_prerequisites
                         where ship_id = 'crawler' and research_id = 'armour_technology' and required_level = 4);
    insert into t_fc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '2. crawler definition (planet only) with its 4 prerequisites');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select pp.energy_per_hour, pp.deuterium_per_hour into v_energy0, v_deut0
      from public.calculate_planet_production(v_planet) pp;

    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'fusion_plant', 5)
    on conflict (planet_id, building_id) do update set level = 5;

    select pp.energy_per_hour, pp.deuterium_per_hour into v_energy_f, v_deut_f
      from public.calculate_planet_production(v_planet) pp;

    select r.economy, r.production into v_eco, v_prod from public.calculate_universe_rates(v_universe) r;
    v_expected_fuel := 10 * 5 * power(1.1, 5) * v_eco * v_prod;

    v_ok := v_energy_f - v_energy0 = 220;
    insert into t_fc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. fusion 5 with energy_technology 3 adds exactly 220 energy (%s -> %s)', v_energy0, v_energy_f));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := abs((v_deut0 - v_deut_f) - v_expected_fuel) < 0.0001;
    insert into t_fc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. the reactor burns 10*L*1.1^L base per hour (%s -> %s, expected %s)',
             v_deut0, v_deut_f, v_expected_fuel));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    update public.planet_resources set deuterium = 0 where planet_id = v_planet;

    select pp.energy_per_hour, pp.deuterium_per_hour into v_energy_f, v_deut_f
      from public.calculate_planet_production(v_planet) pp;

    v_ok := v_energy_f - v_energy0 = 0 and abs(v_deut0 - v_deut_f) < 0.0001;
    insert into t_fc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. an empty tank stops the reactor: no energy, no burn (%s / %s)',
             v_energy_f - v_energy0, v_deut0 - v_deut_f));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* crawler assertions: energy must not become the limiting factor for the bonus ratio tests */
    update public.planet_resources set deuterium = 1000000 where planet_id = v_planet;

    select pp.metal_per_hour into v_metal0 from public.calculate_planet_production(v_planet) pp;

    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_planet, 'crawler', 100)
    on conflict (planet_id, ship_id) do update set quantity = 100;

    select pp.metal_per_hour into v_metal1 from public.calculate_planet_production(v_planet) pp;

    /* mine base = 30 * 10 * 1.1^10; bonus = floor(base * 0.0002 * 100) → ratio 1.019283… */
    v_ok := abs((v_metal1 / nullif(v_metal0, 0)) - ((30 * 10 * power(1.1, 10) + floor(30 * 10 * power(1.1, 10) * 0.02))
                                                    / (30 * 10 * power(1.1, 10)))) < 0.0005;
    insert into t_fc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. 100 crawlers add 0.02 %% each to the mine output (ratio %s)', round(v_metal1 / nullif(v_metal0, 0), 6)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    update public.planet_ships set quantity = 1000 where planet_id = v_planet and ship_id = 'crawler';
    select pp.metal_per_hour into v_metal2 from public.calculate_planet_production(v_planet) pp;

    /* cap = (metal_mine + crystal_mine + deuterium_synthesizer) * 8 = 240 effective units */
    v_ok := abs((v_metal2 / nullif(v_metal0, 0)) - ((30 * 10 * power(1.1, 10) + floor(30 * 10 * power(1.1, 10) * 0.0002 * 240))
                                                    / (30 * 10 * power(1.1, 10)))) < 0.0005
            and v_metal2 < v_metal1 * 1.06;
    insert into t_fc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. 1000 crawlers are capped at 240 effective units (ratio %s)', round(v_metal2 / nullif(v_metal0, 0), 6)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* crawler energy: 20 crawlers on a low-energy planet must throttle production (50 energy each) */
    delete from public.planet_ships where planet_id = v_planet;
    update public.planet_buildings set level = 8 where planet_id = v_planet and building_id = 'solar_plant';
    update public.planet_resources set deuterium = 1000000 where planet_id = v_planet;

    select pp.metal_per_hour into v_metal3 from public.calculate_planet_production(v_planet) pp;

    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_planet, 'crawler', 20)
    on conflict (planet_id, ship_id) do update set quantity = 20;

    select pp.metal_per_hour into v_metal1 from public.calculate_planet_production(v_planet) pp;

    v_ok := v_metal1 < v_metal3 * 0.6;
    insert into t_fc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. crawler energy (50 per effective unit) throttles production (%s -> %s)', v_metal3, v_metal1));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* kind gates: the crawler is planet-only, storages and the shipyard are legal on both kinds (OGameX) */
    delete from public.planet_ships where planet_id = v_planet;
    delete from public.planets m where m.parent_planet_id = v_planet;

    insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
        temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind, parent_planet_id, moon_diameter_km)
    select v_universe, v_player, 'Moon', p.galaxy, p.system, p.position, -20, 20, 10, 0, false, false,
           'MOON', p.id, 2000
      from public.planets p where p.id = v_planet;

    v_raised := null;
    begin
        insert into public.shipyard_queue(planet_id, ship_id, quantity, started_at, finishes_at, status)
        select m.id, 'crawler', 1, clock_timestamp(), clock_timestamp() + interval '1 minute', 'QUEUED'
          from public.planets m where m.parent_planet_id = v_planet;
    exception when others then
        v_raised := sqlerrm;
    end;

    v_ok := v_raised like 'SHIP_NOT_AVAILABLE_FOR_KIND%';
    insert into t_fc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. the crawler cannot be queued on a moon (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_raised := null;
    begin
        insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status)
        select m.id, 'metal_storage', 1, clock_timestamp(), clock_timestamp() + interval '1 hour', 'QUEUED'
          from public.planets m where m.parent_planet_id = v_planet;
    exception when others then
        v_raised := sqlerrm;
    end;

    v_ok := v_raised is null or v_raised not like 'BUILDING_NOT_AVAILABLE_FOR_KIND%';
    insert into t_fc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. storages stay legal on a moon (OGameX: empty valid_planet_types = both) (%s)',
             coalesce(v_raised, 'accepted')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_fc(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; concurrency not executed. Overload percentage of crawlers is not modelled (100 % = OGame default).');

    if v_fail > 0 then
        raise exception 'FUSION/CRAWLER FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_fc order by orden;

drop table if exists t_fc;

ROLLBACK;

