DO $migration$
DECLARE
    v_definition text;
    v_updated text;
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

    v_updated := regexp_replace(
        v_definition,
        '(?s)(-- 10\. Retorno normal.*?returns_at\s*=\s*)clock_timestamp\(\)',
        '\1v_fleet.arrives_at'
    );

    IF v_updated = v_definition THEN
        RAISE EXCEPTION 'Normal return clock_timestamp() block not found; migration aborted';
    END IF;

    EXECUTE v_updated;
END
$migration$;

UPDATE public.expedition_settings
SET
    weight_ships = 17,
    weight_resources = 35,
    weight_delay = 7.5,
    weight_speedup = 2.75,
    weight_nothing = 25,
    weight_black_hole = 0.2,
    weight_pirates = 3,
    weight_aliens = 1.5,
    weight_dark_matter = 7.5,
    weight_merchant = 0.4,
    weight_items = 0.5
WHERE universe_id = '86900cbc-467d-4e23-85fa-7ba6302a57eb';