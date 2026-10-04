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
-- 20260930220000_missile_definitions_and_capacity.sql
--
-- MISSILE SYSTEM (bloque 1/2): Missile Silo + ABM + IPM, catalogo,
-- prerrequisitos y modelo de capacidad por ranuras.
--
-- PRODUCT DECISIONS (cerradas, no reabrir):
--   D1  Silo 60s / time_factor 2 ; ABM 60s ; IPM 60s
--   D2  demolicion BLOQUEADA si used_slots > resulting_capacity
--   D3  prioridad fija = cheapest (0) ; sin selector de UI
--   D4  orden metal+crystal ASC + desempate tecnico estable
--   D5  reutilizar la convencion LGI de casco (hull) ; sin motor paralelo
--
-- VERIFIED FROM OGAMEX (docs/systems/README_MISSILE_SYSTEM.md):
--   Silo 20000/20000/1000, cost_factor 2, shipyard 1, PLANET+MOON
--   ABM  8000/2000/0,      silo 2 + shipyard 1, 1 ranura, hull 800
--   IPM  12500/2500/10000, silo 4 + shipyard 1 + impulse_drive 1,
--        2 ranuras, hull 1500, attack 12000
--   capacidad = silo_level * 10
--
-- Solo se anaden filas de catalogo y helpers de lectura. Ningun dato de
-- jugador se toca.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Catalogo: Missile Silo
-- ---------------------------------------------------------------------
INSERT INTO public.building_definitions
  (id, name, description, base_metal, base_crystal, base_deuterium,
   cost_factor, base_build_time_seconds, time_factor, valid_kinds, max_level)
VALUES
  ('missile_silo',
   'Silo de misiles',
   'Almacena misiles antibalisticos e interplanetarios. Cada nivel '
   || 'aumenta 10 ranuras: un ABM ocupa 1 y un IPM ocupa 2.',
   20000, 20000, 1000,
   2, 60, 2, ARRAY['PLANET','MOON']::text[], NULL)
ON CONFLICT (id) DO UPDATE SET
  name                    = EXCLUDED.name,
  description             = EXCLUDED.description,
  base_metal              = EXCLUDED.base_metal,
  base_crystal            = EXCLUDED.base_crystal,
  base_deuterium          = EXCLUDED.base_deuterium,
  cost_factor             = EXCLUDED.cost_factor,
  base_build_time_seconds = EXCLUDED.base_build_time_seconds,
  time_factor             = EXCLUDED.time_factor,
  valid_kinds             = EXCLUDED.valid_kinds;

-- shipyard 1 (VERIFIED OGameX: GameObjectRequirement('shipyard', 1))
INSERT INTO public.building_prerequisites
  (building_id, prerequisite_building_id, required_level)
VALUES ('missile_silo', 'shipyard', 1)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- 2. Columnas de defensa: coste en ranuras y prioridad de objetivo
--
--   slots_per_unit  : ranuras de silo que ocupa UNA unidad
--   target_priority : codigo 0-9 de la prioridad de destruccion (§4 OGameX)
--
-- Van en defense_definitions y NO en una tabla paralela, para que el
-- coste en ranuras viva junto al resto de datos de la defensa (un solo
-- sitio de verdad, igual que el precio o el casco).
-- ---------------------------------------------------------------------
ALTER TABLE public.defense_definitions
  ADD COLUMN IF NOT EXISTS slots_per_unit integer NOT NULL DEFAULT 0;

ALTER TABLE public.defense_definitions
  ADD COLUMN IF NOT EXISTS target_priority integer NOT NULL DEFAULT 0;

ALTER TABLE public.defense_definitions
  DROP CONSTRAINT IF EXISTS defense_definitions_slots_per_unit_check;

ALTER TABLE public.defense_definitions
  ADD CONSTRAINT defense_definitions_slots_per_unit_check
  CHECK (slots_per_unit >= 0);

ALTER TABLE public.defense_definitions
  DROP CONSTRAINT IF EXISTS defense_definitions_target_priority_check;

ALTER TABLE public.defense_definitions
  ADD CONSTRAINT defense_definitions_target_priority_check
  CHECK (target_priority >= 0 AND target_priority <= 9);

-- Prioridades por tipo (VERIFIED §4.1). 0 = cheapest y 1 = expensive son
-- MODOS, no tipos, asi que ningun tipo real los lleva.
UPDATE public.defense_definitions SET target_priority = 2 WHERE id = 'rocket_launcher';
UPDATE public.defense_definitions SET target_priority = 3 WHERE id = 'light_laser';
UPDATE public.defense_definitions SET target_priority = 4 WHERE id = 'heavy_laser';
UPDATE public.defense_definitions SET target_priority = 5 WHERE id = 'gauss_cannon';
UPDATE public.defense_definitions SET target_priority = 6 WHERE id = 'ion_cannon';
UPDATE public.defense_definitions SET target_priority = 7 WHERE id = 'plasma_turret';
UPDATE public.defense_definitions SET target_priority = 8 WHERE id = 'small_shield_dome';
UPDATE public.defense_definitions SET target_priority = 9 WHERE id = 'large_shield_dome';

-- ---------------------------------------------------------------------
-- 3. Catalogo: ABM e IPM
--
-- hull = integridad/10 (VERIFIED §7: el casco upstream de OGameX es el
-- casco LGI x 10, de modo que /10 deshace la convencion y el valor
-- resultante es exactamente el hull de LGI). El attack 12000 del IPM es
-- la potencia por misil verificada (§3.1).
-- ---------------------------------------------------------------------
INSERT INTO public.defense_definitions
  (id, name, description, metal_cost, crystal_cost, deuterium_cost,
   base_build_time, attack, shield, hull, slots_per_unit, target_priority)
VALUES
  ('anti_ballistic_missile',
   'Misil antibalistico',
   'Intercepta 1 misil interplanetario por unidad. No participa en combate.',
   8000, 2000, 0,
   60, 1, 1, 800, 1, 0),
  ('interplanetary_missile',
   'Misil interplanetario',
   'Ataca defensas a distancia sin combustible. No participa en combate.',
   12500, 2500, 10000,
   60, 12000, 1, 1500, 2, 0)
ON CONFLICT (id) DO UPDATE SET
  name            = EXCLUDED.name,
  description     = EXCLUDED.description,
  metal_cost      = EXCLUDED.metal_cost,
  crystal_cost    = EXCLUDED.crystal_cost,
  deuterium_cost  = EXCLUDED.deuterium_cost,
  base_build_time = EXCLUDED.base_build_time,
  attack          = EXCLUDED.attack,
  shield          = EXCLUDED.shield,
  hull            = EXCLUDED.hull,
  slots_per_unit  = EXCLUDED.slots_per_unit,
  target_priority = EXCLUDED.target_priority;

-- Prerrequisitos (VERIFIED §3 / §5). defense_prerequisites ya soporta
-- prerequisite_type IN ('building','research').
INSERT INTO public.defense_prerequisites
  (defense_id, prerequisite_type, building_id, research_id, required_level)
VALUES
  ('anti_ballistic_missile',  'building', 'missile_silo', NULL, 2),
  ('anti_ballistic_missile',  'building', 'shipyard',     NULL, 1),
  ('interplanetary_missile',  'building', 'missile_silo', NULL, 4),
  ('interplanetary_missile',  'building', 'shipyard',     NULL, 1),
  ('interplanetary_missile',  'research', NULL, 'impulse_drive', 1);

-- ---------------------------------------------------------------------
-- 4. Helpers de capacidad (una sola autoridad)
-- ---------------------------------------------------------------------

-- Ranuras del silo de un cuerpo: nivel * 10.
-- Verificado: silo 0 => 0 ; silo 4 => 40.
CREATE OR REPLACE FUNCTION public.calculate_missile_silo_slots(p_planet_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT COALESCE((
    SELECT pb.level * 10
    FROM public.planet_buildings pb
    WHERE pb.planet_id = p_planet_id
      AND pb.building_id = 'missile_silo'
  ), 0);
$$;

COMMENT ON FUNCTION public.calculate_missile_silo_slots(uuid) IS
  'Ranuras de silo = nivel del silo * 10. Fuente unica de verdad de la capacidad.';

-- Ranuras YA OCUPADAS por el inventario de misiles del cuerpo.
CREATE OR REPLACE FUNCTION public.calculate_used_missile_slots(p_planet_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT COALESCE((
    SELECT SUM(pd.quantity * dd.slots_per_unit)
    FROM public.planet_defenses pd
    JOIN public.defense_definitions dd ON dd.id = pd.defense_id
    WHERE pd.planet_id = p_planet_id
      AND pd.quantity > 0
      AND dd.slots_per_unit > 0
  ), 0);
$$;

COMMENT ON FUNCTION public.calculate_used_missile_slots(uuid) IS
  'Ranuras ocupadas por ABM (1) e IPM (2) ya presentes en planet_defenses.';

-- Ranuras comprometidas por la cola de defensas: incluye lo encolado,
-- igual que OGameX (las defensas en produccion todavia ocupan ranuras).
CREATE OR REPLACE FUNCTION public.calculate_queued_missile_slots(p_planet_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT COALESCE((
    SELECT SUM(dq.quantity * dd.slots_per_unit)
    FROM public.defense_queue dq
    JOIN public.defense_definitions dd ON dd.id = dq.defense_id
    WHERE dq.planet_id = p_planet_id
      AND dq.status = 'BUILDING'
      AND dd.slots_per_unit > 0
  ), 0);
$$;

-- Ranuras libres = capacidad - ocupadas - encoladas. Nunca negativo.
CREATE OR REPLACE FUNCTION public.calculate_free_missile_slots(p_planet_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER

-- Verificacion server-side de que N unidades de una defensa caben.
-- used_slots + queued + requested <= capacity  (VERIFIED §7)
CREATE OR REPLACE FUNCTION public.can_fit_missile_slots(
  p_planet_id uuid,
  p_defense_id text,
  p_quantity    bigint
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_slots_per_unit integer;
  v_requested      integer;
  v_occupied       integer;
  v_capacity       integer;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RETURN false;
  END IF;

  SELECT COALESCE(dd.slots_per_unit, 0)
  INTO v_slots_per_unit
  FROM public.defense_definitions dd
  WHERE dd.id = p_defense_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- Las defensas sin ranuras (las 8 actuales) no tienen gate de silo.
  IF v_slots_per_unit = 0 THEN
    RETURN true;
  END IF;

  v_requested := v_slots_per_unit * p_quantity::integer;
  v_capacity  := public.calculate_missile_silo_slots(p_planet_id);
  v_occupied  := public.calculate_used_missile_slots(p_planet_id)
                 + public.calculate_queued_missile_slots(p_planet_id);

  RETURN v_occupied + v_requested <= v_capacity;
END;
$$;

COMMENT ON FUNCTION public.can_fit_missile_slots(uuid, text, bigint) IS
  'Gate de ranuras del silo: occupied + queued + requested <= capacity. Sin exception, para poderlo usar en can_build_defense.';

-- Razon legible del rechazo de capacidad.
CREATE OR REPLACE FUNCTION public.missile_slot_rejection_reason(
  p_planet_id uuid,
  p_defense_id text,
  p_quantity    bigint
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_slots_per_unit integer;
  v_capacity       integer;
  v_free           integer;
BEGIN
  IF public.can_fit_missile_slots(p_planet_id, p_defense_id, p_quantity) THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(dd.slots_per_unit, 0) INTO v_slots_per_unit
  FROM public.defense_definitions dd WHERE dd.id = p_defense_id;

  v_capacity := public.calculate_missile_silo_slots(p_planet_id);
  v_free     := public.calculate_free_missile_slots(p_planet_id);

  RETURN format(
    'Missile silo capacity exceeded: level %s => %s slots, %s free, requested %s unit(s) x %s slot(s)',
    v_capacity / 10, v_capacity, v_free,
    COALESCE(p_quantity, 0), v_slots_per_unit);
END;
$$;

SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT GREATEST(
    public.calculate_missile_silo_slots(p_planet_id)
    - public.calculate_used_missile_slots(p_planet_id)
    - public.calculate_queued_missile_slots(p_planet_id),
    0);
$$;

