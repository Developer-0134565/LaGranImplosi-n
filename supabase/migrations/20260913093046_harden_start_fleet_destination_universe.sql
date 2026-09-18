BEGIN;

-- Prevent fleet missions from crossing universes through a forged destination_planet_id.
CREATE OR REPLACE FUNCTION public.start_fleet(p_player_id uuid, p_origin_planet_id uuid, p_destination_planet_id uuid, p_ship_id text, p_quantity bigint, p_mission_type text DEFAULT 'TRANSPORT'::text)
RETURNS TABLE(fleet_id uuid, ship_id text, quantity bigint, origin_planet_id uuid, destination_planet_id uuid, mission_type text, started_at timestamp with time zone, arrives_at timestamp with time zone)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_player_id uuid := p_player_id;
  v_origin_planet_id uuid := p_origin_planet_id;
  v_destination_planet_id uuid := p_destination_planet_id;
  v_ship_id text := p_ship_id;
  v_quantity bigint := p_quantity;
  v_mission_type text := upper(p_mission_type);
  v_fleet_id uuid;
  v_planet_player uuid;
  v_available bigint;
  v_universe_id uuid;
  v_dest_galaxy integer;
  v_dest_system integer;
  v_dest_position integer;
  v_origin_galaxy integer;
  v_origin_system integer;
  v_origin_position integer;
  v_distance numeric;
  v_ship_speed numeric;
  v_fleet_speed numeric;
  v_evolution numeric;
  v_fleet_rate numeric;
  v_travel_time numeric;
  v_started_at timestamptz;
  v_arrives_at timestamptz;
  v_bonus numeric := 1;
  v_slots integer;
  v_auth_user uuid;
BEGIN
  v_auth_user := auth.uid();

  IF v_auth_user IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.players pl
    WHERE pl.id = v_player_id AND pl.user_id = v_auth_user
  ) THEN
    RAISE EXCEPTION 'Player does not belong to authenticated user';
  END IF;

  IF v_auth_user IS NULL AND NOT EXISTS (
    SELECT 1 FROM public.players pl
    WHERE pl.id = v_player_id AND coalesce(pl.is_guest, false) = true
  ) THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF v_quantity <= 0 THEN
    RAISE EXCEPTION 'Fleet quantity must be greater than 0';
  END IF;

  IF v_mission_type NOT IN ('ATTACK','TRANSPORT','DEPLOY','ESPIONAGE','COLONIZE','RECYCLE','EXPEDITION') THEN
    RAISE EXCEPTION 'Invalid mission type: %', v_mission_type;
  END IF;

  SELECT p.player_id,p.universe_id,p.galaxy,p.system,p.position
  INTO v_planet_player,v_universe_id,v_origin_galaxy,v_origin_system,v_origin_position
  FROM public.planets p
  WHERE p.id=v_origin_planet_id AND NOT p.is_destroyed
  FOR UPDATE;

  IF NOT FOUND OR v_planet_player<>v_player_id THEN
    RAISE EXCEPTION 'Origin planet does not belong to player';
  END IF;

  IF v_mission_type='EXPEDITION' THEN
    v_destination_planet_id:=NULL;
    v_dest_galaxy:=v_origin_galaxy;
    v_dest_system:=v_origin_system;
    v_dest_position:=16;
    v_slots:=public.get_player_expedition_slots(v_player_id);
    IF public.get_active_expedition_count(v_player_id)>=v_slots THEN
      RAISE EXCEPTION 'EXPEDITION_SLOTS_FULL: %/%',public.get_active_expedition_count(v_player_id),v_slots;
    END IF;
  ELSIF v_mission_type='RECYCLE' THEN
    IF v_ship_id<>'recycler' THEN
      RAISE EXCEPTION 'RECYCLE mission requires recycler';
    END IF;
    SELECT df.galaxy,df.system,df.position
    INTO v_dest_galaxy,v_dest_system,v_dest_position
    FROM public.debris_fields df
    WHERE df.universe_id=v_universe_id AND (df.metal>0 OR df.crystal>0)
    ORDER BY abs(df.galaxy-v_origin_galaxy),abs(df.system-v_origin_system),abs(df.position-v_origin_position)
    LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'No debris field available for RECYCLE';
    END IF;
    v_destination_planet_id:=NULL;
  ELSE
    IF v_destination_planet_id IS NULL THEN
      RAISE EXCEPTION 'Destination planet is required for %',v_mission_type;
    END IF;
    IF v_origin_planet_id=v_destination_planet_id THEN
      RAISE EXCEPTION 'Origin and destination planets must be different';
    END IF;
    SELECT galaxy,system,position INTO v_dest_galaxy,v_dest_system,v_dest_position
    FROM public.planets
    WHERE id=v_destination_planet_id
      AND universe_id=v_universe_id
      AND NOT is_destroyed;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Destination planet not found, destroyed, or belongs to another universe';
    END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.ship_definitions WHERE id=v_ship_id) THEN
    RAISE EXCEPTION 'Unknown ship: %',v_ship_id;
  END IF;

  SELECT ps.quantity INTO v_available
  FROM public.planet_ships ps
  WHERE ps.planet_id=v_origin_planet_id AND ps.ship_id=v_ship_id
  FOR UPDATE;

  IF COALESCE(v_available,0)<v_quantity THEN
    RAISE EXCEPTION 'Not enough %: available %, requested %',v_ship_id,COALESCE(v_available,0),v_quantity;
  END IF;

  IF v_origin_galaxy<>v_dest_galaxy THEN
    v_distance:=20000*abs(v_origin_galaxy-v_dest_galaxy);
  ELSIF v_origin_system<>v_dest_system THEN
    v_distance:=2700+95*abs(v_origin_system-v_dest_system);
  ELSIF v_origin_position<>v_dest_position THEN
    v_distance:=1000+5*abs(v_origin_position-v_dest_position);
  ELSE
    v_distance:=5;
  END IF;

  SELECT speed INTO v_ship_speed FROM public.ship_definitions WHERE id=v_ship_id;
  SELECT fleet_speed INTO v_fleet_speed FROM public.universes WHERE id=v_universe_id;
  v_evolution:=public.calculate_universe_evolution_rate(v_universe_id);
  v_bonus:=1+(
    COALESCE(public.get_active_expedition_item_effect(v_player_id,v_origin_planet_id,'fleet_speed_percent'),0)+
    COALESCE(public.get_active_lifeform_research_effect(v_player_id,'fleet_speed_percent'),0)
  )/100;
  v_fleet_rate:=v_fleet_speed*power(v_evolution,1.0/3.0)*v_bonus;

  IF v_mission_type='EXPEDITION' THEN
    v_travel_time:=((35000/100)*sqrt(v_distance*10/v_ship_speed)+10)/(
      COALESCE((SELECT expedition_speed FROM public.universes WHERE id=v_universe_id),1)*power(v_evolution,1.0/3.0)*v_bonus
    );
  ELSE
    v_travel_time:=(v_distance/v_ship_speed)*3600/v_fleet_rate;
  END IF;

  v_travel_time:=greatest(v_travel_time,1);
  v_started_at:=now();
  v_arrives_at:=v_started_at+(v_travel_time*interval '1 second');

  UPDATE public.planet_ships ps SET quantity=ps.quantity-v_quantity
  WHERE ps.planet_id=v_origin_planet_id AND ps.ship_id=v_ship_id;

  INSERT INTO public.fleet_movements(
    player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status,
    destination_galaxy,destination_system,destination_position,expedition_hold_seconds
  ) VALUES(
    v_player_id,v_origin_planet_id,v_destination_planet_id,v_mission_type,v_started_at,v_arrives_at,'OUTBOUND',
    v_dest_galaxy,v_dest_system,v_dest_position,3600
  ) RETURNING id INTO v_fleet_id;

  INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity)
  VALUES(v_fleet_id,v_ship_id,v_quantity);

  RETURN QUERY SELECT v_fleet_id,v_ship_id,v_quantity,v_origin_planet_id,v_destination_planet_id,v_mission_type,v_started_at,v_arrives_at;
END;
$function$;

COMMIT;
