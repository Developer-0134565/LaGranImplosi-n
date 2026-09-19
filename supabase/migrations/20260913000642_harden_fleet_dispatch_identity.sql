CREATE OR REPLACE FUNCTION public.start_fleet(p_player_id uuid, p_origin_planet_id uuid, p_destination_planet_id uuid, p_ship_id text, p_quantity bigint, p_mission_type text DEFAULT 'TRANSPORT'::text)
RETURNS TABLE(fleet_id uuid, ship_id text, quantity bigint, origin_planet_id uuid, destination_planet_id uuid, mission_type text, started_at timestamptz, arrives_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $function$
DECLARE v_user_id uuid; BEGIN
  IF auth.uid() IS NOT NULL THEN
    SELECT p.user_id INTO v_user_id FROM public.players p WHERE p.id=p_player_id;
    IF v_user_id IS NULL OR v_user_id<>auth.uid() THEN RAISE EXCEPTION 'Player does not belong to authenticated user'; END IF;
  END IF;
  RETURN QUERY SELECT * FROM public.start_fleet_core(p_player_id,p_origin_planet_id,p_destination_planet_id,p_ship_id,p_quantity,p_mission_type);
END;
$function$;