CREATE OR REPLACE FUNCTION public.run_fleet_worker()
RETURNS TABLE(processed_fleets bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count bigint := 0;
  v_row record;
BEGIN
  FOR v_row IN SELECT * FROM public.process_fleet_movements() LOOP
    v_count := v_count + 1;
  END LOOP;
  processed_fleets := v_count;
  RETURN NEXT;
END;
$function$;

REVOKE ALL ON FUNCTION public.run_fleet_worker() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.run_fleet_worker() TO service_role;