-- =====================================================================
-- SUPERSEDED BY THE LEDGER - DO NOT RUN AS-IS
--
-- Este fichero es un BORRADOR local. LIVE aplico el bloque de misiles con
-- otros nombres y versiones (ver scripts/migration-ledger-snapshot.json y la
-- tabla supabase_migrations). Su contenido fue corregido despues: por
-- ejemplo, la primera version guardaba el IPM en fleet_movement_ships, que
-- viola la FK a ship_definitions, y el conteo de ABM con un SELECT sin
-- agregado devolvia NULL. La version final esta en el ledger.
--
-- El drift de ledger es el mismo patron ya diagnosticado en esta tanda y
-- sigue SIN reparar: 'supabase db push' esta prohibido en esta mision.
-- =====================================================================

-- =====================================================================
-- 20260930222000_missile_closed_surface_gates.sql
--
-- MISSILE SYSTEM (bloque 3/3): integracion en las superficies CERRADAS.
--
--   - gate de ranuras del silo en la produccion de defensas
--   - guard de demolición del silo (D2)
--   - rama MISSILE_ATTACK en el worker
--
-- Todos los cambios son MINIMOS y ADITIVOS: se conserva literalmente la
-- logica existente de cada funcion y solo se anade la validacion de
-- misiles. Ningun otro comportamiento cambia.
--
-- PRODUCT DECISIONS (cerradas, no reabrir):
--   D2  demolicion BLOQUEADA si used_slots > resulting_capacity
--   D3  prioridad fija = cheapest (0)
--   D4  orden metal+crystal ASC + desempate tecnico estable
--   D5  reutilizar la convencion LGI de casco ; sin motor paralelo
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Gate de ranuras en la produccion (can_build_defense)
--
-- Se anade UNA comprobacion antes del return final. La logica existente
-- (auth, ownership, requisitos, recursos, cupulas, tiempo) se conserva
-- intacta y se sigue evaluando en el mismo orden.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.can_build_defense(p_player_id uuid, p_planet_id uuid, p_defense_id text, p_quantity bigint DEFAULT 1)
 RETURNS TABLE(allowed boolean, reason text, defense_id text, quantity bigint, metal_cost numeric, crystal_cost numeric, deuterium_cost numeric, build_time_seconds numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
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
  IF auth.uid() IS NULL THEN
    RETURN QUERY SELECT false,'AUTHENTICATION_REQUIRED',p_defense_id,p_quantity,0::numeric,0::numeric,0::numeric,0::numeric;
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.players pl
    WHERE pl.id = p_player_id AND pl.user_id = auth.uid()
  ) THEN
    RETURN QUERY SELECT false,'PLAYER_NOT_OWNED',p_defense_id,p_quantity,0::numeric,0::numeric,0::numeric,0::numeric;
    RETURN;
  END IF;

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

-- ---------------------------------------------------------------------
-- 2. Gate de ranuras en la produccion real (start_defense)
--
-- Misma comprobacion que en can_build_defense, pero aqui es
-- server-side y bloqueante: es la unica via por la que se encola.
-- El silo se bloquea con FOR UPDATE mas abajo, asi que el gate y el
-- descuento de recursos ocurren sobre el mismo cuerpo bloqueado.
-- ---------------------------------------------------------------------
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

  IF v_auth_user IS NULL AND NOT public.is_ai_actor_target(p_player_id) THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_quantity <= 0 THEN RAISE EXCEPTION 'Quantity must be greater than 0'; END IF;

  SELECT p.player_id INTO v_planet_player
  FROM public.planets p
  WHERE p.id=p_planet_id AND NOT p.is_destroyed
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Planet not found or destroyed'; END IF;
  IF v_planet_player <> p_player_id THEN RAISE EXCEPTION 'Planet does not belong to player'; END IF;

  PERFORM public.process_planet_tick(p_planet_id);

  SELECT r.reason INTO v_reason
  FROM public.check_defense_requirements(p_planet_id,p_defense_id) r
  WHERE NOT r.allowed LIMIT 1;
  IF v_reason IS NOT NULL THEN RAISE EXCEPTION '%',v_reason; END IF;

  /* MISSILE SYSTEM: gate de ranuras del silo. Se valida ANTES de tocar
     recursos, y el cuerpo ya esta bloqueado con FOR UPDATE, asi que dos
     productions concurrentes no pueden sobrepasar la capacidad. */
  v_reason := public.missile_slot_rejection_reason(p_planet_id, p_defense_id, p_quantity);
  IF v_reason IS NOT NULL THEN RAISE EXCEPTION '%', v_reason; END IF;

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


-- ---------------------------------------------------------------------
-- 3. Guard de demolicion del silo (D2)
--
-- El jugador no puede demoler el silo si los misiles almacenados ocupan mas
-- ranuras de las que dejaria el silo resultante. La operacion se RECHAZA
-- en servidor. NO se destruyen misiles, NO se recortan cantidades, NO hay
-- overflow: el jugador debe usar o disparar sus misiles primero.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.can_demolish_missile_silo(
  p_planet_id uuid,
  p_building_id text,
  p_target_level integer
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_resulting_capacity integer;
  v_used_slots         integer;
BEGIN
  IF p_building_id <> 'missile_silo' THEN
    RETURN true;
  END IF;

  v_resulting_capacity := GREATEST(COALESCE(p_target_level, 0), 0) * 10;
  v_used_slots := public.calculate_used_missile_slots(p_planet_id);

  RETURN v_used_slots <= v_resulting_capacity;
END;
$$;

COMMENT ON FUNCTION public.can_demolish_missile_silo(uuid, text, integer) IS
  'D2: false si la demolicion dejaria menos ranuras que los misiles almacenados. No destruye ni recorta nada.';

-- Motivo legible del rechazo de demolicion.
CREATE OR REPLACE FUNCTION public.missile_demolition_rejection_reason(
  p_planet_id uuid,
  p_building_id text,
  p_target_level integer
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF public.can_demolish_missile_silo(p_planet_id, p_building_id, p_target_level) THEN
    RETURN NULL;
  END IF;

  RETURN format(
    'Missile silo cannot be reduced below its stored missiles: target level %s => %s slots, %s slot(s) in use',
    GREATEST(COALESCE(p_target_level,0),0),
    GREATEST(COALESCE(p_target_level,0),0) * 10,
    public.calculate_used_missile_slots(p_planet_id)
  );
END;
$$;

  UPDATE public.planet_resources
  SET metal=metal-v_metal,crystal=crystal-v_crystal,deuterium=deuterium-v_deuterium,updated_at=now()
  WHERE planet_id=p_planet_id;

  INSERT INTO public.defense_queue(planet_id,defense_id,quantity,started_at,finishes_at,status)
  VALUES(p_planet_id,p_defense_id,p_quantity,v_started_at,v_finishes_at,'BUILDING')
  RETURNING id INTO v_queue_id;

  RETURN QUERY SELECT v_queue_id,p_defense_id,p_quantity,v_started_at,v_finishes_at,v_metal,v_crystal,v_deuterium;
END;
$function$;

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

  /* MISSILE SYSTEM: gate de ranuras del silo (ABM 1, IPM 2). */
  v_reason := public.missile_slot_rejection_reason(p_planet_id, p_defense_id, p_quantity);
  IF v_reason IS NOT NULL THEN
    RETURN QUERY SELECT false, v_reason, p_defense_id, p_quantity, v_metal, v_crystal, v_deuterium, 0::numeric;
    RETURN;
  END IF;

  v_time := public.calculate_defense_build_time(p_planet_id,p_defense_id);
  RETURN QUERY SELECT true,'OK',p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,v_time;
END;
$function$;

-- 3b. inspect_demolition : D2 aplicado en la superficie real
--
-- start_demolition ya llama a inspect_demolition y lanza exception cuando
-- allowed=false, de modo que anadir la regla aqui bloquea la operacion en
-- servidor SIN tocar start_demolition.
--
-- Impacto de compatibilidad: anadir missile_slots_ok al RETURNS TABLE
-- cambia el tipo devuelto (OUT). Los llamadores que usan v_inspect.* por
-- nombre siguen funcionando; los que hacen "select *" por posicion verian
-- un campo mas al final. Documentado a proposito.
CREATE OR REPLACE FUNCTION public.inspect_demolition(
  p_player_id uuid,
  p_planet_id uuid,
  p_building_id text
)
RETURNS TABLE(
  allowed boolean,
  reason text,
  current_level integer,
  target_level integer,
  ion_level integer,
  cost_metal numeric,
  cost_crystal numeric,
  cost_deuterium numeric,
  duration_seconds numeric,
  available_metal numeric,
  available_crystal numeric,
  available_deuterium numeric,
  prerequisites_met boolean,
  research_idle boolean,
  unit_queue_idle boolean,
  queue_available boolean,
  missile_slots_ok boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
declare
    v_auth_user uuid := auth.uid();
    v_universe_id uuid;
    v_current_level integer := 0;
    v_target_level integer := 0;
    v_ion integer := 0;
    v_item_bonus numeric := 0;
    v_metal numeric := 0;
    v_crystal numeric := 0;
    v_deuterium numeric := 0;
    v_time numeric := 0;
    v_avail_metal numeric := 0;
    v_avail_crystal numeric := 0;
    v_avail_deuterium numeric := 0;
    v_dependents boolean := false;
    v_research_idle boolean := false;
    v_unit_queue_idle boolean := false;
    v_queue_available boolean := false;
    v_missile_slots_ok boolean := true;
    v_reason text;
begin
    /* 1. IDENTITY - owner session or the certified AI service actor. */
    if v_auth_user is not null and not exists (
        select 1 from public.players pl where pl.id = p_player_id and pl.user_id = v_auth_user
    ) then
        v_reason := 'PLAYER_NOT_OWNED_BY_AUTH_USER';
    elsif v_auth_user is null and not public.is_ai_actor_target(p_player_id) then
        v_reason := 'AUTHENTICATION_REQUIRED';
    end if;

    /* 2. OWNERSHIP - the planet must belong to that player. */
    if v_reason is null then
        select p.universe_id into v_universe_id
        from public.planets p
        where p.id = p_planet_id and p.player_id = p_player_id and p.is_destroyed = false;

        if v_universe_id is null then
            v_reason := 'PLANET_NOT_FOUND_OR_NOT_OWNED';
        end if;
    end if;

    if v_reason is null then
        select coalesce(max(pb.level), 0) into v_current_level
        from public.planet_buildings pb
        where pb.planet_id = p_planet_id and pb.building_id = p_building_id;

        if v_current_level > 0 then
            v_target_level := v_current_level - 1;
            v_ion := coalesce(public.get_player_research_level(p_player_id, 'ion_technology'), 0);

            select c.metal, c.crystal, c.deuterium
            into v_metal, v_crystal, v_deuterium
            from public.calculate_building_demolition_cost(p_building_id, v_current_level, v_ion) c;

            v_time := public.calculate_building_time(p_building_id, v_current_level, v_universe_id);
            v_item_bonus := coalesce(public.get_active_expedition_item_effect(p_player_id, p_planet_id, 'building_speed_percent'), 0);
            v_time := greatest(1, round(v_time / (1 + v_item_bonus / 100), 4));

            select pr.metal, pr.crystal, pr.deuterium
            into v_avail_metal, v_avail_crystal, v_avail_deuterium
            from public.planet_resources pr
            where pr.planet_id = p_planet_id;

            v_queue_available := not exists (
                select 1 from public.building_queue bq
                where bq.planet_id = p_planet_id and upper(bq.status) in ('BUILDING', 'QUEUED', 'ACTIVE')
            );

            /* Rule 4: a present building that still needs the level being removed. */
            v_dependents := not exists (
                select 1
                from public.building_prerequisites bp
                join public.planet_buildings dep
                  on dep.planet_id = p_planet_id
                 and dep.building_id = bp.building_id
                 and dep.level > 0
                where bp.prerequisite_building_id = p_building_id
                  and bp.required_level > v_target_level
            );

            /* Rule 5: active research needs the level, or Research Lab busy. */
            v_research_idle := not exists (
                select 1
                from public.research_queue rq
                left join public.research_building_prerequisites rbp
                  on rbp.research_id = rq.research_id
                 and rbp.building_id = p_building_id
                where rq.player_id = p_player_id
                  and upper(rq.status) = 'RESEARCHING'
                  and (p_building_id = 'research_lab' or rbp.required_level > v_target_level)
            );

            /* Rule 6: an active ship/defense order that still needs the level. */
            v_unit_queue_idle := not (
                exists (
                    select 1
                    from public.shipyard_queue sq
                    join public.ship_prerequisites sp
                      on sp.ship_id = sq.ship_id and sp.prerequisite_type = 'building'
                    where sq.planet_id = p_planet_id
                      and upper(sq.status) = 'BUILDING'
                      and sp.building_id = p_building_id
                      and sp.required_level > v_target_level
                )
                or exists (
                    select 1
                    from public.defense_queue dq
                    join public.defense_prerequisites dp
                      on dp.defense_id = dq.defense_id and dp.prerequisite_type = 'building'
                    where dq.planet_id = p_planet_id
                      and upper(dq.status) = 'BUILDING'
                      and dp.building_id = p_building_id
                      and dp.required_level > v_target_level
                )
            );

            /* Rule 7 (MISSILE SYSTEM, D2). El silo no puede bajar por debajo de
               los ranuras ocupadas por los misiles. No se destruye nada. */
            v_missile_slots_ok := public.can_demolish_missile_silo(
                p_planet_id, p_building_id, v_target_level
            );

            v_reason := case
                when not v_queue_available then 'BUILDING_QUEUE_ALREADY_ACTIVE'
                when not v_dependents then 'DEMOLITION_BLOCKED_BY_DEPENDENTS'
                when not v_research_idle then 'DEMOLITION_BLOCKED_BY_ACTIVE_RESEARCH'
                when not v_unit_queue_idle then 'DEMOLITION_BLOCKED_BY_ACTIVE_UNIT_QUEUE'
                when not v_missile_slots_ok then 'DEMOLITION_BLOCKED_BY_MISSILE_SILO_CAPACITY'
                when v_avail_metal < v_metal or v_avail_crystal < v_crystal or v_avail_deuterium < v_deuterium
                    then 'INSUFFICIENT_RESOURCES'
                else 'OK'
            end;
        else
            v_reason := 'BUILDING_NOT_PRESENT';
        end if;
    end if;

    return query select
        (v_reason = 'OK'),
        v_reason,
        v_current_level,
        v_target_level,
        v_ion,
        v_metal,
        v_crystal,
        v_deuterium,
        v_time,
        v_avail_metal,
        v_avail_crystal,
        v_avail_deuterium,
        v_dependents,
        v_research_idle,
        v_unit_queue_idle,
        v_queue_available,
        v_missile_slots_ok;
end;
$function$;

COMMENT ON FUNCTION public.inspect_demolition(uuid, uuid, text) IS
  'Inspeccion de demolicion. Rule 7 (D2) bloquea la reduccion del silo si dejaria menos ranuras que los misiles almacenados.';