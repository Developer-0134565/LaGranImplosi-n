CREATE OR REPLACE FUNCTION public.update_planet_resources(p_planet_id uuid)
RETURNS TABLE(planet_id uuid, metal numeric, crystal numeric, deuterium numeric, energy numeric, elapsed_seconds numeric, metal_produced numeric, crystal_produced numeric, deuterium_produced numeric)
LANGUAGE plpgsql
AS $function$
DECLARE
    v_last_calculated_at timestamptz;
    v_now timestamptz := now();
    v_elapsed_seconds numeric;
    v_metal numeric;
    v_crystal numeric;
    v_deuterium numeric;
    v_energy numeric;
    v_metal_per_hour numeric;
    v_crystal_per_hour numeric;
    v_deuterium_per_hour numeric;
    v_energy_per_hour numeric;
    v_metal_produced numeric;
    v_crystal_produced numeric;
    v_deuterium_produced numeric;
    v_metal_capacity numeric;
    v_crystal_capacity numeric;
    v_deuterium_capacity numeric;
BEGIN
    SELECT pr.last_calculated_at, pr.metal, pr.crystal, pr.deuterium, pr.energy
    INTO v_last_calculated_at, v_metal, v_crystal, v_deuterium, v_energy
    FROM public.planet_resources AS pr
    WHERE pr.planet_id = p_planet_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe planet_resources para el planeta %', p_planet_id;
    END IF;

    v_elapsed_seconds := GREATEST(0, EXTRACT(EPOCH FROM (v_now - v_last_calculated_at)));

    SELECT pp.metal_per_hour, pp.crystal_per_hour, pp.deuterium_per_hour, pp.energy_per_hour
    INTO v_metal_per_hour, v_crystal_per_hour, v_deuterium_per_hour, v_energy_per_hour
    FROM public.calculate_planet_production(p_planet_id) AS pp;

    SELECT s.metal_capacity, s.crystal_capacity, s.deuterium_capacity
    INTO v_metal_capacity, v_crystal_capacity, v_deuterium_capacity
    FROM public.calculate_planet_storage(p_planet_id) AS s;

    v_metal_produced := v_metal_per_hour * v_elapsed_seconds / 3600.0;
    v_crystal_produced := v_crystal_per_hour * v_elapsed_seconds / 3600.0;
    v_deuterium_produced := v_deuterium_per_hour * v_elapsed_seconds / 3600.0;

    v_metal := LEAST(v_metal_capacity, GREATEST(0, v_metal + v_metal_produced));
    v_crystal := LEAST(v_crystal_capacity, GREATEST(0, v_crystal + v_crystal_produced));
    v_deuterium := LEAST(v_deuterium_capacity, GREATEST(0, v_deuterium + v_deuterium_produced));

    UPDATE public.planet_resources AS pr
    SET metal = v_metal, crystal = v_crystal, deuterium = v_deuterium,
        last_calculated_at = v_now, updated_at = v_now
    WHERE pr.planet_id = p_planet_id;

    planet_id := p_planet_id; metal := v_metal; crystal := v_crystal; deuterium := v_deuterium; energy := v_energy;
    elapsed_seconds := v_elapsed_seconds;
    metal_produced := v_metal_produced; crystal_produced := v_crystal_produced; deuterium_produced := v_deuterium_produced;
    RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_planet_resources_until(p_planet_id uuid, p_until timestamptz)
RETURNS TABLE(planet_id uuid, metal numeric, crystal numeric, deuterium numeric, energy numeric, elapsed_seconds numeric, metal_produced numeric, crystal_produced numeric, deuterium_produced numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
    v_energy_per_hour numeric;
    v_metal_produced numeric;
    v_crystal_produced numeric;
    v_deuterium_produced numeric;
    v_metal_capacity numeric;
    v_crystal_capacity numeric;
    v_deuterium_capacity numeric;
BEGIN
    SELECT pr.last_calculated_at, pr.metal, pr.crystal, pr.deuterium, pr.energy
    INTO v_last_calculated_at, v_metal, v_crystal, v_deuterium, v_energy
    FROM public.planet_resources AS pr
    WHERE pr.planet_id = p_planet_id
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'PLANET_RESOURCES_NOT_FOUND'; END IF;
    IF p_until < v_last_calculated_at THEN RAISE EXCEPTION 'INVALID_RESOURCE_TIMESTAMP'; END IF;

    v_elapsed_seconds := GREATEST(0, EXTRACT(EPOCH FROM (p_until - v_last_calculated_at)));

    SELECT pp.metal_per_hour, pp.crystal_per_hour, pp.deuterium_per_hour, pp.energy_per_hour
    INTO v_metal_per_hour, v_crystal_per_hour, v_deuterium_per_hour, v_energy_per_hour
    FROM public.calculate_planet_production(p_planet_id) AS pp;

    SELECT s.metal_capacity, s.crystal_capacity, s.deuterium_capacity
    INTO v_metal_capacity, v_crystal_capacity, v_deuterium_capacity
    FROM public.calculate_planet_storage(p_planet_id) AS s;

    v_metal_produced := v_metal_per_hour * v_elapsed_seconds / 3600.0;
    v_crystal_produced := v_crystal_per_hour * v_elapsed_seconds / 3600.0;
    v_deuterium_produced := v_deuterium_per_hour * v_elapsed_seconds / 3600.0;

    v_metal := LEAST(v_metal_capacity, GREATEST(0, v_metal + v_metal_produced));
    v_crystal := LEAST(v_crystal_capacity, GREATEST(0, v_crystal + v_crystal_produced));
    v_deuterium := LEAST(v_deuterium_capacity, GREATEST(0, v_deuterium + v_deuterium_produced));

    UPDATE public.planet_resources AS pr
    SET metal = v_metal, crystal = v_crystal, deuterium = v_deuterium,
        last_calculated_at = p_until, updated_at = now()
    WHERE pr.planet_id = p_planet_id;

    planet_id := p_planet_id; metal := v_metal; crystal := v_crystal; deuterium := v_deuterium; energy := v_energy;
    elapsed_seconds := v_elapsed_seconds;
    metal_produced := v_metal_produced; crystal_produced := v_crystal_produced; deuterium_produced := v_deuterium_produced;
    RETURN NEXT;
END;
$function$;