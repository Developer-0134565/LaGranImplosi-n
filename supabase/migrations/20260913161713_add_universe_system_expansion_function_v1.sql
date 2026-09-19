CREATE OR REPLACE FUNCTION public.process_universe_system_expansion(p_universe_id uuid)
RETURNS TABLE(
    systems_expanded integer,
    last_galaxy integer,
    last_system_count integer
)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_now timestamptz := now();
    v_galaxy public.universe_galaxies%ROWTYPE;
    v_interval_seconds numeric;
    v_next_expansion_at timestamptz;
    v_system_count integer;
    v_expanded integer := 0;
    v_last_galaxy integer := NULL;
    v_last_system_count integer := NULL;
    v_max_expansions integer := 100;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.universes
        WHERE id = p_universe_id
    ) THEN
        RAISE EXCEPTION 'Universe % does not exist', p_universe_id;
    END IF;

    WHILE v_expanded < v_max_expansions LOOP
        SELECT *
        INTO v_galaxy
        FROM public.universe_galaxies
        WHERE universe_id = p_universe_id
          AND next_system_expansion_at <= v_now
          AND system_count < 1000000000
        ORDER BY next_system_expansion_at ASC, galaxy ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 1;

        EXIT WHEN NOT FOUND;

        v_system_count := v_galaxy.system_count + 1;
        v_interval_seconds := CASE
            WHEN v_galaxy.is_special THEN
                GREATEST(
                    1,
                    v_galaxy.system_interval_seconds
                ) * GREATEST(
                    1,
                    v_galaxy.system_interval_growth_factor
                )
            ELSE
                v_galaxy.system_interval_seconds
        END;

        v_next_expansion_at := v_galaxy.next_system_expansion_at
            + make_interval(secs => v_galaxy.system_interval_seconds);

        UPDATE public.universe_galaxies
        SET system_count = v_system_count,
            next_system_expansion_at = v_next_expansion_at,
            system_interval_seconds = CASE
                WHEN is_special THEN v_interval_seconds
                ELSE system_interval_seconds
            END,
            updated_at = v_now
        WHERE universe_id = v_galaxy.universe_id
          AND galaxy = v_galaxy.galaxy;

        v_expanded := v_expanded + 1;
        v_last_galaxy := v_galaxy.galaxy;
        v_last_system_count := v_system_count;
    END LOOP;

    RETURN QUERY
    SELECT v_expanded, v_last_galaxy, v_last_system_count;
END;
$function$;

COMMENT ON FUNCTION public.process_universe_system_expansion(uuid) IS
'Advances due galaxy system counts without creating planet rows. Normal galaxies use a fixed per-galaxy interval; special galaxies grow their interval after each expansion. Scheduling advances from the previous scheduled timestamp to avoid drift. Processes at most 100 expansions per invocation.';