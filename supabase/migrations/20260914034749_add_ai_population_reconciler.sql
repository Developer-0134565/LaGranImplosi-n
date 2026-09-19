CREATE OR REPLACE FUNCTION public.reconcile_universe_ai_population(p_universe_id uuid)
RETURNS TABLE(
    positions_unlocked bigint,
    ai_before bigint,
    ai_after bigint,
    target_ai bigint,
    planets_created integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_state public.universe_population_state%ROWTYPE;
    v_positions bigint;
    v_systems bigint;
    v_ai_before bigint;
    v_ai_after bigint;
    v_target bigint;
    v_needed bigint;
    v_to_create integer;
    v_created integer := 0;
    v_candidate record;
    v_player_id uuid;
    v_planet_id uuid;
    v_now timestamptz := now();
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.universes WHERE id = p_universe_id
    ) THEN
        RAISE EXCEPTION 'Universe % does not exist', p_universe_id;
    END IF;

    INSERT INTO public.universe_population_state (universe_id, next_reconciliation_at)
    VALUES (p_universe_id, v_now)
    ON CONFLICT (universe_id) DO NOTHING;

    SELECT *
    INTO v_state
    FROM public.universe_population_state
    WHERE universe_id = p_universe_id
    FOR UPDATE;

    SELECT COALESCE(SUM(system_count), 0)::bigint
    INTO v_systems
    FROM public.universe_galaxies
    WHERE universe_id = p_universe_id;

    v_positions := v_systems * 15;

    SELECT COUNT(*)::bigint
    INTO v_ai_before
    FROM public.planets p
    JOIN public.players pl ON pl.id = p.player_id
    WHERE p.universe_id = p_universe_id
      AND pl.player_type = 'AI'
      AND p.is_destroyed = false;

    v_target := CEIL(v_positions * v_state.ai_density_target)::bigint;
    v_needed := GREATEST(v_target - v_ai_before, 0);
    v_to_create := LEAST(v_needed, GREATEST(v_state.ai_generation_batch, 0));

    IF v_to_create > 0 THEN
        FOR v_candidate IN
            SELECT g.galaxy, s.system_no, pos.position
            FROM public.universe_galaxies g
            CROSS JOIN LATERAL generate_series(1, g.system_count) AS s(system_no)
            CROSS JOIN LATERAL generate_series(1, 15) AS pos(position)
            WHERE g.universe_id = p_universe_id
              AND NOT EXISTS (
                  SELECT 1
                  FROM public.planets existing
                  WHERE existing.universe_id = p_universe_id
                    AND existing.galaxy = g.galaxy
                    AND existing.system = s.system_no
                    AND existing.position = pos.position
              )
            ORDER BY g.galaxy, s.system_no, pos.position
            LIMIT v_to_create
        LOOP
            BEGIN
                INSERT INTO public.players (
                    universe_id,
                    user_id,
                    username,
                    points,
                    rank,
                    dark_matter,
                    is_guest,
                    player_type
                )
                VALUES (
                    p_universe_id,
                    NULL,
                    format('AI-G%s-S%s-P%s', v_candidate.galaxy, v_candidate.system_no, v_candidate.position),
                    0,
                    NULL,
                    0,
                    false,
                    'AI'
                )
                RETURNING id INTO v_player_id;

                INSERT INTO public.planets (
                    universe_id,
                    player_id,
                    name,
                    galaxy,
                    system,
                    position,
                    temperature_min,
                    temperature_max,
                    fields_total,
                    fields_used,
                    is_homeworld,
                    is_destroyed
                )
                VALUES (
                    p_universe_id,
                    v_player_id,
                    format('AI World G%s:S%s:P%s', v_candidate.galaxy, v_candidate.system_no, v_candidate.position),
                    v_candidate.galaxy,
                    v_candidate.system_no,
                    v_candidate.position,
                    NULL,
                    NULL,
                    163,
                    0,
                    true,
                    false
                )
                RETURNING id INTO v_planet_id;

                INSERT INTO public.planet_resources (
                    planet_id,
                    metal,
                    crystal,
                    deuterium,
                    energy,
                    last_calculated_at,
                    updated_at
                )
                VALUES (
                    v_planet_id,
                    0,
                    0,
                    0,
                    0,
                    v_now,
                    v_now
                );

                v_created := v_created + 1;
            EXCEPTION WHEN unique_violation THEN
                -- A concurrent colonization/creation may have taken this coordinate.
                -- Roll back only this candidate and continue with the next one.
                NULL;
            END;

            EXIT WHEN v_created >= v_to_create;
        END LOOP;
    END IF;

    SELECT COUNT(*)::bigint
    INTO v_ai_after
    FROM public.planets p
    JOIN public.players pl ON pl.id = p.player_id
    WHERE p.universe_id = p_universe_id
      AND pl.player_type = 'AI'
      AND p.is_destroyed = false;

    UPDATE public.universe_population_state
    SET unlocked_systems = v_systems,
        unlocked_positions = v_positions,
        ai_planets_count = v_ai_after,
        next_reconciliation_at = v_now + make_interval(secs => GREATEST(v_state.reconciliation_interval_seconds, 1)),
        updated_at = v_now
    WHERE universe_id = p_universe_id;

    RETURN QUERY
    SELECT v_positions, v_ai_before, v_ai_after, v_target, v_created;
END;
$function$;

REVOKE ALL ON FUNCTION public.reconcile_universe_ai_population(uuid) FROM PUBLIC;

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
    v_population RECORD;
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

        -- Population is timestamp-driven, not tick-driven. A missed heartbeat
        -- simply causes the next heartbeat to reconcile after downtime.
        IF EXISTS (
            SELECT 1
            FROM public.universe_population_state
            WHERE universe_id = v_universe.id
              AND next_reconciliation_at <= now()
        ) THEN
            SELECT *
            INTO v_population
            FROM public.reconcile_universe_ai_population(v_universe.id);
        END IF;
    END LOOP;

    RETURN QUERY
    SELECT v_universes, v_ticks, v_systems;
END;
$function$;

REVOKE ALL ON FUNCTION public.process_universe_heartbeat() FROM PUBLIC;