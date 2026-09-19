CREATE OR REPLACE FUNCTION public.calculate_universe_evolution_rate(p_universe_id uuid)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_created_at timestamptz;
    v_age_days numeric;
BEGIN
    SELECT created_at
    INTO v_created_at
    FROM public.universes
    WHERE id = p_universe_id;

    IF v_created_at IS NULL THEN
        RAISE EXCEPTION 'Universe % does not exist', p_universe_id;
    END IF;

    v_age_days := GREATEST(
        0,
        EXTRACT(EPOCH FROM (now() - v_created_at)) / 86400
    );

    RETURN CASE
        WHEN v_age_days < 7 THEN
            1 + (v_age_days / 7) * 4
        WHEN v_age_days < 14 THEN
            5 + ((v_age_days - 7) / 7) * 5
        WHEN v_age_days < 30 THEN
            10 + ((v_age_days - 14) / 16) * 15
        WHEN v_age_days < 45 THEN
            25 + ((v_age_days - 30) / 15) * 15
        WHEN v_age_days < 60 THEN
            40 + ((v_age_days - 45) / 15) * 20
        WHEN v_age_days < 90 THEN
            60 + ((v_age_days - 60) / 30) * 40
        ELSE
            100
    END;
END;
$function$;