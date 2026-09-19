CREATE OR REPLACE FUNCTION public.load_fleet_cargo(p_fleet_id uuid, p_metal numeric DEFAULT 0, p_crystal numeric DEFAULT 0, p_deuterium numeric DEFAULT 0)
RETURNS TABLE(fleet_id uuid, metal numeric, crystal numeric, deuterium numeric, total_cargo numeric, cargo_capacity numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_fleet RECORD;
    v_resources RECORD;
    v_capacity numeric;
    v_total numeric;
BEGIN
    IF p_metal < 0 OR p_crystal < 0 OR p_deuterium < 0 THEN
        RAISE EXCEPTION 'Cargo cannot be negative';
    END IF;

    SELECT fm.id, fm.origin_planet_id, fm.status
    INTO v_fleet
    FROM public.fleet_movements fm
    WHERE fm.id = p_fleet_id
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'Fleet not found'; END IF;
    IF v_fleet.status <> 'OUTBOUND' THEN
        RAISE EXCEPTION 'Cargo can only be loaded while fleet is OUTBOUND';
    END IF;

    -- Resources must be settled through the current instant before validating
    -- or removing cargo. Otherwise a stale planet_resources row can reject a
    -- valid load or allow the caller to reason about obsolete balances.
    PERFORM public.update_planet_resources_until(v_fleet.origin_planet_id, now());

    v_capacity := public.calculate_fleet_cargo_capacity(p_fleet_id);
    v_total := p_metal + p_crystal + p_deuterium;
    IF v_total > v_capacity THEN
        RAISE EXCEPTION 'Cargo exceeds fleet capacity: % / %', v_total, v_capacity;
    END IF;

    SELECT pr.metal, pr.crystal, pr.deuterium
    INTO v_resources
    FROM public.planet_resources pr
    WHERE pr.planet_id = v_fleet.origin_planet_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Planet resources not found'; END IF;

    IF v_resources.metal < p_metal THEN RAISE EXCEPTION 'Insufficient metal'; END IF;
    IF v_resources.crystal < p_crystal THEN RAISE EXCEPTION 'Insufficient crystal'; END IF;
    IF v_resources.deuterium < p_deuterium THEN RAISE EXCEPTION 'Insufficient deuterium'; END IF;

    UPDATE public.planet_resources pr
    SET metal = pr.metal - p_metal,
        crystal = pr.crystal - p_crystal,
        deuterium = pr.deuterium - p_deuterium,
        updated_at = now()
    WHERE pr.planet_id = v_fleet.origin_planet_id;

    UPDATE public.fleet_movements fm
    SET metal = fm.metal + p_metal,
        crystal = fm.crystal + p_crystal,
        deuterium = fm.deuterium + p_deuterium
    WHERE fm.id = p_fleet_id;

    RETURN QUERY
    SELECT fm.id, fm.metal, fm.crystal, fm.deuterium,
           fm.metal + fm.crystal + fm.deuterium, v_capacity
    FROM public.fleet_movements fm
    WHERE fm.id = p_fleet_id;
END;
$function$;