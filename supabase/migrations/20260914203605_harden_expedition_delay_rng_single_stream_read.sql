CREATE OR REPLACE FUNCTION public.select_expedition_delay_multiplier(p_fleet_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
        WHEN r < 0.89 THEN 2
        WHEN r < 0.99 THEN 3
        ELSE 5
    END
    FROM (
        SELECT public.expedition_event_random(p_fleet_id, 'delay_multiplier') AS r
    ) s
$function$;