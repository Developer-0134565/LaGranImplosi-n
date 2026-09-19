CREATE OR REPLACE FUNCTION public.calculate_planet_energy_production_factor(p_planet_id uuid)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_energy_production numeric;
  v_energy_consumption numeric;
BEGIN
  SELECT pp.energy_per_hour INTO v_energy_production
  FROM public.calculate_planet_production(p_planet_id) pp;

  SELECT COALESCE(SUM(public.calculate_building_energy_consumption(pb.building_id, pb.level)), 0)
    INTO v_energy_consumption
  FROM public.planet_buildings pb
  WHERE pb.planet_id = p_planet_id;

  IF v_energy_consumption <= 0 THEN
    RETURN 1;
  END IF;

  RETURN GREATEST(0, LEAST(1, v_energy_production / v_energy_consumption));
END;
$function$;