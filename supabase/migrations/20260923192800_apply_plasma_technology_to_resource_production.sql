-- GAMEPLAY - Plasma Technology -> economic production (LGI rule)
--
-- Evidence basis (no LGI rule existed before this migration; see README_ECONOMY):
--   * the classic OGame rule, documented inside this repository's own reference snapshot
--     template/investigaciones.txt ("optimiza la produccion de metal, cristal y deuterio
--     (1% / 0,66% / 0,33% por nivel)");
--   * LGI's plasma_technology data lineage is OGame-classic (cost 2000/4000/1000 with
--     factor 2, plasma_turret 3000/300/10000 requiring plasma 7 + energy 8 + shipyard 8,
--     bomber requiring plasma 5);
--   * no contradictory LGI contract: zero code readers of 'plasma_technology', no economic
--     statement in research_definitions, no migration/doc/history ever implementing one.
--
-- Rule (LGI):
--   metal     : +1.00 % per level
--   crystal   : +0.66 % per level
--   deuterium : +0.33 % per level
--   energy    : NOT modified (Energy Technology is the only energy-production modifier)
--
-- Applied exactly once, in the single authoritative production function, using the level of
-- the OWNING player through get_player_research_level (COALESCE -> 0, same pattern as
-- Energy Technology). No rounding is introduced for metal/crystal/deuterium: the factors are
-- plain numeric multipliers on outputs that were never floored, so level 0 keeps the previous
-- production byte-identical (and any floor() would break that). The factor multiplies the
-- energy-factor-adjusted term; the order is mathematically irrelevant because the energy
-- factor does not depend on plasma.

CREATE OR REPLACE FUNCTION public.calculate_planet_production(p_planet_id uuid)
RETURNS TABLE(metal_per_hour numeric, crystal_per_hour numeric, deuterium_per_hour numeric, energy_per_hour numeric)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_universe_id uuid;
  v_player_id uuid;
  v_metal_level integer := 0;
  v_crystal_level integer := 0;
  v_deuterium_level integer := 0;
  v_solar_level integer := 0;
  v_energy_technology_level integer := 0;
  v_plasma_technology_level integer := 0;
  v_economy_rate numeric;
  v_production_rate numeric;
  v_item_bonus numeric := 0;
  v_prod_bonus numeric := 0;
  v_metal_bonus numeric := 0;
  v_crystal_bonus numeric := 0;
  v_deut_bonus numeric := 0;
  v_energy_bonus numeric := 0;
  v_energy_production numeric := 0;
  v_energy_consumption numeric := 0;
  v_production_factor numeric := 1;
  v_plasma_metal_factor numeric := 1;
  v_plasma_crystal_factor numeric := 1;
  v_plasma_deuterium_factor numeric := 1;
BEGIN
  SELECT p.universe_id, p.player_id INTO v_universe_id, v_player_id
  FROM public.planets p WHERE p.id = p_planet_id;
  IF v_universe_id IS NULL THEN RAISE EXCEPTION 'Planet % does not exist', p_planet_id; END IF;

  SELECT r.economy, r.production INTO v_economy_rate, v_production_rate
  FROM public.calculate_universe_rates(v_universe_id) r;

  SELECT
    COALESCE(MAX(level) FILTER (WHERE building_id = 'metal_mine'), 0),
    COALESCE(MAX(level) FILTER (WHERE building_id = 'crystal_mine'), 0),
    COALESCE(MAX(level) FILTER (WHERE building_id = 'deuterium_synthesizer'), 0),
    COALESCE(MAX(level) FILTER (WHERE building_id = 'solar_plant'), 0),
    COALESCE(SUM(public.calculate_building_energy_consumption(building_id, level)), 0)
  INTO v_metal_level, v_crystal_level, v_deuterium_level, v_solar_level, v_energy_consumption
  FROM public.planet_buildings
  WHERE planet_id = p_planet_id;

  v_item_bonus := COALESCE(public.get_active_expedition_item_effect(v_player_id, p_planet_id, 'production_percent'), 0);
  v_prod_bonus := COALESCE(public.get_active_lifeform_research_effect(v_player_id, 'production_percent'), 0);
  v_metal_bonus := COALESCE(public.get_active_lifeform_research_effect(v_player_id, 'metal_production_percent'), 0) + COALESCE(public.get_planet_lifeform_building_effect(p_planet_id, 'metal_production_percent'), 0);
  v_crystal_bonus := COALESCE(public.get_active_lifeform_research_effect(v_player_id, 'crystal_production_percent'), 0) + COALESCE(public.get_planet_lifeform_building_effect(p_planet_id, 'crystal_production_percent'), 0);
  v_deut_bonus := COALESCE(public.get_active_lifeform_research_effect(v_player_id, 'deuterium_production_percent'), 0) + COALESCE(public.get_planet_lifeform_building_effect(p_planet_id, 'deuterium_production_percent'), 0);
  v_energy_bonus := COALESCE(public.get_active_lifeform_research_effect(v_player_id, 'energy_percent'), 0) + COALESCE(public.get_planet_lifeform_building_effect(p_planet_id, 'energy_percent'), 0);
  v_energy_technology_level := COALESCE(public.get_player_research_level(v_player_id, 'energy_technology'), 0);
  v_plasma_technology_level := COALESCE(public.get_player_research_level(v_player_id, 'plasma_technology'), 0);

  v_plasma_metal_factor := 1 + 0.01 * v_plasma_technology_level;
  v_plasma_crystal_factor := 1 + 0.0066 * v_plasma_technology_level;
  v_plasma_deuterium_factor := 1 + 0.0033 * v_plasma_technology_level;

  v_energy_production := floor(
    20 * v_solar_level * power(1.1, v_solar_level)
    * (1 + v_energy_bonus / 100)
    * (1 + 0.05 * v_energy_technology_level)
  );

  IF v_energy_consumption > 0 THEN
    v_production_factor := GREATEST(0, LEAST(1, v_energy_production / v_energy_consumption));
  END IF;

  RETURN QUERY SELECT
    30 * v_metal_level * power(1.1, v_metal_level) * v_economy_rate * v_production_rate * (1 + (v_item_bonus + v_prod_bonus + v_metal_bonus) / 100) * v_production_factor * v_plasma_metal_factor,
    20 * v_crystal_level * power(1.1, v_crystal_level) * v_economy_rate * v_production_rate * (1 + (v_item_bonus + v_prod_bonus + v_crystal_bonus) / 100) * v_production_factor * v_plasma_crystal_factor,
    10 * v_deuterium_level * power(1.1, v_deuterium_level) * v_economy_rate * v_production_rate * (1 + (v_item_bonus + v_prod_bonus + v_deut_bonus) / 100) * v_production_factor * v_plasma_deuterium_factor,
    v_energy_production;
END;
$function$;
