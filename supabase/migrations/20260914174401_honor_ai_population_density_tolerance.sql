CREATE OR REPLACE FUNCTION public.reconcile_universe_ai_population(p_universe_id uuid)
RETURNS TABLE(positions_unlocked bigint, ai_before bigint, ai_after bigint, target_ai bigint, planets_created integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
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
    v_lower_density numeric;
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

    /*
     * ai_density_target is the desired centre of the band.
     * ai_density_tolerance defines the acceptable lower/upper band.
     * We only create AI planets when density falls below the lower edge.
     * We deliberately do not delete AI planets when density exceeds the
     * upper edge: existing AI empires must not be destroyed by maintenance.
     */
    v_lower_density := GREATEST(
        v_state.ai_density_target - v_state.ai_density_tolerance,
        0
    );

    v_target := CEIL(v_positions * v_lower_density)::bigint;
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