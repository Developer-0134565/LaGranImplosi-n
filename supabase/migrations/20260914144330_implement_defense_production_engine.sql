CREATE TABLE public.defense_prerequisites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  defense_id text NOT NULL REFERENCES public.defense_definitions(id),
  prerequisite_type text NOT NULL CHECK (prerequisite_type IN ('building','research')),
  building_id text NULL REFERENCES public.building_definitions(id),
  research_id text NULL REFERENCES public.research_definitions(id),
  required_level integer NOT NULL CHECK (required_level > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (prerequisite_type = 'building' AND building_id IS NOT NULL AND research_id IS NULL)
    OR
    (prerequisite_type = 'research' AND research_id IS NOT NULL AND building_id IS NULL)
  )
);

CREATE UNIQUE INDEX defense_prerequisites_unique
ON public.defense_prerequisites (defense_id, prerequisite_type, COALESCE(building_id, ''), COALESCE(research_id, ''));

CREATE TABLE public.defense_queue (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  planet_id uuid NOT NULL REFERENCES public.planets(id),
  defense_id text NOT NULL REFERENCES public.defense_definitions(id),
  quantity bigint NOT NULL CHECK (quantity > 0),
  started_at timestamptz NOT NULL DEFAULT now(),
  finishes_at timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'BUILDING' CHECK (status IN ('BUILDING','COMPLETED','CANCELLED')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_defense_queue_planet_building_finish
ON public.defense_queue (planet_id, finishes_at, created_at)
WHERE status = 'BUILDING';

INSERT INTO public.defense_prerequisites (defense_id, prerequisite_type, building_id, research_id, required_level)
VALUES
  ('rocket_launcher','building','shipyard',NULL,1),
  ('light_laser','building','shipyard',NULL,2),
  ('light_laser','research',NULL,'laser_technology',3),
  ('heavy_laser','building','shipyard',NULL,3),
  ('heavy_laser','research',NULL,'laser_technology',6),
  ('ion_cannon','building','shipyard',NULL,4),
  ('ion_cannon','research',NULL,'ion_technology',4),
  ('gauss_cannon','building','shipyard',NULL,6),
  ('gauss_cannon','research',NULL,'weapons_technology',3),
  ('gauss_cannon','research',NULL,'shielding_technology',1),
  ('gauss_cannon','research',NULL,'energy_technology',6),
  ('plasma_turret','building','shipyard',NULL,8),
  ('plasma_turret','research',NULL,'plasma_technology',7),
  ('plasma_turret','research',NULL,'energy_technology',8),
  ('small_shield_dome','building','shipyard',NULL,1),
  ('small_shield_dome','research',NULL,'shielding_technology',2),
  ('large_shield_dome','building','shipyard',NULL,6),
  ('large_shield_dome','research',NULL,'shielding_technology',6);

CREATE OR REPLACE FUNCTION public.calculate_defense_build_time(p_planet_id uuid, p_defense_id text)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_base_time numeric;
  v_shipyard_level integer;
  v_universe_id uuid;
  v_building_speed numeric;
  v_evolution numeric;
  v_building_rate numeric;
BEGIN
  SELECT p.universe_id INTO v_universe_id
  FROM public.planets p
  WHERE p.id = p_planet_id AND NOT p.is_destroyed;
  IF NOT FOUND THEN RAISE EXCEPTION 'Planet not found or destroyed'; END IF;

  SELECT d.base_build_time INTO v_base_time
  FROM public.defense_definitions d
  WHERE d.id = p_defense_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown defense: %', p_defense_id; END IF;

  SELECT COALESCE(pb.level,0) INTO v_shipyard_level
  FROM public.planet_buildings pb
  WHERE pb.planet_id = p_planet_id AND pb.building_id = 'shipyard';
  v_shipyard_level := COALESCE(v_shipyard_level,0);

  SELECT u.building_speed INTO v_building_speed
  FROM public.universes u WHERE u.id = v_universe_id;
  IF v_building_speed IS NULL OR v_building_speed <= 0 THEN RAISE EXCEPTION 'Invalid universe building speed'; END IF;

  v_evolution := public.calculate_universe_evolution_rate(v_universe_id);
  v_building_rate := v_building_speed * sqrt(v_evolution);
  IF v_building_rate <= 0 THEN RAISE EXCEPTION 'Invalid effective building rate'; END IF;

  RETURN round((v_base_time / greatest(v_shipyard_level,1)) / v_building_rate, 4);
END;
$$;

CREATE OR REPLACE FUNCTION public.check_defense_requirements(p_planet_id uuid, p_defense_id text)
RETURNS TABLE(allowed boolean, reason text, defense_id text)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_player_id uuid;
  v_failed text;
BEGIN
  SELECT p.player_id INTO v_player_id
  FROM public.planets p
  WHERE p.id = p_planet_id AND NOT p.is_destroyed;
  IF NOT FOUND THEN RETURN QUERY SELECT false,'Planet not found or destroyed',p_defense_id; RETURN; END IF;

  IF NOT EXISTS (SELECT 1 FROM public.defense_definitions WHERE id=p_defense_id) THEN
    RETURN QUERY SELECT false,'Unknown defense',p_defense_id; RETURN;
  END IF;

  SELECT format('Requires %s level %s', CASE WHEN dp.prerequisite_type='building' THEN dp.building_id ELSE dp.research_id END, dp.required_level)
  INTO v_failed
  FROM public.defense_prerequisites dp
  WHERE dp.defense_id=p_defense_id
    AND (
      (dp.prerequisite_type='building' AND COALESCE((SELECT pb.level FROM public.planet_buildings pb WHERE pb.planet_id=p_planet_id AND pb.building_id=dp.building_id),0) < dp.required_level)
      OR
      (dp.prerequisite_type='research' AND COALESCE((SELECT pr.level FROM public.player_research pr WHERE pr.player_id=v_player_id AND pr.research_id=dp.research_id),0) < dp.required_level)
    )
  LIMIT 1;

  IF v_failed IS NOT NULL THEN RETURN QUERY SELECT false,v_failed,p_defense_id; RETURN; END IF;
  RETURN QUERY SELECT true,'OK',p_defense_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.calculate_defense_cost(p_defense_id text, p_quantity bigint DEFAULT 1)
RETURNS TABLE(defense_id text, quantity bigint, metal numeric, crystal numeric, deuterium numeric)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public','pg_temp'
AS $$
BEGIN
  IF p_quantity <= 0 THEN RAISE EXCEPTION 'Defense quantity must be greater than 0'; END IF;
  RETURN QUERY
  SELECT d.id,p_quantity,d.metal_cost*p_quantity,d.crystal_cost*p_quantity,d.deuterium_cost*p_quantity
  FROM public.defense_definitions d WHERE d.id=p_defense_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown defense: %',p_defense_id; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.can_build_defense(p_player_id uuid, p_planet_id uuid, p_defense_id text, p_quantity bigint DEFAULT 1)
RETURNS TABLE(allowed boolean, reason text, defense_id text, quantity bigint, metal_cost numeric, crystal_cost numeric, deuterium_cost numeric, build_time_seconds numeric)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_reason text; v_metal numeric; v_crystal numeric; v_deuterium numeric;
  v_metal_available numeric; v_crystal_available numeric; v_deuterium_available numeric; v_time numeric;
BEGIN
  IF p_quantity <= 0 THEN RETURN QUERY SELECT false,'Quantity must be greater than 0',p_defense_id,p_quantity,0::numeric,0::numeric,0::numeric,0::numeric; RETURN; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.planets p WHERE p.id=p_planet_id AND p.player_id=p_player_id AND NOT p.is_destroyed) THEN
    RETURN QUERY SELECT false,'Planet does not belong to player',p_defense_id,p_quantity,0::numeric,0::numeric,0::numeric,0::numeric; RETURN;
  END IF;
  SELECT r.reason INTO v_reason FROM public.check_defense_requirements(p_planet_id,p_defense_id) r WHERE NOT r.allowed LIMIT 1;
  SELECT c.metal,c.crystal,c.deuterium INTO v_metal,v_crystal,v_deuterium FROM public.calculate_defense_cost(p_defense_id,p_quantity) c;
  IF v_reason IS NOT NULL THEN RETURN QUERY SELECT false,v_reason,p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,0::numeric; RETURN; END IF;
  SELECT pr.metal,pr.crystal,pr.deuterium INTO v_metal_available,v_crystal_available,v_deuterium_available FROM public.get_current_planet_resources(p_planet_id) pr;
  IF v_metal_available < v_metal THEN RETURN QUERY SELECT false,'Not enough metal',p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,0::numeric; RETURN; END IF;
  IF v_crystal_available < v_crystal THEN RETURN QUERY SELECT false,'Not enough crystal',p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,0::numeric; RETURN; END IF;
  IF v_deuterium_available < v_deuterium THEN RETURN QUERY SELECT false,'Not enough deuterium',p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,0::numeric; RETURN; END IF;
  IF p_defense_id IN ('small_shield_dome','large_shield_dome') AND EXISTS (SELECT 1 FROM public.planet_defenses pd WHERE pd.planet_id=p_planet_id AND pd.defense_id=p_defense_id AND pd.quantity > 0) THEN
    RETURN QUERY SELECT false,'Shield dome already exists',p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,0::numeric; RETURN;
  END IF;
  v_time := public.calculate_defense_build_time(p_planet_id,p_defense_id);
  RETURN QUERY SELECT true,'OK',p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,v_time;
END;
$$;

CREATE OR REPLACE FUNCTION public.start_defense(p_player_id uuid, p_planet_id uuid, p_defense_id text, p_quantity bigint DEFAULT 1)
RETURNS TABLE(queue_id uuid, defense_id text, quantity bigint, started_at timestamptz, finishes_at timestamptz, metal_cost numeric, crystal_cost numeric, deuterium_cost numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_planet_player uuid; v_reason text; v_metal numeric; v_crystal numeric; v_deuterium numeric;
  v_metal_available numeric; v_crystal_available numeric; v_deuterium_available numeric;
  v_unit_time numeric; v_total_time numeric; v_started_at timestamptz; v_finishes_at timestamptz; v_queue_id uuid; v_auth_user uuid;
BEGIN
  v_auth_user := auth.uid();
  IF v_auth_user IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.players pl WHERE pl.id=p_player_id AND pl.user_id=v_auth_user) THEN RAISE EXCEPTION 'Player does not belong to authenticated user'; END IF;
  IF v_auth_user IS NULL AND NOT EXISTS (SELECT 1 FROM public.players pl WHERE pl.id=p_player_id AND COALESCE(pl.is_guest,false)=true) THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_quantity <= 0 THEN RAISE EXCEPTION 'Quantity must be greater than 0'; END IF;
  SELECT p.player_id INTO v_planet_player FROM public.planets p WHERE p.id=p_planet_id AND NOT p.is_destroyed FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Planet not found or destroyed'; END IF;
  IF v_planet_player <> p_player_id THEN RAISE EXCEPTION 'Planet does not belong to player'; END IF;
  PERFORM public.update_planet_resources(p_planet_id);
  SELECT r.reason INTO v_reason FROM public.check_defense_requirements(p_planet_id,p_defense_id) r WHERE NOT r.allowed LIMIT 1;
  IF v_reason IS NOT NULL THEN RAISE EXCEPTION '%',v_reason; END IF;
  SELECT c.metal,c.crystal,c.deuterium INTO v_metal,v_crystal,v_deuterium FROM public.calculate_defense_cost(p_defense_id,p_quantity) c;
  SELECT pr.metal,pr.crystal,pr.deuterium INTO v_metal_available,v_crystal_available,v_deuterium_available FROM public.planet_resources pr WHERE pr.planet_id=p_planet_id FOR UPDATE;
  IF v_metal_available < v_metal THEN RAISE EXCEPTION 'Not enough metal'; END IF;
  IF v_crystal_available < v_crystal THEN RAISE EXCEPTION 'Not enough crystal'; END IF;
  IF v_deuterium_available < v_deuterium THEN RAISE EXCEPTION 'Not enough deuterium'; END IF;
  IF p_defense_id IN ('small_shield_dome','large_shield_dome') AND EXISTS (SELECT 1 FROM public.planet_defenses pd WHERE pd.planet_id=p_planet_id AND pd.defense_id=p_defense_id AND pd.quantity > 0) THEN RAISE EXCEPTION 'Shield dome already exists'; END IF;
  v_unit_time := public.calculate_defense_build_time(p_planet_id,p_defense_id);
  v_total_time := v_unit_time * p_quantity;
  SELECT GREATEST(
    COALESCE((SELECT MAX(sq.finishes_at) FROM public.shipyard_queue sq WHERE sq.planet_id=p_planet_id AND sq.status='BUILDING' AND sq.finishes_at>now()),now()),
    COALESCE((SELECT MAX(dq.finishes_at) FROM public.defense_queue dq WHERE dq.planet_id=p_planet_id AND dq.status='BUILDING' AND dq.finishes_at>now()),now())
  ) INTO v_started_at;
  v_finishes_at := v_started_at + make_interval(secs => v_total_time);
  UPDATE public.planet_resources SET metal=metal-v_metal,crystal=crystal-v_crystal,deuterium=deuterium-v_deuterium,updated_at=now() WHERE planet_id=p_planet_id;
  INSERT INTO public.defense_queue(planet_id,defense_id,quantity,started_at,finishes_at,status) VALUES(p_planet_id,p_defense_id,p_quantity,v_started_at,v_finishes_at,'BUILDING') RETURNING id INTO v_queue_id;
  RETURN QUERY SELECT v_queue_id,p_defense_id,p_quantity,v_started_at,v_finishes_at,v_metal,v_crystal,v_deuterium;
END;
$$;

CREATE OR REPLACE FUNCTION public.process_defense_queue(p_planet_id uuid)
RETURNS TABLE(queue_id uuid, defense_id text, quantity bigint, status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_queue RECORD;
BEGIN
  FOR v_queue IN
    SELECT dq.id,dq.planet_id,dq.defense_id AS queued_defense_id,dq.quantity AS queued_quantity
    FROM public.defense_queue dq
    WHERE dq.planet_id=p_planet_id AND dq.status='BUILDING' AND dq.finishes_at<=now()
    ORDER BY dq.created_at
    FOR UPDATE SKIP LOCKED
  LOOP
    INSERT INTO public.planet_defenses AS pd (planet_id,defense_id,quantity,updated_at)
    VALUES(v_queue.planet_id,v_queue.queued_defense_id,v_queue.queued_quantity,now());
    UPDATE public.defense_queue dq SET status='COMPLETED' WHERE dq.id=v_queue.id AND dq.status='BUILDING';
    queue_id:=v_queue.id; defense_id:=v_queue.queued_defense_id; quantity:=v_queue.queued_quantity; status:='COMPLETED'; RETURN NEXT;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.process_planet_tick_local(p_planet_id uuid)
RETURNS TABLE(planet_id uuid, metal numeric, crystal numeric, deuterium numeric, energy numeric, buildings_completed integer, researches_completed integer)
LANGUAGE plpgsql
SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_metal numeric; v_crystal numeric; v_deuterium numeric; v_energy numeric;
BEGIN
  SELECT r.metal,r.crystal,r.deuterium,r.energy INTO v_metal,v_crystal,v_deuterium,v_energy FROM public.update_planet_resources(p_planet_id) r;
  PERFORM public.process_lifeform_tick(p_planet_id);
  PERFORM public.process_shipyard_queue(p_planet_id);
  PERFORM public.process_defense_queue(p_planet_id);
  RETURN QUERY SELECT p_planet_id,v_metal,v_crystal,v_deuterium,v_energy,0,0;
END;
$$;

CREATE OR REPLACE FUNCTION public.start_ship(p_player_id uuid, p_planet_id uuid, p_ship_id text, p_quantity bigint DEFAULT 1)
RETURNS TABLE(queue_id uuid, ship_id text, quantity bigint, started_at timestamptz, finishes_at timestamptz, metal_cost numeric, crystal_cost numeric, deuterium_cost numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_planet_player uuid; v_reason text; v_metal numeric; v_crystal numeric; v_deuterium numeric; v_metal_available numeric; v_crystal_available numeric; v_deuterium_available numeric; v_unit_time numeric; v_total_time numeric; v_started_at timestamptz; v_finishes_at timestamptz; v_queue_id uuid; v_auth_user uuid;
BEGIN
  v_auth_user:=auth.uid();
  IF v_auth_user IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.players pl WHERE pl.id=p_player_id AND pl.user_id=v_auth_user) THEN RAISE EXCEPTION 'Player does not belong to authenticated user'; END IF;
  IF v_auth_user IS NULL AND NOT EXISTS (SELECT 1 FROM public.players pl WHERE pl.id=p_player_id AND COALESCE(pl.is_guest,false)=true) THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_quantity<=0 THEN RAISE EXCEPTION 'Quantity must be greater than 0'; END IF;
  SELECT p.player_id INTO v_planet_player FROM public.planets p WHERE p.id=p_planet_id AND NOT p.is_destroyed FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Planet not found or destroyed'; END IF;
  IF v_planet_player<>p_player_id THEN RAISE EXCEPTION 'Planet does not belong to player'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.ship_definitions sd WHERE sd.id=p_ship_id) THEN RAISE EXCEPTION 'Unknown ship: %',p_ship_id; END IF;
  PERFORM public.update_planet_resources(p_planet_id);
  SELECT r.reason INTO v_reason FROM public.check_ship_requirements(p_planet_id,p_ship_id) r WHERE NOT r.allowed LIMIT 1;
  IF v_reason IS NOT NULL THEN RAISE EXCEPTION '%',v_reason; END IF;
  SELECT c.metal,c.crystal,c.deuterium INTO v_metal,v_crystal,v_deuterium FROM public.calculate_ship_cost(p_ship_id,p_quantity) c;
  SELECT pr.metal,pr.crystal,pr.deuterium INTO v_metal_available,v_crystal_available,v_deuterium_available FROM public.planet_resources pr WHERE pr.planet_id=p_planet_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Planet resources not found'; END IF;
  IF v_metal_available<v_metal THEN RAISE EXCEPTION 'Not enough metal'; END IF;
  IF v_crystal_available<v_crystal THEN RAISE EXCEPTION 'Not enough crystal'; END IF;
  IF v_deuterium_available<v_deuterium THEN RAISE EXCEPTION 'Not enough deuterium'; END IF;
  v_unit_time:=public.calculate_ship_build_time(p_planet_id,p_ship_id);
  v_total_time:=v_unit_time*p_quantity;
  SELECT GREATEST(
    COALESCE((SELECT MAX(sq.finishes_at) FROM public.shipyard_queue sq WHERE sq.planet_id=p_planet_id AND sq.status='BUILDING' AND sq.finishes_at>now()),now()),
    COALESCE((SELECT MAX(dq.finishes_at) FROM public.defense_queue dq WHERE dq.planet_id=p_planet_id AND dq.status='BUILDING' AND dq.finishes_at>now()),now())
  ) INTO v_started_at;
  v_finishes_at:=v_started_at+make_interval(secs=>v_total_time);
  UPDATE public.planet_resources SET metal=metal-v_metal,crystal=crystal-v_crystal,deuterium=deuterium-v_deuterium,updated_at=now() WHERE planet_id=p_planet_id;
  INSERT INTO public.shipyard_queue(planet_id,ship_id,quantity,started_at,finishes_at,status) VALUES(p_planet_id,p_ship_id,p_quantity,v_started_at,v_finishes_at,'BUILDING') RETURNING id INTO v_queue_id;
  RETURN QUERY SELECT v_queue_id,p_ship_id,p_quantity,v_started_at,v_finishes_at,v_metal,v_crystal,v_deuterium;
END;
$$;