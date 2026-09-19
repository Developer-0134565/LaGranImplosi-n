CREATE OR REPLACE FUNCTION public.can_build_defense(p_player_id uuid, p_planet_id uuid, p_defense_id text, p_quantity bigint DEFAULT 1)
RETURNS TABLE(allowed boolean, reason text, defense_id text, quantity bigint, metal_cost numeric, crystal_cost numeric, deuterium_cost numeric, build_time_seconds numeric)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_reason text;
  v_metal numeric;
  v_crystal numeric;
  v_deuterium numeric;
  v_metal_available numeric;
  v_crystal_available numeric;
  v_deuterium_available numeric;
  v_time numeric;
BEGIN
  IF p_quantity <= 0 THEN
    RETURN QUERY SELECT false,'Quantity must be greater than 0',p_defense_id,p_quantity,0::numeric,0::numeric,0::numeric,0::numeric;
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.planets p
    WHERE p.id=p_planet_id AND p.player_id=p_player_id AND NOT p.is_destroyed
  ) THEN
    RETURN QUERY SELECT false,'Planet does not belong to player',p_defense_id,p_quantity,0::numeric,0::numeric,0::numeric,0::numeric;
    RETURN;
  END IF;

  SELECT r.reason INTO v_reason
  FROM public.check_defense_requirements(p_planet_id,p_defense_id) r
  WHERE NOT r.allowed LIMIT 1;

  SELECT c.metal,c.crystal,c.deuterium
  INTO v_metal,v_crystal,v_deuterium
  FROM public.calculate_defense_cost(p_defense_id,p_quantity) c;

  IF v_reason IS NOT NULL THEN
    RETURN QUERY SELECT false,v_reason,p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,0::numeric;
    RETURN;
  END IF;

  SELECT pr.metal,pr.crystal,pr.deuterium
  INTO v_metal_available,v_crystal_available,v_deuterium_available
  FROM public.get_current_planet_resources(p_planet_id) pr;

  IF v_metal_available < v_metal THEN
    RETURN QUERY SELECT false,'Not enough metal',p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,0::numeric;
    RETURN;
  END IF;
  IF v_crystal_available < v_crystal THEN
    RETURN QUERY SELECT false,'Not enough crystal',p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,0::numeric;
    RETURN;
  END IF;
  IF v_deuterium_available < v_deuterium THEN
    RETURN QUERY SELECT false,'Not enough deuterium',p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,0::numeric;
    RETURN;
  END IF;

  IF p_defense_id IN ('small_shield_dome','large_shield_dome') AND (
    EXISTS (
      SELECT 1 FROM public.planet_defenses pd
      WHERE pd.planet_id=p_planet_id AND pd.defense_id=p_defense_id AND pd.quantity > 0
    )
    OR EXISTS (
      SELECT 1 FROM public.defense_queue dq
      WHERE dq.planet_id=p_planet_id AND dq.defense_id=p_defense_id AND dq.status='BUILDING'
    )
  ) THEN
    RETURN QUERY SELECT false,'Shield dome already exists or is queued',p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,0::numeric;
    RETURN;
  END IF;

  v_time := public.calculate_defense_build_time(p_planet_id,p_defense_id);
  RETURN QUERY SELECT true,'OK',p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,v_time;
END;
$function$;

CREATE OR REPLACE FUNCTION public.start_defense(p_player_id uuid, p_planet_id uuid, p_defense_id text, p_quantity bigint DEFAULT 1)
RETURNS TABLE(queue_id uuid, defense_id text, quantity bigint, started_at timestamp with time zone, finishes_at timestamp with time zone, metal_cost numeric, crystal_cost numeric, deuterium_cost numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_planet_player uuid;
  v_reason text;
  v_metal numeric;
  v_crystal numeric;
  v_deuterium numeric;
  v_metal_available numeric;
  v_crystal_available numeric;
  v_deuterium_available numeric;
  v_unit_time numeric;
  v_total_time numeric;
  v_started_at timestamptz;
  v_finishes_at timestamptz;
  v_queue_id uuid;
  v_auth_user uuid;
BEGIN
  v_auth_user := auth.uid();
  IF v_auth_user IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.players pl WHERE pl.id=p_player_id AND pl.user_id=v_auth_user) THEN
    RAISE EXCEPTION 'Player does not belong to authenticated user';
  END IF;
  IF v_auth_user IS NULL AND NOT EXISTS (SELECT 1 FROM public.players pl WHERE pl.id=p_player_id AND COALESCE(pl.is_guest,false)=true) THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_quantity <= 0 THEN RAISE EXCEPTION 'Quantity must be greater than 0'; END IF;

  SELECT p.player_id INTO v_planet_player
  FROM public.planets p
  WHERE p.id=p_planet_id AND NOT p.is_destroyed
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Planet not found or destroyed'; END IF;
  IF v_planet_player <> p_player_id THEN RAISE EXCEPTION 'Planet does not belong to player'; END IF;

  PERFORM public.update_planet_resources(p_planet_id);

  SELECT r.reason INTO v_reason
  FROM public.check_defense_requirements(p_planet_id,p_defense_id) r
  WHERE NOT r.allowed LIMIT 1;
  IF v_reason IS NOT NULL THEN RAISE EXCEPTION '%',v_reason; END IF;

  SELECT c.metal,c.crystal,c.deuterium INTO v_metal,v_crystal,v_deuterium
  FROM public.calculate_defense_cost(p_defense_id,p_quantity) c;

  SELECT pr.metal,pr.crystal,pr.deuterium
  INTO v_metal_available,v_crystal_available,v_deuterium_available
  FROM public.planet_resources pr
  WHERE pr.planet_id=p_planet_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Planet resources not found'; END IF;
  IF v_metal_available < v_metal THEN RAISE EXCEPTION 'Not enough metal'; END IF;
  IF v_crystal_available < v_crystal THEN RAISE EXCEPTION 'Not enough crystal'; END IF;
  IF v_deuterium_available < v_deuterium THEN RAISE EXCEPTION 'Not enough deuterium'; END IF;

  IF p_defense_id IN ('small_shield_dome','large_shield_dome') AND (
    EXISTS (
      SELECT 1 FROM public.planet_defenses pd
      WHERE pd.planet_id=p_planet_id AND pd.defense_id=p_defense_id AND pd.quantity > 0
    )
    OR EXISTS (
      SELECT 1 FROM public.defense_queue dq
      WHERE dq.planet_id=p_planet_id AND dq.defense_id=p_defense_id AND dq.status='BUILDING'
    )
  ) THEN
    RAISE EXCEPTION 'Shield dome already exists or is queued';
  END IF;

  v_unit_time := public.calculate_defense_build_time(p_planet_id,p_defense_id);
  v_total_time := v_unit_time * p_quantity;

  SELECT GREATEST(
    COALESCE((SELECT MAX(sq.finishes_at) FROM public.shipyard_queue sq WHERE sq.planet_id=p_planet_id AND sq.status='BUILDING' AND sq.finishes_at>now()),now()),
    COALESCE((SELECT MAX(dq.finishes_at) FROM public.defense_queue dq WHERE dq.planet_id=p_planet_id AND dq.status='BUILDING' AND dq.finishes_at>now()),now())
  ) INTO v_started_at;
  v_finishes_at := v_started_at + make_interval(secs => v_total_time);

  UPDATE public.planet_resources
  SET metal=metal-v_metal,crystal=crystal-v_crystal,deuterium=deuterium-v_deuterium,updated_at=now()
  WHERE planet_id=p_planet_id;

  INSERT INTO public.defense_queue(planet_id,defense_id,quantity,started_at,finishes_at,status)
  VALUES(p_planet_id,p_defense_id,p_quantity,v_started_at,v_finishes_at,'BUILDING')
  RETURNING id INTO v_queue_id;

  RETURN QUERY SELECT v_queue_id,p_defense_id,p_quantity,v_started_at,v_finishes_at,v_metal,v_crystal,v_deuterium;
END;
$function$;

ALTER TABLE public.planet_defenses DROP CONSTRAINT IF EXISTS planet_defenses_planet_id_defense_id_key;