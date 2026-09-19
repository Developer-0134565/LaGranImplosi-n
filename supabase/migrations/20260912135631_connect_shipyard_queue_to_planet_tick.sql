CREATE OR REPLACE FUNCTION public.process_planet_tick(p_planet_id uuid)
RETURNS TABLE(
    planet_id uuid,
    metal numeric,
    crystal numeric,
    deuterium numeric,
    energy numeric,
    buildings_completed integer,
    researches_completed integer
)
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

    -- El astillero forma parte del mismo tick económico del planeta.
    -- La función es idempotente mediante status + SKIP LOCKED.
    PERFORM public.process_shipyard_queue()
    WHERE EXISTS (
        SELECT 1
        FROM public.shipyard_queue sq
        WHERE sq.planet_id = p_planet_id
          AND sq.status = 'BUILDING'
          AND sq.finishes_at <= now()
    );

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