-- PLASMA TECHNOLOGY PRODUCTION FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- LGI gameplay rule (GAMEPLAY — Plasma Technology):
--   metal     : production × (1 + 0.01   × plasma_level)
--   crystal   : production × (1 + 0.0066 × plasma_level)
--   deuterium : production × (1 + 0.0033 × plasma_level)
--   energy    : NOT modified
-- applied EXACTLY ONCE in calculate_planet_production, using the level of the OWNING player
-- through get_player_research_level (COALESCE -> 0, plasma 0 = no row at all). No floor is
-- introduced for metal/crystal/deuterium (they were never floored), so level 0 stays
-- byte-identical to the previous behaviour; the energy factor is untouched and commutes with
-- the plasma factor.

begin;

drop table if exists t_plasma_results;
create temp table t_plasma_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_planet_a uuid; v_planet_b uuid;
    v_player_a uuid; v_player_b uuid;
    v_universe uuid;
    v_econ numeric; v_prod_rate numeric;
    v_item_a numeric; v_prod_b_a numeric; v_metal_b_a numeric; v_crystal_b_a numeric; v_deut_b_a numeric;
    v_energy_prod numeric; v_energy_cons numeric; v_factor numeric; v_factor_def numeric;
    v_exp_metal numeric; v_exp_crystal numeric; v_exp_deut numeric;
    v_m0_a numeric; v_c0_a numeric; v_d0_a numeric; v_e0_a numeric;
    v_m0_b numeric; v_c0_b numeric; v_d0_b numeric;
    v_m1 numeric; v_c1 numeric; v_d1 numeric;
    v_m5 numeric; v_c5 numeric; v_d5 numeric;
    v_m20 numeric; v_c20 numeric; v_d20 numeric; v_e20 numeric;
    v_m10a numeric; v_c10a numeric; v_d10a numeric;
    v_m10b numeric; v_c10b numeric; v_d10b numeric;
    v_md_m numeric; v_md_c numeric; v_md_d numeric;
    v_m0_a2 numeric; v_c0_a2 numeric; v_d0_a2 numeric;
    v_tol numeric := 0.000000001;
    v_ok boolean;
    v_fail integer := 0;
begin
    /* two planets with DIFFERENT owners (owner-routing scenario) */
    select p.id, p.player_id, p.universe_id into v_planet_a, v_player_a, v_universe
      from public.planets p where p.is_destroyed = false order by p.created_at, p.id limit 1;
    select p.id, p.player_id into v_planet_b, v_player_b
      from public.planets p
     where p.is_destroyed = false and p.player_id <> v_player_a
     order by p.created_at, p.id limit 1;

    if v_planet_a is null or v_planet_b is null then
        raise exception 'PLASMA_FIXTURE_ABORT: two planets with different owners are required';
    end if;

    /* deterministic economy: energy-positive (solar 20) with the three mines at 10 */
    insert into public.planet_buildings(planet_id, building_id, level)
    values
      (v_planet_a, 'solar_plant', 20), (v_planet_a, 'metal_mine', 10),
      (v_planet_a, 'crystal_mine', 10), (v_planet_a, 'deuterium_synthesizer', 10),
      (v_planet_b, 'solar_plant', 20), (v_planet_b, 'metal_mine', 10),
      (v_planet_b, 'crystal_mine', 10), (v_planet_b, 'deuterium_synthesizer', 10)
    on conflict (planet_id, building_id) do update set level = excluded.level;

    /* level 0 = no row at all: the authoritative reader must COALESCE to 0 */
    delete from public.player_research
     where player_id in (v_player_a, v_player_b) and research_id = 'plasma_technology';

    /* independent recomputation of the pre-patch (plasma 0) formula for planet A's owner */
    select r.economy, r.production into v_econ, v_prod_rate
      from public.calculate_universe_rates(v_universe) r;
    v_item_a      := coalesce(public.get_active_expedition_item_effect(v_player_a, v_planet_a, 'production_percent'), 0);
    v_prod_b_a    := coalesce(public.get_active_lifeform_research_effect(v_player_a, 'production_percent'), 0);
    v_metal_b_a   := coalesce(public.get_active_lifeform_research_effect(v_player_a, 'metal_production_percent'), 0)
                   + coalesce(public.get_planet_lifeform_building_effect(v_planet_a, 'metal_production_percent'), 0);
    v_crystal_b_a := coalesce(public.get_active_lifeform_research_effect(v_player_a, 'crystal_production_percent'), 0)
                   + coalesce(public.get_planet_lifeform_building_effect(v_planet_a, 'crystal_production_percent'), 0);
    v_deut_b_a    := coalesce(public.get_active_lifeform_research_effect(v_player_a, 'deuterium_production_percent'), 0)
                   + coalesce(public.get_planet_lifeform_building_effect(v_planet_a, 'deuterium_production_percent'), 0);

    select energy_production_per_hour, energy_consumption_per_hour into v_energy_prod, v_energy_cons
      from public.calculate_planet_energy_balance(v_planet_a);
    v_factor := case when v_energy_cons > 0 then greatest(0, least(1, v_energy_prod / v_energy_cons)) else 1 end;

    v_exp_metal   := 30 * 10 * power(1.1, 10) * v_econ * v_prod_rate * (1 + (v_item_a + v_prod_b_a + v_metal_b_a) / 100)   * v_factor;
    v_exp_crystal := 20 * 10 * power(1.1, 10) * v_econ * v_prod_rate * (1 + (v_item_a + v_prod_b_a + v_crystal_b_a) / 100) * v_factor;
    v_exp_deut    := 10 * 10 * power(1.1, 10) * v_econ * v_prod_rate * (1 + (v_item_a + v_prod_b_a + v_deut_b_a) / 100)    * v_factor;

    /* baselines with plasma level 0 */
    select metal_per_hour, crystal_per_hour, deuterium_per_hour, energy_per_hour
      into v_m0_a, v_c0_a, v_d0_a, v_e0_a from public.calculate_planet_production(v_planet_a);
    select metal_per_hour, crystal_per_hour, deuterium_per_hour
      into v_m0_b, v_c0_b, v_d0_b from public.calculate_planet_production(v_planet_b);

    /* TEST 1 — level 0 metal = previous production (independently recomputed) */
    v_ok := abs(v_m0_a - v_exp_metal) <= abs(v_exp_metal) * v_tol + v_tol;
    insert into t_plasma_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. level 0 metal = pre-patch formula (%s vs %s)', v_m0_a, v_exp_metal));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* TEST 12 — level 0 crystal */
    v_ok := abs(v_c0_a - v_exp_crystal) <= abs(v_exp_crystal) * v_tol + v_tol;
    insert into t_plasma_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('12. level 0 crystal = pre-patch formula (%s vs %s)', v_c0_a, v_exp_crystal));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* TEST 13 — level 0 deuterium */
    v_ok := abs(v_d0_a - v_exp_deut) <= abs(v_exp_deut) * v_tol + v_tol;
    insert into t_plasma_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('13. level 0 deuterium = pre-patch formula (%s vs %s)', v_d0_a, v_exp_deut));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* TEST 2 — level 1: +1% metal, +0.66% crystal, +0.33% deuterium */
    insert into public.player_research(player_id, research_id, level) values (v_player_a, 'plasma_technology', 1);
    select metal_per_hour, crystal_per_hour, deuterium_per_hour into v_m1, v_c1, v_d1
      from public.calculate_planet_production(v_planet_a);
    v_ok := abs(v_m1 - v_m0_a * 1.01)   <= abs(v_m0_a) * v_tol + v_tol
        and abs(v_c1 - v_c0_a * 1.0066) <= abs(v_c0_a) * v_tol + v_tol
        and abs(v_d1 - v_d0_a * 1.0033) <= abs(v_d0_a) * v_tol + v_tol;
    insert into t_plasma_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. level 1 -> metal x1.01 / crystal x1.0066 / deuterium x1.0033 (%s / %s / %s)', v_m1, v_c1, v_d1));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* TEST 3 — intermediate level 5 */
    update public.player_research set level = 5 where player_id = v_player_a and research_id = 'plasma_technology';
    select metal_per_hour, crystal_per_hour, deuterium_per_hour into v_m5, v_c5, v_d5
      from public.calculate_planet_production(v_planet_a);
    v_ok := abs(v_m5 - v_m0_a * 1.05)   <= abs(v_m0_a) * v_tol + v_tol
        and abs(v_c5 - v_c0_a * 1.033)  <= abs(v_c0_a) * v_tol + v_tol
        and abs(v_d5 - v_d0_a * 1.0165) <= abs(v_d0_a) * v_tol + v_tol;
    insert into t_plasma_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. level 5 -> metal x1.05 / crystal x1.033 / deuterium x1.0165 (%s / %s / %s)', v_m5, v_c5, v_d5));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* TEST 4 — high level 20 (no overflow, exact factors) */
    update public.player_research set level = 20 where player_id = v_player_a and research_id = 'plasma_technology';
    select metal_per_hour, crystal_per_hour, deuterium_per_hour, energy_per_hour into v_m20, v_c20, v_d20, v_e20
      from public.calculate_planet_production(v_planet_a);
    v_ok := abs(v_m20 - v_m0_a * 1.20)  <= abs(v_m0_a) * v_tol + v_tol
        and abs(v_c20 - v_c0_a * 1.132) <= abs(v_c0_a) * v_tol + v_tol
        and abs(v_d20 - v_d0_a * 1.066) <= abs(v_d0_a) * v_tol + v_tol;
    insert into t_plasma_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. level 20 -> metal x1.20 / crystal x1.132 / deuterium x1.066 (%s / %s / %s)', v_m20, v_c20, v_d20));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* TEST 8 — plasma does NOT modify energy */
    v_ok := v_e20 = v_e0_a;
    insert into t_plasma_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. energy untouched by plasma (level 0 = %s, level 20 = %s)', v_e0_a, v_e20));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* TEST 5/14 — single application: level 10 = 1.10 / 1.066 / 1.033, never squared */
    update public.player_research set level = 10 where player_id = v_player_a and research_id = 'plasma_technology';
    select metal_per_hour, crystal_per_hour, deuterium_per_hour into v_m10a, v_c10a, v_d10a
      from public.calculate_planet_production(v_planet_a);
    v_ok := abs(v_m10a - v_m0_a * 1.10)  <= abs(v_m0_a) * v_tol + v_tol
        and abs(v_c10a - v_c0_a * 1.066) <= abs(v_c0_a) * v_tol + v_tol
        and abs(v_d10a - v_d0_a * 1.033) <= abs(v_d0_a) * v_tol + v_tol
        and abs(v_m10a - v_m0_a * 1.21) > v_tol
        and abs(v_c10a - v_c0_a * 1.1356) > v_tol
        and abs(v_d10a - v_d0_a * 1.067089) > v_tol;
    insert into t_plasma_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. single application at level 10 (metal %s = 1.10x, never 1.21x)', v_m10a));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* TEST 6/7 — owner routing: B is at level 0 and must not inherit A's level 10 */
    insert into public.player_research(player_id, research_id, level) values (v_player_b, 'plasma_technology', 0)
      on conflict (player_id, research_id) do update set level = 0;
    select metal_per_hour, crystal_per_hour, deuterium_per_hour into v_m10b, v_c10b, v_d10b
      from public.calculate_planet_production(v_planet_b);
    v_ok := v_m10b = v_m0_b and v_c10b = v_c0_b and v_d10b = v_d0_b
        and abs(v_m10a / v_m0_a - 1.10) <= v_tol;
    insert into t_plasma_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6/7. owner routing: A(lvl 10) ratio %s; B(lvl 0) unchanged (%s / %s / %s)',
             round(v_m10a / v_m0_a, 6), v_m10b, v_c10b, v_d10b));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* TEST 10 — the factor multiplies the full numeric value: not floor(base) x factor */
    v_ok := (v_m0_a = floor(v_m0_a)) or (abs(v_m1 - floor(v_m0_a) * 1.01) > v_tol);
    insert into t_plasma_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. no floor introduced: base=%s, level 1=%s, floor(base)x1.01=%s', v_m0_a, v_m1, floor(v_m0_a) * 1.01));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* TEST 9 — coexistence with the energy_factor: force an energy deficit (solar 1) */
    update public.planet_buildings set level = 1 where planet_id = v_planet_a and building_id = 'solar_plant';
    select metal_per_hour, crystal_per_hour, deuterium_per_hour into v_md_m, v_md_c, v_md_d
      from public.calculate_planet_production(v_planet_a);          -- A still at plasma 10
    update public.player_research set level = 0 where player_id = v_player_a and research_id = 'plasma_technology';
    select metal_per_hour, crystal_per_hour, deuterium_per_hour into v_m0_a2, v_c0_a2, v_d0_a2
      from public.calculate_planet_production(v_planet_a);          -- same deficit, plasma 0
    select energy_production_per_hour, energy_consumption_per_hour into v_energy_prod, v_energy_cons
      from public.calculate_planet_energy_balance(v_planet_a);
    v_factor_def := case when v_energy_cons > 0 then greatest(0, least(1, v_energy_prod / v_energy_cons)) else 1 end;
    v_ok := v_factor_def < 1
        and abs(v_md_m / v_m0_a2 - 1.10)  <= v_tol
        and abs(v_md_c / v_c0_a2 - 1.066) <= v_tol
        and abs(v_md_d / v_d0_a2 - 1.033) <= v_tol;
    insert into t_plasma_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. energy_factor coexistence (factor=%s < 1): ratios %s / %s / %s', round(v_factor_def, 6),
             round(v_md_m / v_m0_a2, 6), round(v_md_c / v_c0_a2, 6), round(v_md_d / v_d0_a2, 6)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* TEST 14 — level 0 restores the pre-patch production after every scenario */
    update public.planet_buildings set level = 20 where planet_id = v_planet_a and building_id = 'solar_plant';
    select metal_per_hour, crystal_per_hour, deuterium_per_hour into v_m0_a2, v_c0_a2, v_d0_a2
      from public.calculate_planet_production(v_planet_a);
    v_ok := abs(v_m0_a2 - v_m0_a) <= abs(v_m0_a) * v_tol + v_tol
        and abs(v_c0_a2 - v_c0_a) <= abs(v_c0_a) * v_tol + v_tol
        and abs(v_d0_a2 - v_d0_a) <= abs(v_d0_a) * v_tol + v_tol
        and v_m10b = v_m0_b;
    insert into t_plasma_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('14. level 0 restores pre-patch production after all scenarios (%s / %s / %s)', v_m0_a2, v_c0_a2, v_d0_a2));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    if v_fail > 0 then
        raise exception 'PLASMA TECHNOLOGY FIXTURE: % failed assertion(s)', v_fail;
    end if;
end
$test$;

select orden, resultado, prueba from t_plasma_results order by orden;

drop table if exists t_plasma_results;

ROLLBACK;
