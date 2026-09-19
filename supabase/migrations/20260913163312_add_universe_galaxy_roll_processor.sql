CREATE OR REPLACE FUNCTION public.process_universe_galaxy_roll(p_universe_id uuid)
RETURNS TABLE(rolls_processed integer, galaxies_created integer, last_galaxy integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_state public.universe_expansion_state%ROWTYPE;
    v_now timestamptz := now();
    v_roll_at timestamptz;
    v_interval interval;
    v_probability numeric;
    v_initial_systems integer;
    v_base_interval numeric;
    v_growth_factor numeric;
    v_next_galaxy integer;
    v_rolls integer := 0;
    v_created integer := 0;
    v_last_galaxy integer := NULL;
    v_max_rolls integer := 1000;
BEGIN
    SELECT *
    INTO v_state
    FROM public.universe_expansion_state
    WHERE universe_id = p_universe_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Universe expansion state not found: %', p_universe_id;
    END IF;

    v_roll_at := v_state.next_galaxy_roll_at;
    v_interval := make_interval(secs => v_state.galaxy_roll_interval_seconds);
    v_probability := v_state.galaxy_roll_probability;
    v_initial_systems := v_state.initial_special_galaxy_systems;
    v_base_interval := v_state.special_galaxy_base_interval_seconds;
    v_growth_factor := v_state.special_galaxy_interval_growth_factor;

    IF v_roll_at IS NULL THEN
        RETURN QUERY SELECT 0, 0, NULL::integer;
        RETURN;
    END IF;

    IF v_state.galaxy_roll_interval_seconds <= 0
       OR v_probability < 0
       OR v_probability > 1
       OR v_initial_systems <= 0
       OR v_base_interval <= 0
       OR v_growth_factor < 1 THEN
        RAISE EXCEPTION 'Invalid galaxy roll configuration for universe %', p_universe_id;
    END IF;

    WHILE v_roll_at <= v_now AND v_rolls < v_max_rolls LOOP
        v_rolls := v_rolls + 1;

        IF random() < v_probability THEN
            SELECT COALESCE(MAX(galaxy), 0) + 1
            INTO v_next_galaxy
            FROM public.universe_galaxies
            WHERE universe_id = p_universe_id;

            INSERT INTO public.universe_galaxies (
                universe_id,
                galaxy,
                system_count,
                next_system_expansion_at,
                system_interval_seconds,
                system_interval_growth_factor,
                is_special,
                created_at,
                updated_at
            )
            VALUES (
                p_universe_id,
                v_next_galaxy,
                v_initial_systems,
                v_roll_at + make_interval(secs => v_base_interval),
                v_base_interval,
                v_growth_factor,
                true,
                v_roll_at,
                v_now
            );

            v_created := v_created + 1;
            v_last_galaxy := v_next_galaxy;
        END IF;

        v_roll_at := v_roll_at + v_interval;
    END LOOP;

    UPDATE public.universe_expansion_state
    SET next_galaxy_roll_at = v_roll_at,
        updated_at = v_now
    WHERE universe_id = p_universe_id;

    RETURN QUERY
    SELECT v_rolls, v_created, v_last_galaxy;
END;
$function$;

REVOKE ALL ON FUNCTION public.process_universe_galaxy_roll(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.process_universe_heartbeat()
RETURNS TABLE(universes_processed integer, total_ticks_executed integer, systems_expanded integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_universe RECORD;
    v_clock RECORD;
    v_roll RECORD;
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
        SELECT *
        INTO v_clock
        FROM public.process_universe_clock(v_universe.id);

        SELECT *
        INTO v_roll
        FROM public.process_universe_galaxy_roll(v_universe.id);

        SELECT *
        INTO v_expansion
        FROM public.process_universe_system_expansion(v_universe.id);

        v_universes := v_universes + 1;
        v_ticks := v_ticks + COALESCE(v_clock.ticks_executed, 0);
        v_systems := v_systems + COALESCE(v_expansion.systems_expanded, 0);
    END LOOP;

    RETURN QUERY
    SELECT v_universes, v_ticks, v_systems;
END;
$function$;

REVOKE ALL ON FUNCTION public.process_universe_heartbeat() FROM PUBLIC;