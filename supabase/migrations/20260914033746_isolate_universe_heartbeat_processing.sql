CREATE OR REPLACE FUNCTION public.process_universe_heartbeat()
RETURNS TABLE(universes_processed integer, total_ticks_executed integer, systems_expanded integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_universe RECORD;
    v_clock RECORD;
    v_expansion RECORD;
    v_universes integer := 0;
    v_ticks integer := 0;
    v_systems integer := 0;
BEGIN
    FOR v_universe IN
        SELECT id
        FROM public.universes
        WHERE is_active = true
        ORDER BY created_at, id
    LOOP
        -- A test/legacy universe must never be able to abort production processing.
        -- The clock is independent; expansion state is required only for galaxy/system evolution.
        SELECT *
        INTO v_clock
        FROM public.process_universe_clock(v_universe.id);

        v_universes := v_universes + 1;
        v_ticks := v_ticks + COALESCE(v_clock.ticks_executed, 0);

        IF EXISTS (
            SELECT 1
            FROM public.universe_expansion_state
            WHERE universe_id = v_universe.id
        ) THEN
            PERFORM public.process_universe_galaxy_roll(v_universe.id);
            SELECT *
            INTO v_expansion
            FROM public.process_universe_system_expansion(v_universe.id);

            v_systems := v_systems + COALESCE(v_expansion.systems_expanded, 0);
        END IF;
    END LOOP;

    RETURN QUERY
    SELECT v_universes, v_ticks, v_systems;
END;
$function$;