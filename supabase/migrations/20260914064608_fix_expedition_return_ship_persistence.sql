CREATE OR REPLACE FUNCTION public.resolve_expedition_return(p_fleet_id uuid)
RETURNS TABLE(fleet_id uuid, origin_planet_id uuid, delivered_metal numeric, delivered_crystal numeric, delivered_deuterium numeric, status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_fleet RECORD;
BEGIN
    SELECT fm.id, fm.origin_planet_id, fm.mission_type, fm.status,
           fm.metal, fm.crystal, fm.deuterium
    INTO v_fleet
    FROM public.fleet_movements fm
    WHERE fm.id = p_fleet_id
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'Fleet not found: %', p_fleet_id; END IF;
    IF v_fleet.mission_type <> 'EXPEDITION' THEN RAISE EXCEPTION 'Fleet is not an EXPEDITION'; END IF;
    IF v_fleet.status <> 'RETURNING' THEN RAISE EXCEPTION 'Expedition must be RETURNING. Current status: %', v_fleet.status; END IF;

    PERFORM public.update_planet_resources_until(v_fleet.origin_planet_id, now());

    INSERT INTO public.planet_ships(planet_id, ship_id, quantity)
    SELECT v_fleet.origin_planet_id, fms.ship_id, fms.quantity
    FROM public.fleet_movement_ships fms
    WHERE fms.fleet_id = p_fleet_id
    ON CONFLICT(planet_id, ship_id)
    DO UPDATE SET quantity = public.planet_ships.quantity + EXCLUDED.quantity;

    UPDATE public.planet_resources pr
    SET metal = pr.metal + v_fleet.metal,
        crystal = pr.crystal + v_fleet.crystal,
        deuterium = pr.deuterium + v_fleet.deuterium,
        updated_at = now()
    WHERE pr.planet_id = v_fleet.origin_planet_id;

    IF NOT FOUND THEN RAISE EXCEPTION 'Origin planet resources not found'; END IF;

    UPDATE public.fleet_movements
    SET metal = 0, crystal = 0, deuterium = 0, status = 'COMPLETED'
    WHERE id = p_fleet_id AND status = 'RETURNING';

    fleet_id := v_fleet.id;
    origin_planet_id := v_fleet.origin_planet_id;
    delivered_metal := v_fleet.metal;
    delivered_crystal := v_fleet.crystal;
    delivered_deuterium := v_fleet.deuterium;
    status := 'COMPLETED';
    RETURN NEXT;
END;
$function$;