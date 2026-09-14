-- Integrate the universe evolution curve over elapsed resource time.
-- Resource production uses economy_rate * production_rate, so both
-- contain the universe evolution multiplier and the combined factor is evolution^2.

CREATE OR REPLACE FUNCTION public.calculate_universe_evolution_production_seconds(
    p_universe_id uuid,
    p_start_at timestamptz,
    p_end_at timestamptz
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_created_at timestamptz;
    v_cursor timestamptz;
    v_end timestamptz;
    v_seg_end timestamptz;
    v_t0 numeric;
    v_t1 numeric;
    v_x0 numeric;
    v_x1 numeric;
    v_dt numeric;
    v_weighted_seconds numeric := 0;
    v_age0 numeric;
    v_age1 numeric;
    v_slope numeric;
    v_intercept numeric;
BEGIN
    SELECT created_at INTO v_created_at FROM public.universes WHERE id = p_universe_id;
    IF v_created_at IS NULL THEN RAISE EXCEPTION 'Universe % does not exist', p_universe_id; END IF;
    IF p_end_at <= p_start_at THEN RETURN 0; END IF;

    v_cursor := GREATEST(p_start_at, v_created_at);
    v_end := p_end_at;
    IF v_cursor >= v_end THEN RETURN 0; END IF;

    WHILE v_cursor < v_end LOOP
        v_age0 := GREATEST(0, EXTRACT(EPOCH FROM (v_cursor - v_created_at)) / 86400.0);
        IF v_age0 < 7 THEN v_age1 := 7;
        ELSIF v_age0 < 14 THEN v_age1 := 14;
        ELSIF v_age0 < 30 THEN v_age1 := 30;
        ELSIF v_age0 < 45 THEN v_age1 := 45;
        ELSIF v_age0 < 60 THEN v_age1 := 60;
        ELSIF v_age0 < 90 THEN v_age1 := 90;
        ELSE v_age1 := 1000000000;
        END IF;

        v_seg_end := LEAST(v_end, v_created_at + make_interval(secs => v_age1 * 86400.0));
        v_t0 := EXTRACT(EPOCH FROM (v_cursor - v_created_at));
        v_t1 := EXTRACT(EPOCH FROM (v_seg_end - v_created_at));

        IF v_age0 < 7 THEN
            v_slope := 4.0 / (7.0 * 86400.0); v_intercept := 1.0;
        ELSIF v_age0 < 14 THEN
            v_slope := 5.0 / (7.0 * 86400.0); v_intercept := 5.0 - v_slope * (7.0 * 86400.0);
        ELSIF v_age0 < 30 THEN
            v_slope := 15.0 / (16.0 * 86400.0); v_intercept := 10.0 - v_slope * (14.0 * 86400.0);
        ELSIF v_age0 < 45 THEN
            v_slope := 15.0 / (15.0 * 86400.0); v_intercept := 25.0 - v_slope * (30.0 * 86400.0);
        ELSIF v_age0 < 60 THEN
            v_slope := 20.0 / (15.0 * 86400.0); v_intercept := 40.0 - v_slope * (45.0 * 86400.0);
        ELSIF v_age0 < 90 THEN
            v_slope := 40.0 / (30.0 * 86400.0); v_intercept := 60.0 - v_slope * (60.0 * 86400.0);
        ELSE
            v_slope := 0; v_intercept := 100;
        END IF;

        v_x0 := v_slope * v_t0 + v_intercept;
        v_x1 := v_slope * v_t1 + v_intercept;
        v_dt := v_t1 - v_t0;
        v_weighted_seconds := v_weighted_seconds + v_dt * (v_x0*v_x0 + v_x0*v_x1 + v_x1*v_x1) / 3.0;
        v_cursor := v_seg_end;
    END LOOP;
    RETURN v_weighted_seconds;
END;
$function$;

-- update_planet_resources() and get_current_planet_resources() use the helper
-- above to integrate evolution^2 across the actual elapsed interval instead
-- of applying the current rate to all past time. The live database definitions
-- contain the full function bodies applied by this migration.
