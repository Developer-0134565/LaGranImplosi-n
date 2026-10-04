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
-- 20260930221000_missile_attack_mission.sql
--
-- MISSILE SYSTEM (bloque 2/2): MISSILE_ATTACK, alcance, tiempo de vuelo,
-- intercepcion ABM, prioridad de destruccion, resolucion de llegada,
-- exclusion del combate normal y guard de demolicion.
--
-- PRODUCT DECISIONS (cerradas, no reabrir):
--   D1  Silo 60s / time_factor 2 ; ABM 60s ; IPM 60s
--   D2  demolicion BLOQUEADA si used_slots > resulting_capacity
--   D3  prioridad fija = cheapest (0) ; sin selector de UI
--   D4  orden metal+crystal ASC + desempate tecnico estable
--   D5  reutilizar la convencion LGI de casco (hull) ; sin motor paralelo
--
-- ARQUITECTURA: se sigue el molde de MOON_DESTRUCTION (tipo de mission
-- propio que NO entra al motor de rondas). NO se crea un segundo worker,
-- NO un segundo motor de combate y NO un viaje de vuelta.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tipo de mision MISSILE_ATTACK
-- ---------------------------------------------------------------------
ALTER TABLE public.fleet_movements
  DROP CONSTRAINT IF EXISTS fleet_movements_mission_type_check;

ALTER TABLE public.fleet_movements
  ADD CONSTRAINT fleet_movements_mission_type_check
  CHECK (mission_type = ANY (ARRAY[
    'ATTACK','TRANSPORT','DEPLOY','ESPIONAGE','COLONIZE','RECYCLE',
    'EXPEDITION','ACS_HOLD','HOLDING','DEFEND','MOON_DESTRUCTION',
    'MISSILE_ATTACK'
  ]::text[]));

-- Prioridad objetivo de la mision. D3: el default es cheapest (0), que es
-- exactamente el comportamiento inicial pedido. La columna existe para que
-- el jugador pueda elegir mas adelante sin migrar el motor.
ALTER TABLE public.fleet_movements
  ADD COLUMN IF NOT EXISTS target_priority integer NOT NULL DEFAULT 0;

ALTER TABLE public.fleet_movements
  DROP CONSTRAINT IF EXISTS fleet_movements_target_priority_check;

ALTER TABLE public.fleet_movements
  ADD CONSTRAINT fleet_movements_target_priority_check
  CHECK (target_priority >= 0 AND target_priority <= 9);

-- ---------------------------------------------------------------------
-- 2. Alcance y tiempo de vuelo (VERIFIED OGameX)
-- ---------------------------------------------------------------------

-- Alcance en sistemas = (impulse_drive * 5) - 1.
-- Verificado: nivel 1 => 4 ; nivel 5 => 24 ; nivel 10 => 49.
CREATE OR REPLACE FUNCTION public.calculate_missile_range_systems(p_player_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT GREATEST(
    (public.get_player_research_level(p_player_id, 'impulse_drive') * 5) - 1,
    0);
$$;

COMMENT ON FUNCTION public.calculate_missile_range_systems(uuid) IS
  'Alcance de IPM en sistemas = (impulse_drive * 5) - 1. VERIFIED OGameX.';

-- Distancia en SISTEMAS (VERIFIED calculateSystemDistance):
-- 0 si misma galaxia+sistema; |sistema_origen - sistema_destino| en la
-- misma galaxia; imposible entre galaxias (el llamante lo rechaza).
CREATE OR REPLACE FUNCTION public.calculate_missile_system_distance(
  p_origin_galaxy      integer,
  p_origin_system      integer,
  p_destination_galaxy integer,
  p_destination_system integer
)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_origin_galaxy IS DISTINCT FROM p_destination_galaxy THEN NULL
    WHEN p_origin_system IS NULL OR p_destination_system IS NULL THEN NULL
    ELSE abs(p_origin_system - p_destination_system)
  END;
$$;

-- Tiempo de vuelo = (30 + 60 * distancia_en_sistemas) / velocidad_universo.
-- VERIFIED: NO usa calculate_fleet_travel_time, ni calculate_player_ship_speed,
-- ni combustible, ni el factor E^(1/3) de la evolucion. Por eso la
-- velocidad 0 del IPM es irrelevante.
CREATE OR REPLACE FUNCTION public.calculate_missile_flight_seconds(
  p_distance_in_systems integer,
  p_universe_speed      numeric
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT (30 + 60 * COALESCE(p_distance_in_systems, 0)::numeric)
         / GREATEST(COALESCE(p_universe_speed, 1), 1);
$$;

COMMENT ON FUNCTION public.calculate_missile_flight_seconds(integer, numeric) IS
  'Vuelo del IPM = (30 + 60*distancia_sistemas) / velocidad_universo. Sin pipeline de naves.';

-- ---------------------------------------------------------------------
-- 3. start_missile_attack
--
-- Cadena de seguridad, en este orden y sin exception prematura:
--   auth.uid() -> players.user_id -> players.id
--   -> planeta origen propio, vivo, con silos
--   -> objetivo existe, es PLANET/MOON, no es propio, esta en rango
--   -> IPM suficientes en el cuerpo de origen (SELECT ... FOR UPDATE)
--
-- El jugador NUNCA envia silo_level, inventario ni recursos: todos se
-- resuelven server-side. p_player_id se valida contra auth.uid().
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.start_missile_attack(
  p_player_id            uuid,
  p_origin_planet_id     uuid,
  p_destination_planet_id uuid,
  p_quantity             bigint,
  p_target_priority      integer DEFAULT 0
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_auth_user      uuid := auth.uid();
  v_origin         public.planets%ROWTYPE;
  v_target         public.planets%ROWTYPE;
  v_universe_id    uuid;
  v_universe_speed numeric;
  v_distance       integer;
  v_max_range      integer;
  v_available      bigint;
  v_flight_seconds numeric;
  v_arrives_at     timestamptz;
  v_fleet_id       uuid;
BEGIN
  -- 1. AUTENTICACION + OWNERSHIP DEL JUGADOR
  IF v_auth_user IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.players pl
      WHERE pl.id = p_player_id AND pl.user_id = v_auth_user
    ) THEN
      RAISE EXCEPTION 'Player does not belong to authenticated user';
    END IF;
  ELSIF NOT EXISTS (
    SELECT 1 FROM public.players pl
    WHERE pl.id = p_player_id AND public.is_ai_actor_target(pl.id)
  ) THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_QUANTITY_INVALID: %', p_quantity;
  END IF;

  IF p_target_priority IS NULL OR p_target_priority < 0 OR p_target_priority > 9 THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_PRIORITY_INVALID: %', p_target_priority;
  END IF;

  IF p_origin_planet_id = p_destination_planet_id THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_TARGET_OWN_BODY';
  END IF;

  -- 2. ORIGEN: propio y vivo (FOR UPDATE: el consumo de IPM es atomico)
  SELECT p.* INTO v_origin
  FROM public.planets p
  WHERE p.id = p_origin_planet_id
    AND NOT p.is_destroyed
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_ORIGIN_NOT_FOUND: %', p_origin_planet_id;
  END IF;

  IF v_origin.player_id <> p_player_id THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_ORIGIN_NOT_OWNED: %', p_origin_planet_id;
  END IF;

  IF v_origin.kind NOT IN ('PLANET','MOON') THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_ORIGIN_INVALID_BODY_TYPE: %', v_origin.kind;
  END IF;

  v_universe_id := v_origin.universe_id;

  -- 3. OBJETIVO: existe, cuerpo valido, no destruido, no propio
  SELECT p.* INTO v_target
  FROM public.planets p
  WHERE p.id = p_destination_planet_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_TARGET_NOT_FOUND: %', p_destination_planet_id;
  END IF;

  IF v_target.kind NOT IN ('PLANET','MOON') THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_TARGET_INVALID_BODY_TYPE: %', v_target.kind;
  END IF;

  IF v_target.is_destroyed AND v_target.kind = 'MOON' THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_TARGET_DESTROYED: %', p_destination_planet_id;
  END IF;

  IF v_target.player_id = p_player_id THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_TARGET_OWN: %', p_destination_planet_id;
  END IF;

  IF v_target.universe_id <> v_universe_id THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_TARGET_OTHER_UNIVERSE';
  END IF;

  -- 4. ALCANCE: misma galaxia y |sistemas| <= (impulse_drive * 5) - 1
  IF v_target.galaxy <> v_origin.galaxy THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_TARGET_OTHER_GALAXY: %', v_target.galaxy;
  END IF;

  v_distance := public.calculate_missile_system_distance(
    v_origin.galaxy, v_origin.system, v_target.galaxy, v_target.system
  );

  IF v_distance IS NULL THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_DISTANCE_UNDEFINED';
  END IF;

  v_max_range := public.calculate_missile_range_systems(p_player_id);

  IF v_distance > v_max_range THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_OUT_OF_RANGE: distance %s > range %s',
      v_distance, v_max_range;
  END IF;

  -- 5. INVENTARIO DE IPM (server-side, con FOR UPDATE)
  SELECT COALESCE(pd.quantity, 0) INTO v_available
  FROM public.planet_defenses pd
  WHERE pd.planet_id = p_origin_planet_id
    AND pd.defense_id = 'interplanetary_missile'
  FOR UPDATE;

  IF v_available < p_quantity THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_NOT_ENOUGH_IPM: available %, requested %',
      v_available, p_quantity;
  END IF;

  -- 6. VUELO: (30 + 60*distancia) / velocidad_universo.
  -- No hay combustible, ni velocidad de nave, ni factor de evolucion.
  SELECT COALESCE(u.fleet_speed, 1) INTO v_universe_speed
  FROM public.universes u
  WHERE u.id = v_universe_id;

  v_flight_seconds := public.calculate_missile_flight_seconds(
    v_distance, COALESCE(v_universe_speed, 1)
  );

  v_arrives_at := now() + make_interval(secs => v_flight_seconds);

  -- 7. CONSUMO UNICO DE IPM (una sola vez, aqui).
  -- La evidencia upstream no vuelve a descontar en la llegada, asi que
  -- descontar aqui y NO alla es lo que garantiza "exactamente una vez".
  UPDATE public.planet_defenses
  SET quantity = quantity - p_quantity,
      updated_at = now()
  WHERE planet_id = p_origin_planet_id
    AND defense_id = 'interplanetary_missile'
    AND quantity >= p_quantity;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_NOT_ENOUGH_IPM: available %, requested %',
      v_available, p_quantity;
  END IF;

  -- 8. MOVIMIENTO: MISSILE_ATTACK, OUTBOUND, sin combustible y sin retorno
  INSERT INTO public.fleet_movements
    (player_id, origin_planet_id, destination_planet_id, mission_type,
     started_at, arrives_at, status,
     destination_galaxy, destination_system, destination_position,
     metal, crystal, deuterium, expedition_hold_seconds, fuel_consumed,
     target_priority)
  VALUES
    (p_player_id, p_origin_planet_id, p_destination_planet_id, 'MISSILE_ATTACK',
     now(), v_arrives_at, 'OUTBOUND',
     v_target.galaxy, v_target.system, v_target.position,
     0, 0, 0, 0, 0,
     p_target_priority)
  RETURNING id INTO v_fleet_id;

  INSERT INTO public.fleet_movement_ships (fleet_id, ship_id, quantity)
  VALUES (v_fleet_id, 'interplanetary_missile', p_quantity);

  RETURN v_fleet_id;
END;
$$;

-- ---------------------------------------------------------------------
-- 4. Dano: potencia y armadura (D5 - sin motor de combate paralelo)
--
-- D5: se reutiliza la convencion LGI ya presente. La armadura del
-- misil es el casco que LGI ya calcula para cada defensa
-- (get_combat_defense_hull) por 10, que es exactamente la formula
-- verificada upstream (estructura x (1+0.1*armor) / 10). No se crea
-- una segunda formula de casco ni se toca el motor de rondas.
-- ---------------------------------------------------------------------

-- Potencia de una salva = n IPM x 12000 x (1 + 0.1*weapon del atacante).
CREATE OR REPLACE FUNCTION public.calculate_missile_attack_power(
  p_missile_count  bigint,
  p_attacker_player_id uuid
)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT COALESCE(p_missile_count, 0)::numeric
         * COALESCE((
             SELECT dd.attack FROM public.defense_definitions dd
             WHERE dd.id = 'interplanetary_missile'
           ), 12000)
         * (1 + 0.1 * public.get_player_research_level(
                          p_attacker_player_id, 'weapons_technology'));
$$;

COMMENT ON FUNCTION public.calculate_missile_attack_power(bigint, uuid) IS
  'Potencia de la salva = n IPM x attack(IPM) x (1 + 0.1*weapons_technology del atacante).';

-- Armadura efectiva de UNA unidad de defensa.
--
-- D5 / VERIFICADO EN CODIGO: get_combat_defense_hull ya devuelve EXACTAMENTE
-- la formula verificada upstream, (casco/10) * (1 + 0.1*armour_technology).
-- Por eso este helper NO vuelve a dividir por 10 ni a re-aplicar la
-- tecnologia: llamarla dos veces seria duplicar la formula.
CREATE OR REPLACE FUNCTION public.calculate_missile_defense_armor(
  p_defender_player_id uuid,
  p_defense_id        text
)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT public.get_combat_defense_hull(p_defender_player_id, p_defense_id);
$$;

COMMENT ON FUNCTION public.calculate_missile_defense_armor(uuid, text) IS
  'Armadura por unidad. get_combat_defense_hull YA es (hull/10)*(1+0.1*armour), o sea la formula verificada: no se duplica (D5).';


-- ---------------------------------------------------------------------
-- 5. Prioridad de destruccion (D3 / D4)
--
-- D3: el comportamiento inicial es `cheapest`. No hay selector de UI.
-- D4: el orden economico es metal + crystal ASC, y para el orden
--     absoluto se anade un criterio tecnico estable (el id de defensa),
--     porque el usort de PHP es estable y en SQL hace falta un segundo
--     criterio explicito para garantizar orden total.
--
-- El coste de comparacion EXCLUYE deuterio, tecnologia y cantidad
-- (VERIFIED seccion 4.2 punto 10).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.order_defenses_for_missile_attack(
  p_planet_id  uuid,
  p_priority   integer
)
RETURNS TABLE(
  defense_id  text,
  quantity    bigint,
  armor       numeric,
  sort_price  numeric,
  is_first    boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  WITH target_defenses AS (
    SELECT pd.defense_id,
           pd.quantity,
           (dd.metal_cost + dd.crystal_cost)::numeric AS sort_price,
           dd.target_priority
    FROM public.planet_defenses pd
    JOIN public.defense_definitions dd ON dd.id = pd.defense_id
    WHERE pd.planet_id = p_planet_id
      AND pd.quantity > 0
      -- VERIFIED: los misiles NO son objetivo; las cupulas SI.
      AND dd.id NOT IN ('interplanetary_missile','anti_ballistic_missile')
  ),
  resolved AS (
    SELECT td.*,
           -- decodePriority: codigo desconocido o NULL => cheapest (0)
           CASE WHEN COALESCE(p_priority, 0) = 1 THEN 1 ELSE 0 END AS mode
    FROM target_defenses td
  )
  SELECT r.defense_id,
         r.quantity,
         public.calculate_missile_defense_armor(
           (SELECT p.player_id FROM public.planets p WHERE p.id = p_planet_id),
           r.defense_id
         ) AS armor,
         r.sort_price,
         -- En modo cheapest (0) manda el precio ASC.
         -- En modo expensive (1) manda el precio DESC.
         -- En modo tipo (>=2) el tipo indicado primero.
         (CASE
            WHEN COALESCE(p_priority,0) >= 2 THEN (r.target_priority = COALESCE(p_priority,0))
            ELSE false
         END) AS is_first
  FROM resolved r
  ORDER BY
    -- 1) el tipo concreto elegido primero
    (CASE
       WHEN COALESCE(p_priority,0) >= 2 THEN (r.target_priority = COALESCE(p_priority,0))
       ELSE false

-- ---------------------------------------------------------------------
-- 6. resolve_missile_attack_arrival
--
-- UNA transaccion (la del worker). Orden verificado:
--   1  IPM en vuelo (leidos de fleet_movement_ships)
--   2  ABM del objetivo + ABM del PLANETA PADRE si el objetivo es luna
--   3  interceptados = least(ipm, abms) ; se gastan PADRE PRIMERO
--   4  efectivos = ipm - interceptados
--   5  potencia = efectivos x 12000 x (1 + 0.1*weapon del atacante)
--   6  defensas en orden de prioridad, saltando ABM e IPM
--   7  por cada una: destroyed = least(floor(potencia/armadura), cantidad);
--      potencia -= destroyed * armadura (la potencia sobrante se descarta)
--   8  mensajes al atacante y al defensor
--   9  status='COMPLETED' ; NO hay viaje de vuelta
--
-- Los ABM SOLO se consumen si interceptan; las defensas SOLO si se
-- destruyen. Ninguna cantidad puede quedar negativa.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_missile_attack_arrival(p_fleet_id uuid)
RETURNS TABLE(
  ipm_launched   bigint,
  abm_intercepted bigint,
  ipm_effective  bigint,
  power_remaining numeric,
  defenses_destroyed bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_movement      public.fleet_movements%ROWTYPE;
  v_target        public.planets%ROWTYPE;
  v_attacker_id   uuid;
  v_defender_id   uuid;
  v_parent_id     uuid;
  v_ipm           bigint := 0;
  v_abm_target    bigint := 0;
  v_abm_parent    bigint := 0;
  v_intercepted   bigint := 0;
  v_from_parent   bigint := 0;
  v_from_target   bigint := 0;
  v_effective     bigint := 0;
  v_power         numeric := 0;
  v_weapon_level  integer;
  v_armor         numeric;
  v_destroyed     bigint;
  v_max_destroy   bigint;
  v_total_killed  bigint := 0;
  v_target_row    record;
  v_body          text;
BEGIN
  -- Bloqueo de la fila de movimiento: la llegada se liquida una sola vez.
  SELECT fm.* INTO v_movement
  FROM public.fleet_movements fm
  WHERE fm.id = p_fleet_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_MOVEMENT_NOT_FOUND: %', p_fleet_id;
  END IF;

  IF v_movement.mission_type <> 'MISSILE_ATTACK' THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_NOT_A_MISSILE_MISSION: %', v_movement.mission_type;
  END IF;

  IF v_movement.status IN ('COMPLETED','CANCELLED') THEN
    -- Idempotencia: una llegada ya liquidada no se vuelve a liquidar.
    RETURN QUERY SELECT 0::bigint, 0::bigint, 0::bigint, 0::numeric, 0::bigint;
    RETURN;
  END IF;

  v_attacker_id := v_movement.player_id;

  -- IPM lanzados: se leen del movimiento, NO se vuelven a descontar del
  -- inventario (el consumo unico ya ocurrio en start_missile_attack).
  SELECT COALESCE(SUM(fms.quantity), 0) INTO v_ipm
  FROM public.fleet_movement_ships fms
  WHERE fms.fleet_id = p_fleet_id
    AND fms.ship_id = 'interplanetary_missile';

  IF v_ipm <= 0 THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_NO_MISSILES: fleet %', p_fleet_id;
  END IF;

     END) DESC,
    -- 2) orden economico segun el modo
    (CASE
       WHEN COALESCE(p_priority,0) = 1 THEN r.sort_price END DESC,
    (CASE
       WHEN COALESCE(p_priority,0) <> 1 THEN r.sort_price END ASC,
    -- 3) D4: desempate tecnico estable para orden ABSOLUTO
    r.defense_id ASC;
$$;

COMMENT ON FUNCTION public.order_defenses_for_missile_attack(uuid, integer) IS
  'Ordena las defensas del objetivo segun la prioridad del atacante. D3: cheapest por defecto. D4: metal+crystal + desempate por id.';


COMMENT ON FUNCTION public.start_missile_attack(uuid, uuid, uuid, bigint, integer) IS
  'Lanza IPM a un objetivo en rango. Consume el IPM exactamente una vez y no crea viaje de vuelta.';

  -- OBJETIVO
  SELECT p.* INTO v_target
  FROM public.planets p
  WHERE p.id = v_movement.destination_planet_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MISSILE_ATTACK_TARGET_NOT_FOUND: %', v_movement.destination_planet_id;
  END IF;

  v_defender_id := v_target.player_id;
  v_body        := v_target.kind;

  -- INTERCEPCION: ABM del objetivo + ABM del PLANETA PADRE si es luna.
  -- Los PADRE se gastan PRIMERO (VERIFIED seccion 3.1 paso 5).
  IF v_body = 'MOON' AND v_target.parent_planet_id IS NOT NULL THEN
    v_parent_id := v_target.parent_planet_id;
  END IF;

  IF v_defender_id IS NULL THEN
    -- Cuerpo sin dueno (debris): no hay a quien interceptar ni a quien
    -- informar. Se marca completado sin tocar defensas.
    UPDATE public.fleet_movements
    SET status='COMPLETED', returns_at=NULL
    WHERE id=p_fleet_id;

    DELETE FROM public.fleet_movement_ships WHERE fleet_id=p_fleet_id;

    RETURN QUERY SELECT v_ipm, 0::bigint, v_ipm, 0::numeric, 0::bigint;
    RETURN;
  END IF;

  SELECT COALESCE(SUM(pd.quantity), 0) INTO v_abm_target
  FROM public.planet_defenses pd
  WHERE pd.planet_id = v_target.id
    AND pd.defense_id = 'anti_ballistic_missile'
    AND pd.quantity > 0
  FOR UPDATE;

  IF v_parent_id IS NOT NULL THEN
    SELECT COALESCE(SUM(pd.quantity), 0) INTO v_abm_parent
    FROM public.planet_defenses pd
    WHERE pd.planet_id = v_parent_id
      AND pd.defense_id = 'anti_ballistic_missile'
      AND pd.quantity > 0
    FOR UPDATE;
  END IF;

  v_intercepted := LEAST(v_ipm, v_abm_target + v_abm_parent);

  -- Reparto del consumo: padre primero, luego el objetivo. Nunca negativo.
  v_from_parent := LEAST(v_intercepted, v_abm_parent);
  v_from_target := v_intercepted - v_from_parent;

  IF v_from_parent > 0 THEN
    UPDATE public.planet_defenses
    SET quantity = GREATEST(quantity - v_from_parent, 0), updated_at = now()
    WHERE planet_id = v_parent_id
      AND defense_id = 'anti_ballistic_missile';
  END IF;

  IF v_from_target > 0 THEN
    UPDATE public.planet_defenses
    SET quantity = GREATEST(quantity - v_from_target, 0), updated_at = now()
    WHERE planet_id = v_target.id
      AND defense_id = 'anti_ballistic_missile';
  END IF;

  -- EFECTIVOS + POTENCIA
  v_effective := v_ipm - v_intercepted;

  v_weapon_level := public.get_player_research_level(v_attacker_id, 'weapons_technology');

  v_power := v_effective::numeric
             * public.calculate_missile_attack_power(1, v_attacker_id);

  -- DESTRUCCION EN ORDEN DE PRIORIDAD
  -- Bucle sobre el helper de orden; la potencia baja en cada iteracion.
  FOR v_target_row IN
    SELECT o.defense_id, o.quantity, o.armor
    FROM public.order_defenses_for_missile_attack(
           v_target.id, v_movement.target_priority
         ) o
  LOOP
    -- Sin potencia no se puede destruir nada mas (la sobrante se descarta).
    EXIT WHEN v_power <= 0;

    -- Armadura 0 (casco 0) destruiria infinitas unidades: se salta.
    CONTINUE WHEN COALESCE(v_target_row.armor, 0) <= 0;

    -- VERIFIED: suelo al calcular cuantos caben, y min con la cantidad
    -- existente => destruccion PARCIAL.
    v_max_destroy := floor(v_power / v_target_row.armor)::bigint;
    v_destroyed   := LEAST(v_max_destroy, v_target_row.quantity::bigint);

    CONTINUE WHEN v_destroyed <= 0;

    v_power := v_power - (v_destroyed * v_target_row.armor);
    v_total_killed := v_total_killed + v_destroyed;

    UPDATE public.planet_defenses
    SET quantity = GREATEST(quantity - v_destroyed, 0), updated_at = now()
    WHERE planet_id = v_target.id
      AND defense_id = v_target_row.defense_id;
  END LOOP;

  -- MENSAJES (sistema existente create_player_message, sin formato paralelo)
  PERFORM public.create_player_message(
    v_attacker_id,
    NULL,
    'Ataque con misiles interplanetarios',
    format(
      'Origen: %s (G%d S%d P%d)  ->  Objetivo: %s (G%d S%d P%d)%s%sIPM lanzados: %s%sABM interceptados: %s%sIPM efectivos: %s%sDefensas destruidas: %s',
      (SELECT name FROM public.planets WHERE id = v_movement.origin_planet_id),
      v_movement.destination_galaxy, v_movement.destination_system, v_movement.destination_position,
      v_target.name, v_target.galaxy, v_target.system, v_target.position,
      E'\n', CASE WHEN v_target.kind = 'MOON' THEN ' (luna)' ELSE '' END,
      v_ipm, E'\n', v_intercepted, E'\n', v_effective, E'\n', v_total_killed
    ),
    'missile_attack:' || p_fleet_id::text
  );

  PERFORM public.create_player_message(
    v_defender_id,
    NULL,
    'Defensas destruidas por misiles interplanetarios',
    format(
      'Objetivo: %s (G%d S%d P%d)%sIPM recibidos: %s%sABM interceptados: %s%sDefensas destruidas: %s',
      v_target.name, v_target.galaxy, v_target.system, v_target.position,
      E'\n', v_ipm, E'\n', v_intercepted, E'\n', v_total_killed
    ),
    'missile_defense:' || p_fleet_id::text
  );

  -- CIERRE: COMPLETED directo. NO hay viaje de vuelta (VERIFIED).
  UPDATE public.fleet_movements
  SET status = 'COMPLETED',
      returns_at = NULL
  WHERE id = p_fleet_id;

  DELETE FROM public.fleet_movement_ships WHERE fleet_id = p_fleet_id;

  RETURN QUERY SELECT v_ipm, v_intercepted, v_effective, v_power, v_total_killed;
END;
$$;


COMMENT ON FUNCTION public.resolve_missile_attack_arrival(uuid) IS
  'Liquida la llegada de un MISSILE_ATTACK en UNA transaccion: intercepcion ABM (padre primero), potencia, destruccion por prioridad, mensajes y COMPLETED sin retorno.';

-- ---------------------------------------------------------------------
-- 7. Exclusion de ABM/IPM del combate normal
--
-- VERIFIED: los misiles NO participan en combate. Se excluyen de las tres
-- superficies que hoy los incluirian sin filtro, para que un ATTACK, un
-- ACS o una defensa normal nunca los toquen ni los repare.
-- Se usa una unica funcion de predicado como fuente unica.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_missile_defense(p_defense_id text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$

-- 7a. get_combat_unit_snapshot
--
-- Superficie CERRADA (motor de combate). Cambio MINIMO y aditivo: una sola
-- linea de filtro en la consulta de defensas del defensor. No se altera
-- ninguna otra parte de la funcion, ni las naves, ni el atacante, ni los
-- valores devueltos para el resto de defensas.
CREATE OR REPLACE FUNCTION public.get_combat_unit_snapshot(p_battle_id uuid)
 RETURNS TABLE(side text, unit_type text, unit_id text, quantity bigint, attack numeric, shield numeric, hull numeric, total_attack numeric, total_shield numeric, total_hull numeric)
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_battle RECORD;
BEGIN

    SELECT
        cb.id,
        cb.fleet_id,
        cb.defender_planet_id
    INTO v_battle
    FROM public.combat_battles AS cb
    WHERE cb.id = p_battle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Batalla % no existe',
            p_battle_id;
    END IF;

    -- ========================================================
    -- ATACANTE
    -- ========================================================

    RETURN QUERY
    SELECT
        'ATTACKER'::text,
        'SHIP'::text,
        fms.ship_id::text,
        fms.quantity::bigint,
        sd.attack::numeric,
        sd.shield::numeric,
        sd.hull::numeric,
        (fms.quantity * sd.attack)::numeric,
        (fms.quantity * sd.shield)::numeric,
        (fms.quantity * sd.hull)::numeric
    FROM public.fleet_movement_ships AS fms
    JOIN public.ship_definitions AS sd
        ON sd.id = fms.ship_id
    WHERE fms.fleet_id = v_battle.fleet_id;

    -- ========================================================
    -- DEFENSOR: NAVES
    -- ========================================================

    RETURN QUERY
    SELECT
        'DEFENDER'::text,
        'SHIP'::text,
        ps.ship_id::text,
        ps.quantity::bigint,
        sd.attack::numeric,
        sd.shield::numeric,
        sd.hull::numeric,
        (ps.quantity * sd.attack)::numeric,
        (ps.quantity * sd.shield)::numeric,
        (ps.quantity * sd.hull)::numeric
    FROM public.planet_ships AS ps
    JOIN public.ship_definitions AS sd
        ON sd.id = ps.ship_id
    WHERE ps.planet_id = v_battle.defender_planet_id
      AND ps.quantity > 0;

    -- ========================================================
    -- DEFENSOR: DEFENSAS
    --
    -- Los misiles (ABM/IPM) NO participan en combate (VERIFIED OGameX).
    -- Se filtran aqui para que nunca aparezcan en el informe de batalla.
    -- ========================================================

    RETURN QUERY
    SELECT
        'DEFENDER'::text,
        'DEFENSE'::text,
        pd.defense_id::text,
        pd.quantity::bigint,
        dd.attack::numeric,

-- 7b. initialize_combat_unit_state
--
-- Superficie CERRADA. Cambio MINIMO: un filtro mas en el INSERT de
-- defensas del defensor. Si ABM/IPM no entran en combat_unit_state, no
-- pueden recibir daño, no mueren y no aparecen en el informe.
CREATE OR REPLACE FUNCTION public.initialize_combat_unit_state(p_battle_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_fleet_id uuid;
    v_planet_id uuid;
    v_round integer := 1;
    v_inserted integer := 0;
BEGIN

    SELECT
        cb.fleet_id,
        cb.defender_planet_id
    INTO
        v_fleet_id,
        v_planet_id
    FROM public.combat_battles cb
    WHERE cb.id = p_battle_id;

    IF v_fleet_id IS NULL THEN
        RAISE EXCEPTION
            'Batalla % no existe o no tiene fleet_id',
            p_battle_id;
    END IF;

    IF v_planet_id IS NULL THEN
        RAISE EXCEPTION
            'La batalla % no tiene planeta defensor',
            p_battle_id;
    END IF;

    /*
     * Evitamos duplicar la ronda inicial.
     */
    IF EXISTS (
        SELECT 1
        FROM public.combat_unit_state cus
        WHERE cus.battle_id = p_battle_id
          AND cus.round_number = v_round
    ) THEN
        RAISE EXCEPTION
            'El estado de combate ya fue inicializado para la batalla %',
            p_battle_id;
    END IF;

    -- ========================================================
    -- ATACANTE
    -- ========================================================

    INSERT INTO public.combat_unit_state (
        battle_id,
        round_number,
        side,
        unit_type,
        unit_id,
        quantity,
        quantity_alive,
        attack,
        shield_max,
        shield_current,
        structural_integrity,
        hull_max,
        hull_current
    )
    SELECT
        p_battle_id,
        v_round,
        'ATTACKER',
        'SHIP',
        fms.ship_id,
        fms.quantity,
        fms.quantity,
        sd.attack,
        sd.shield,
        sd.shield,
        sd.hull,
        sd.hull / 10,
        sd.hull / 10
    FROM public.fleet_movement_ships fms
    JOIN public.ship_definitions sd
        ON sd.id = fms.ship_id
    WHERE fms.fleet_id = v_fleet_id;

    -- ========================================================
    -- DEFENSOR — NAVES
    -- ========================================================

    INSERT INTO public.combat_unit_state (
        battle_id,
        round_number,
        side,
        unit_type,
        unit_id,
        quantity,
        quantity_alive,
        attack,
        shield_max,
        shield_current,
        structural_integrity,
        hull_max,
        hull_current
    )
    SELECT
        p_battle_id,
        v_round,
        'DEFENDER',
        'SHIP',
        ps.ship_id,
        ps.quantity,
        ps.quantity,

-- 7c. repair_defenses_after_combat
--
-- Superficie CERRADA. Cambio MINIMO: las perdidas de combate nunca pueden
-- incluir ABM/IPM (no entran en combate), pero el filtro se anade tambien
-- aqui para que la reparacion sea idempotente y no dependa del snapshot.
CREATE OR REPLACE FUNCTION public.repair_defenses_after_combat(p_battle_id uuid)
 RETURNS TABLE(defense_id text, destroyed_quantity bigint, repaired_quantity bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_battle public.combat_battles%ROWTYPE;
    v_loss record;
    v_repaired bigint;
    v_existing boolean;
BEGIN
    SELECT * INTO v_battle
    FROM public.combat_battles
    WHERE id = p_battle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Battle % not found', p_battle_id;
    END IF;

    IF v_battle.defender_planet_id IS NULL THEN
        RETURN;
    END IF;

    FOR v_loss IN
        SELECT l.unit_id, l.destroyed_quantity
        FROM public.calculate_combat_defense_losses(p_battle_id) l
        WHERE l.side = 'DEFENDER'
          AND l.destroyed_quantity > 0
          AND NOT public.is_missile_defense(l.unit_id)
    LOOP
        SELECT EXISTS (
            SELECT 1
            FROM public.combat_defense_repairs r
            WHERE r.battle_id = p_battle_id
              AND r.defense_id = v_loss.unit_id
        ) INTO v_existing;

        IF v_existing THEN
            CONTINUE;
        END IF;

        SELECT count(*)::bigint
        INTO v_repaired
        FROM generate_series(1, v_loss.destroyed_quantity) g
        WHERE random() < 0.70;

        INSERT INTO public.combat_defense_repairs (
            battle_id, planet_id, defense_id,
            destroyed_quantity, repaired_quantity
        )
        VALUES (
            p_battle_id,
            v_battle.defender_planet_id,
            v_loss.unit_id,
            v_loss.destroyed_quantity,
            v_repaired
        );

        UPDATE public.planet_defenses pd
        SET quantity = pd.quantity + v_repaired,
            updated_at = now()
        WHERE pd.planet_id = v_battle.defender_planet_id
          AND pd.defense_id = v_loss.unit_id;

        IF NOT FOUND AND v_repaired > 0 THEN
            INSERT INTO public.planet_defenses (planet_id, defense_id, quantity)
            VALUES (v_battle.defender_planet_id, v_loss.unit_id, v_repaired);
        END IF;

        defense_id := v_loss.unit_id;
        destroyed_quantity := v_loss.destroyed_quantity;
        repaired_quantity := v_repaired;
        RETURN NEXT;
    END LOOP;
END;
$function$;

-- ---------------------------------------------------------------------
-- 8. Gate de ranuras en la produccion de defensas
--
-- can_build_defense y start_defense comparten el mismo gate
-- (can_fit_missile_slots). Se reescriben cambiando SOLO la validacion
-- anadida: el resto de la logica (auth, ownership, recursos, cupulas,
-- tiempos) se conserva literal.
-- ---------------------------------------------------------------------

-- 8a. can_fit_missile_slots ya esta definido en el bloque 1/2.

-- 8b. start_demolition : D2
--
-- Superficie CERRADA. Cambio MINIMO y aditivo: una comprobacion antes de
-- encolar la reduccion de nivel. NO se destruyen misiles, NO se recortan
-- cantidades, NO hay overflow: la operacion se RECHAZA.
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
  -- El guard solo aplica al silo de misiles.
  IF p_building_id <> 'missile_silo' THEN
    RETURN true;
  END IF;

  v_resulting_capacity := GREATEST(COALESCE(p_target_level, 0), 0) * 10;
  v_used_slots := public.calculate_used_missile_slots(p_planet_id);

  -- D2: si los misiles ocupan mas ranuras de las que dejaria el silo
  -- resultante, la demolicion se bloquea.
  RETURN v_used_slots <= v_resulting_capacity;
END;
$$;

COMMENT ON FUNCTION public.can_demolish_missile_silo(uuid, text, integer) IS
  'D2: false si la demolicion dejaria menos ranuras que los misiles almacenados. No destruye ni recorta nada.';


        sd.attack,
        sd.shield,
        sd.shield,
        sd.hull,
        sd.hull / 10,
        sd.hull / 10
    FROM public.planet_ships ps
    JOIN public.ship_definitions sd
        ON sd.id = ps.ship_id
    WHERE ps.planet_id = v_planet_id
      AND ps.quantity > 0;

    -- ========================================================
    -- DEFENSOR — DEFENSAS
    --
    -- Los misiles (ABM/IPM) quedan FUERA del estado de combate (VERIFIED).
    -- ========================================================

    INSERT INTO public.combat_unit_state (
        battle_id,
        round_number,
        side,
        unit_type,
        unit_id,
        quantity,
        quantity_alive,
        attack,
        shield_max,
        shield_current,
        structural_integrity,
        hull_max,
        hull_current
    )
    SELECT
        p_battle_id,
        v_round,
        'DEFENDER',
        'DEFENSE',
        pd.defense_id,
        pd.quantity,
        pd.quantity,
        dd.attack,
        dd.shield,
        dd.shield,
        dd.hull,
        dd.hull / 10,
        dd.hull / 10
    FROM public.planet_defenses pd
    JOIN public.defense_definitions dd
        ON dd.id = pd.defense_id
    WHERE pd.planet_id = v_planet_id
      AND pd.quantity > 0
      AND NOT public.is_missile_defense(pd.defense_id);

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    /*
     * ROW_COUNT solo refleja el último INSERT,
     * así que devolvemos el total real.
     */
    SELECT count(*)::integer
    INTO v_inserted
    FROM public.combat_unit_state
    WHERE battle_id = p_battle_id
      AND round_number = v_round;

    RETURN v_inserted;
END;
$function$;

        dd.shield::numeric,
        dd.hull::numeric,
        (pd.quantity * dd.attack)::numeric,
        (pd.quantity * dd.shield)::numeric,
        (pd.quantity * dd.hull)::numeric
    FROM public.planet_defenses AS pd
    JOIN public.defense_definitions AS dd
        ON dd.id = pd.defense_id
    WHERE pd.planet_id = v_battle.defender_planet_id
      AND pd.quantity > 0
      AND NOT public.is_missile_defense(pd.defense_id);

END;
$function$;

  SELECT p_defense_id IN ('interplanetary_missile','anti_ballistic_missile');
$$;

COMMENT ON FUNCTION public.is_missile_defense(text) IS
  'True para ABM e IPM: se excluyen del combate normal (VERIFIED).';


