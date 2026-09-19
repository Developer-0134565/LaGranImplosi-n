CREATE OR REPLACE FUNCTION public.process_shipyard_queue(p_planet_id uuid)
RETURNS TABLE(queue_id uuid, ship_id text, quantity bigint, status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
    v_queue RECORD;
BEGIN
    FOR v_queue IN
        SELECT
            sq.id,
            sq.planet_id,
            sq.ship_id AS queued_ship_id,
            sq.quantity AS queued_quantity,
            sq.finishes_at
        FROM public.shipyard_queue AS sq
        WHERE sq.planet_id = p_planet_id
          AND sq.status = 'BUILDING'
          AND sq.finishes_at <= now()
        ORDER BY sq.created_at
        FOR UPDATE SKIP LOCKED
    LOOP
        INSERT INTO public.planet_ships AS ps (planet_id, ship_id, quantity)
        VALUES (v_queue.planet_id, v_queue.queued_ship_id, v_queue.queued_quantity)
        ON CONFLICT ON CONSTRAINT planet_ships_pkey
        DO UPDATE SET quantity = ps.quantity + EXCLUDED.quantity;

        UPDATE public.shipyard_queue AS sq
        SET status = 'COMPLETED'
        WHERE sq.id = v_queue.id
          AND sq.status = 'BUILDING';

        queue_id := v_queue.id;
        ship_id := v_queue.queued_ship_id;
        quantity := v_queue.queued_quantity;
        status := 'COMPLETED';
        RETURN NEXT;
    END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_planet_tick(p_planet_id uuid)
RETURNS TABLE(planet_id uuid, metal numeric, crystal numeric, deuterium numeric, energy numeric, buildings_completed integer, researches_completed integer)
LANGUAGE plpgsql
AS $function$
DECLARE
    v_metal numeric;
    v_crystal numeric;
    v_deuterium numeric;
    v_energy numeric;
    v_buildings_completed integer := 0;
    v_researches_completed integer := 0;
BEGIN
    SELECT r.metal, r.crystal, r.deuterium, r.energy
    INTO v_metal, v_crystal, v_deuterium, v_energy
    FROM public.update_planet_resources(p_planet_id) r;

    PERFORM public.process_lifeform_tick(p_planet_id);

    SELECT COUNT(*)
    INTO v_buildings_completed
    FROM public.process_building_queue() b
    WHERE b.planet_id = p_planet_id;

    SELECT COUNT(*)
    INTO v_researches_completed
    FROM public.process_research_queue() r
    WHERE r.player_id = (
        SELECT p.player_id
        FROM public.planets p
        WHERE p.id = p_planet_id
    );

    PERFORM public.process_shipyard_queue(p_planet_id);

    RETURN QUERY
    SELECT
        p_planet_id,
        v_metal,
        v_crystal,
        v_deuterium,
        v_energy,
        v_buildings_completed,
        v_researches_completed;
END;
$function$;