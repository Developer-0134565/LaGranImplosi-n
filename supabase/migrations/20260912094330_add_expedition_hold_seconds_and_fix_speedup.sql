ALTER TABLE public.fleet_movements
ADD COLUMN IF NOT EXISTS expedition_hold_seconds numeric
    NOT NULL DEFAULT 3600
    CHECK (expedition_hold_seconds >= 0);

CREATE OR REPLACE FUNCTION public.calculate_expedition_speedup_seconds(
    p_fleet_id uuid,
    p_percentage numeric
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_flight_seconds numeric;
    v_hold_seconds numeric;
    v_one_way_seconds numeric;
BEGIN
    IF p_percentage < 5 OR p_percentage > 10 THEN
        RAISE EXCEPTION 'Speedup percentage must be between 5 and 10';
    END IF;

    SELECT
        EXTRACT(EPOCH FROM (fm.arrives_at - fm.started_at)),
        COALESCE(fm.expedition_hold_seconds, 3600)
    INTO v_flight_seconds, v_hold_seconds
    FROM public.fleet_movements fm
    WHERE fm.id = p_fleet_id
      AND fm.mission_type = 'EXPEDITION';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Expedition fleet % not found', p_fleet_id;
    END IF;

    IF v_flight_seconds <= 0 THEN
        RAISE EXCEPTION 'Invalid expedition flight duration for fleet %', p_fleet_id;
    END IF;

    v_one_way_seconds := v_flight_seconds + v_hold_seconds;

    RETURN round(
        greatest(v_one_way_seconds * (p_percentage / 100), 1),
        4
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.select_expedition_speedup_percentage()
RETURNS numeric
LANGUAGE plpgsql
VOLATILE
AS $function$
BEGIN
    RETURN floor(random() * 6) + 5;
END;
$function$;