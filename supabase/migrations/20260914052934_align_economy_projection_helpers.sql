CREATE OR REPLACE FUNCTION public.calculate_planet_production_snapshot(
    p_planet_id uuid,
    p_economy_rate numeric,
    p_production_rate numeric
)
RETURNS TABLE(
    metal_per_hour numeric,
    crystal_per_hour numeric,
    deuterium_per_hour numeric,
    energy_per_hour numeric
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_metal integer;
    v_crystal integer;
    v_deuterium integer;
    v_solar integer;
    v_energy_production numeric;
BEGIN
    SELECT COALESCE(MAX(level), 0) INTO v_metal
    FROM public.planet_buildings
    WHERE planet_id = p_planet_id AND building_id = 'metal_mine';

    SELECT COALESCE(MAX(level), 0) INTO v_crystal
    FROM public.planet_buildings
    WHERE planet_id = p_planet_id AND building_id = 'crystal_mine';

    SELECT COALESCE(MAX(level), 0) INTO v_deuterium
    FROM public.planet_buildings
    WHERE planet_id = p_planet_id AND building_id = 'deuterium_synthesizer';

    SELECT COALESCE(MAX(level), 0) INTO v_solar
    FROM public.planet_buildings
    WHERE planet_id = p_planet_id AND building_id = 'solar_plant';

    metal_per_hour := 30 * v_metal * power(1.1, v_metal) * p_economy_rate * p_production_rate;
    crystal_per_hour := 20 * v_crystal * power(1.1, v_crystal) * p_economy_rate * p_production_rate;
    deuterium_per_hour := 10 * v_deuterium * power(1.1, v_deuterium) * p_economy_rate * p_production_rate;

    -- Energy is a resource balance, not an economy/production-rate output.
    -- Keep this helper consistent with calculate_planet_production().
    v_energy_production := floor(20 * v_solar * power(1.1, v_solar));
    energy_per_hour := v_energy_production;

    RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_virtual_production(
    p_planet_id uuid,
    p_metal_level integer,
    p_crystal_level integer,
    p_deuterium_level integer,
    p_solar_level integer,
    p_economy_rate numeric,
    p_production_rate numeric
)
RETURNS TABLE(
    metal_per_hour numeric,
    crystal_per_hour numeric,
    deuterium_per_hour numeric,
    energy_per_hour numeric
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF p_metal_level < 0
       OR p_crystal_level < 0
       OR p_deuterium_level < 0
       OR p_solar_level < 0 THEN
        RAISE EXCEPTION 'Los niveles virtuales no pueden ser negativos';
    END IF;

    metal_per_hour := 30 * p_metal_level * power(1.1, p_metal_level) * p_economy_rate * p_production_rate;
    crystal_per_hour := 20 * p_crystal_level * power(1.1, p_crystal_level) * p_economy_rate * p_production_rate;
    deuterium_per_hour := 10 * p_deuterium_level * power(1.1, p_deuterium_level) * p_economy_rate * p_production_rate;

    -- Energy follows the authoritative production engine and therefore does not
    -- inherit economy/production/evolution multipliers.
    energy_per_hour := floor(20 * p_solar_level * power(1.1, p_solar_level));

    RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_current_planet_resources(p_planet_id uuid)
RETURNS TABLE(
    planet_id uuid,
    metal numeric,
    crystal numeric,
    deuterium numeric,
    energy numeric,
    elapsed_seconds numeric,
    projected_metal numeric,
    projected_crystal numeric,
    projected_deuterium numeric
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_last_calculated_at timestamptz;
    v_metal numeric;
    v_crystal numeric;
    v_deuterium numeric;
    v_energy numeric;
    v_elapsed_seconds numeric;
    v_metal_per_hour numeric;
    v_crystal_per_hour numeric;
    v_deuterium_per_hour numeric;
    v_metal_capacity numeric;
    v_crystal_capacity numeric;
    v_deuterium_capacity numeric;
    v_now timestamptz := now();
BEGIN
    SELECT pr.last_calculated_at, pr.metal, pr.crystal, pr.deuterium, pr.energy
    INTO v_last_calculated_at, v_metal, v_crystal, v_deuterium, v_energy
    FROM public.planet_resources AS pr
    WHERE pr.planet_id = p_planet_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe planet_resources para el planeta %', p_planet_id;
    END IF;

    v_elapsed_seconds := GREATEST(0, EXTRACT(EPOCH FROM (v_now - v_last_calculated_at)));

    SELECT pp.metal_per_hour, pp.crystal_per_hour, pp.deuterium_per_hour
    INTO v_metal_per_hour, v_crystal_per_hour, v_deuterium_per_hour
    FROM public.calculate_planet_production(p_planet_id) AS pp;

    SELECT s.metal_capacity, s.crystal_capacity, s.deuterium_capacity
    INTO v_metal_capacity, v_crystal_capacity, v_deuterium_capacity
    FROM public.calculate_planet_storage(p_planet_id) AS s;

    planet_id := p_planet_id;
    metal := ROUND(v_metal, 6);
    crystal := ROUND(v_crystal, 6);
    deuterium := ROUND(v_deuterium, 6);
    energy := ROUND(v_energy, 6);
    elapsed_seconds := ROUND(v_elapsed_seconds, 6);

    projected_metal := ROUND(LEAST(
        v_metal_capacity,
        GREATEST(0, v_metal + v_metal_per_hour * v_elapsed_seconds / 3600.0)
    ), 6);

    projected_crystal := ROUND(LEAST(
        v_crystal_capacity,
        GREATEST(0, v_crystal + v_crystal_per_hour * v_elapsed_seconds / 3600.0)
    ), 6);

    projected_deuterium := ROUND(LEAST(
        v_deuterium_capacity,
        GREATEST(0, v_deuterium + v_deuterium_per_hour * v_elapsed_seconds / 3600.0)
    ), 6);

    RETURN NEXT;
END;
$function$;
