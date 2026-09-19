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
BEGIN
  SELECT p.universe_id, p.player_id INTO v_universe_id, v_player_id
  FROM public.planets p WHERE p.id = p_planet_id;
  IF v_universe_id IS NULL THEN RAISE EXCEPTION 'Planet % does not exist', p_planet_id; END IF;

  SELECT r.economy, r.production INTO v_economy_rate, v_production_rate
  FROM public.calculate_universe_rates(v_universe_id) r;

  SELECT COALESCE(MAX(level), 0) INTO v_metal_level FROM public.planet_buildings WHERE planet_id = p_planet_id AND building_id = 'metal_mine';
  SELECT COALESCE(MAX(level), 0) INTO v_crystal_level FROM public.planet_buildings WHERE planet_id = p_planet_id AND building_id = 'crystal_mine';
  SELECT COALESCE(MAX(level), 0) INTO v_deuterium_level FROM public.planet_buildings WHERE planet_id = p_planet_id AND building_id = 'deuterium_synthesizer';
  SELECT COALESCE(MAX(level), 0) INTO v_solar_level FROM public.planet_buildings WHERE planet_id = p_planet_id AND building_id = 'solar_plant';

  v_item_bonus := COALESCE(public.get_active_expedition_item_effect(v_player_id, p_planet_id, 'production_percent'), 0);
  v_prod_bonus := COALESCE(public.get_active_lifeform_research_effect(v_player_id, 'production_percent'), 0);
  v_metal_bonus := COALESCE(public.get_active_lifeform_research_effect(v_player_id, 'metal_production_percent'), 0) + COALESCE(public.get_planet_lifeform_building_effect(p_planet_id, 'metal_production_percent'), 0);
  v_crystal_bonus := COALESCE(public.get_active_lifeform_research_effect(v_player_id, 'crystal_production_percent'), 0) + COALESCE(public.get_planet_lifeform_building_effect(p_planet_id, 'crystal_production_percent'), 0);
  v_deut_bonus := COALESCE(public.get_active_lifeform_research_effect(v_player_id, 'deuterium_production_percent'), 0) + COALESCE(public.get_planet_lifeform_building_effect(p_planet_id, 'deuterium_production_percent'), 0);
  v_energy_bonus := COALESCE(public.get_active_lifeform_research_effect(v_player_id, 'energy_percent'), 0) + COALESCE(public.get_planet_lifeform_building_effect(p_planet_id, 'energy_percent'), 0);

  -- Energy production is independent of universe economy/resource-production speed.
  v_energy_production := floor(20 * v_solar_level * power(1.1, v_solar_level) * (1 + v_energy_bonus / 100));

  SELECT COALESCE(SUM(public.calculate_building_energy_consumption(pb.building_id, pb.level)), 0)
    INTO v_energy_consumption
  FROM public.planet_buildings pb WHERE pb.planet_id = p_planet_id;

  IF v_energy_consumption > 0 THEN
    v_production_factor := GREATEST(0, LEAST(1, v_energy_production / v_energy_consumption));
  END IF;

  RETURN QUERY SELECT
    30 * v_metal_level * power(1.1, v_metal_level) * v_economy_rate * v_production_rate * (1 + (v_item_bonus + v_prod_bonus + v_metal_bonus) / 100) * v_production_factor,
    20 * v_crystal_level * power(1.1, v_crystal_level) * v_economy_rate * v_production_rate * (1 + (v_item_bonus + v_prod_bonus + v_crystal_bonus) / 100) * v_production_factor,
    10 * v_deuterium_level * power(1.1, v_deuterium_level) * v_economy_rate * v_production_rate * (1 + (v_item_bonus + v_prod_bonus + v_deut_bonus) / 100) * v_production_factor,
    v_energy_production;
END;
$function$;