DO $migration$
DECLARE
    v_definition text;
BEGIN
    SELECT pg_get_functiondef(p.oid)
    INTO v_definition
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'resolve_expedition_arrival'
      AND pg_get_function_identity_arguments(p.oid) = 'p_fleet_id uuid';

    IF v_definition IS NULL THEN
        RAISE EXCEPTION 'Function public.resolve_expedition_arrival(uuid) not found';
    END IF;

    IF position('clock_timestamp()' IN v_definition) = 0 THEN
        RAISE EXCEPTION 'clock_timestamp() not found; migration aborted';
    END IF;

    v_definition := regexp_replace(
        v_definition,
        'returns_at[[:space:]]*=[[:space:]]*clock_timestamp\(\)[[:space:]]*\+[[:space:]]*make_interval\([[:space:]]*secs[[:space:]]*=>[[:space:]]*v_return_seconds[[:space:]]*\)',
        'returns_at = v_fleet.arrives_at + make_interval(secs => v_return_seconds)',
        1,
        0,
        'n'
    );

    IF position('returns_at = v_fleet.arrives_at + make_interval(secs => v_return_seconds)' IN v_definition) = 0 THEN
        RAISE EXCEPTION 'SPEEDUP returns_at expression was not replaced; migration aborted';
    END IF;

    EXECUTE v_definition;
END
$migration$;