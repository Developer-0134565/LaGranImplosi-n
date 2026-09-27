-- ENERGY TECHNOLOGY PRODUCTION FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- LGI gameplay rule (GAMEPLAY 01B — decided by LGI, NOT the OGameX Fusion Reactor formula):
--   energy_output = floor(20 * solar_level * 1.1^solar_level * (1 + lifeform_energy/100)
--                         * (1 + 0.05 * energy_technology))
-- applied EXACTLY ONCE inside calculate_planet_production, using the level of the OWNING
-- player through get_player_research_level (no global / first-player / guest fallback).
--
-- Expected values are recomputed with the same public helper chain the engine uses
-- (get_active_lifeform_research_effect + get_planet_lifeform_building_effect), so the
-- assertions are exact — including the floor() the engine applies to the total.

begin;

drop table if exists t_energy_results;
create temp table t_energy_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_planet_a uuid;
    v_planet_b uuid;
    v_player_a uuid;
    v_player_b uuid;
    v_solar_a integer;
    v_solar_b integer;
    v_lf_a numeric;
    v_lf_b numeric;
    v_raw_a numeric;
    v_raw_b numeric;
    v_energy_lvl0 numeric;
    v_energy_lvl1 numeric;
    v_energy_lvl10 numeric;
    v_energy_lvl20 numeric;
    v_owner_a numeric;
    v_owner_b numeric;
    v_balance_production numeric;
    v_balance_consumption numeric;
    v_balance numeric;
    v_removed integer;
    v_ok boolean;
    v_fail integer := 0;
begin
    SELECT p.id, p.player_id
      INTO v_planet_a, v_player_a
      FROM public.planets p
     WHERE p.is_destroyed = false
     ORDER BY p.created_at, p.id
     LIMIT 1;

    SELECT p.id, p.player_id
      INTO v_planet_b, v_player_b
      FROM public.planets p
     WHERE p.is_destroyed = false
       AND p.player_id <> v_player_a
     ORDER BY p.created_at, p.id
     LIMIT 1;

    IF v_planet_a IS NULL OR v_planet_b IS NULL THEN
        RAISE EXCEPTION 'TEST_ABORT: se necesitan dos planetas de propietarios distintos';
    END IF;

    INSERT INTO public.planet_buildings(planet_id, building_id, level)
    VALUES
      (v_planet_a, 'solar_plant', 20),
      (v_planet_a, 'metal_mine', 0),
      (v_planet_a, 'crystal_mine', 0),
      (v_planet_a, 'deuterium_synthesizer', 0),
      (v_planet_b, 'solar_plant', 20),
      (v_planet_b, 'metal_mine', 0),
      (v_planet_b, 'crystal_mine', 0),
      (v_planet_b, 'deuterium_synthesizer', 0)
    ON CONFLICT (planet_id, building_id) DO UPDATE SET level = EXCLUDED.level;

    DELETE FROM public.player_research
     WHERE player_id IN (v_player_a, v_player_b)
       AND research_id = 'energy_technology';
    GET DIAGNOSTICS v_removed = ROW_COUNT;

    SELECT level INTO v_solar_a FROM public.planet_buildings
     WHERE planet_id = v_planet_a AND building_id = 'solar_plant';
    SELECT level INTO v_solar_b FROM public.planet_buildings
     WHERE planet_id = v_planet_b AND building_id = 'solar_plant';

    v_lf_a := COALESCE(public.get_active_lifeform_research_effect(v_player_a, 'energy_percent'), 0)
            + COALESCE(public.get_planet_lifeform_building_effect(v_planet_a, 'energy_percent'), 0);
    v_lf_b := COALESCE(public.get_active_lifeform_research_effect(v_player_b, 'energy_percent'), 0)
            + COALESCE(public.get_planet_lifeform_building_effect(v_planet_b, 'energy_percent'), 0);

    /* the certified pre-patch energy expression (technology factor = 1.00) */
    v_raw_a := 20 * v_solar_a * power(1.1, v_solar_a) * (1 + v_lf_a / 100);
    v_raw_b := 20 * v_solar_b * power(1.1, v_solar_b) * (1 + v_lf_b / 100);

    /* TEST 1 — level 0 (no row at all): factor 1.00, pre-patch value preserved */
    SELECT energy_per_hour INTO v_energy_lvl0 FROM public.calculate_planet_production(v_planet_a);
    v_ok := v_energy_lvl0 = floor(v_raw_a);
    INSERT INTO t_energy_results(resultado, prueba) VALUES (
      CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
      format('1. level 0 -> base x 1.00 (%s = floor(%s)); energy_technology rows removed = %s',
             v_energy_lvl0, v_raw_a, v_removed));
    v_fail := v_fail + CASE WHEN v_ok THEN 0 ELSE 1 END;

    /* TEST 2 — level 1 -> x 1.05 */
    INSERT INTO public.player_research(player_id, research_id, level)
    VALUES (v_player_a, 'energy_technology', 1);

    SELECT energy_per_hour INTO v_energy_lvl1 FROM public.calculate_planet_production(v_planet_a);
    v_ok := v_energy_lvl1 = floor(v_raw_a * 1.05);
    INSERT INTO t_energy_results(resultado, prueba) VALUES (
      CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
      format('2. level 1 -> x 1.05 (%s = floor(%s))', v_energy_lvl1, v_raw_a * 1.05));
    v_fail := v_fail + CASE WHEN v_ok THEN 0 ELSE 1 END;

    /* TEST 3 — level 10 -> x 1.50 */
    UPDATE public.player_research SET level = 10
     WHERE player_id = v_player_a AND research_id = 'energy_technology';

    SELECT energy_per_hour INTO v_energy_lvl10 FROM public.calculate_planet_production(v_planet_a);
    v_ok := v_energy_lvl10 = floor(v_raw_a * 1.50);
    INSERT INTO t_energy_results(resultado, prueba) VALUES (
      CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
      format('3. level 10 -> x 1.50 (%s = floor(%s))', v_energy_lvl10, v_raw_a * 1.50));
    v_fail := v_fail + CASE WHEN v_ok THEN 0 ELSE 1 END;

    /* TEST 5 — single application: 1.50x here, never 1.50 x 1.50 */
    v_ok := v_energy_lvl10 = floor(v_raw_a * 1.50) AND v_energy_lvl10 <> floor(v_raw_a * 2.25);
    INSERT INTO t_energy_results(resultado, prueba) VALUES (
      CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
      format('5. single application (%s = 1.50x and <> 2.25x = %s)', v_energy_lvl10, floor(v_raw_a * 2.25)));
    v_fail := v_fail + CASE WHEN v_ok THEN 0 ELSE 1 END;

    /* TEST 4 — level 20 -> x 2.00 */
    UPDATE public.player_research SET level = 20
     WHERE player_id = v_player_a AND research_id = 'energy_technology';

    SELECT energy_per_hour INTO v_energy_lvl20 FROM public.calculate_planet_production(v_planet_a);
    v_ok := v_energy_lvl20 = floor(v_raw_a * 2.00);
    INSERT INTO t_energy_results(resultado, prueba) VALUES (
      CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
      format('4. level 20 -> x 2.00 (%s = floor(%s))', v_energy_lvl20, v_raw_a * 2.00));
    v_fail := v_fail + CASE WHEN v_ok THEN 0 ELSE 1 END;

    /* TEST 6 — owner routing: A = 10, B = 0 (no global fallback) */
    UPDATE public.player_research SET level = 10
     WHERE player_id = v_player_a AND research_id = 'energy_technology';
    INSERT INTO public.player_research(player_id, research_id, level)
    VALUES (v_player_b, 'energy_technology', 0)
    ON CONFLICT (player_id, research_id) DO UPDATE SET level = 0;

    SELECT energy_per_hour INTO v_owner_a FROM public.calculate_planet_production(v_planet_a);
    SELECT energy_per_hour INTO v_owner_b FROM public.calculate_planet_production(v_planet_b);
    v_ok := v_owner_a = floor(v_raw_a * 1.50)
        AND v_owner_b = floor(v_raw_b * 1.00)
        AND v_owner_b <> floor(v_raw_b * 1.50)
        AND v_owner_a > v_owner_b;
    INSERT INTO t_energy_results(resultado, prueba) VALUES (
      CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
      format('6. owner routing: A(lvl 10) = %s, B(lvl 0) = %s (B must not inherit A = %s)',
             v_owner_a, v_owner_b, floor(v_raw_b * 1.50)));
    v_fail := v_fail + CASE WHEN v_ok THEN 0 ELSE 1 END;

    /* TEST 7 — regression: level 0 keeps the certified pre-patch value, and the energy
       balance passes the BOOSTED production through exactly once (no double application) */
    SELECT energy_production_per_hour, energy_consumption_per_hour, energy_balance_per_hour
      INTO v_balance_production, v_balance_consumption, v_balance
      FROM public.calculate_planet_energy_balance(v_planet_a);

    v_ok := v_owner_b = floor(v_raw_b)
        AND v_balance_production = v_owner_a
        AND v_balance = v_balance_production - v_balance_consumption;
    INSERT INTO t_energy_results(resultado, prueba) VALUES (
      CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
      format('7. regression + balance single pass (level 0 = %s; balance production %s = production %s)',
             v_owner_b, v_balance_production, v_owner_a));
    v_fail := v_fail + CASE WHEN v_ok THEN 0 ELSE 1 END;

    IF v_fail > 0 THEN
        RAISE EXCEPTION 'ENERGY TECHNOLOGY FIXTURE: % failed assertion(s)', v_fail;
    END IF;
END;
$test$;

select orden, resultado, prueba from t_energy_results order by orden;

drop table if exists t_energy_results;

ROLLBACK;
