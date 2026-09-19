-- Reconcile out-of-band fleet mission-speed and universe-monitor ACL provenance.
-- 2026-09-19
-- Forward provenance only: the live end state already existed; this migration
-- re-asserts it idempotently so the state is reproducible from migration history.
-- Supersedes the four unledgered origin/main migration files from the integration merge.

ALTER TABLE public.universes
  ADD COLUMN IF NOT EXISTS peaceful_fleet_speed numeric NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS war_fleet_speed numeric NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS holding_fleet_speed numeric NOT NULL DEFAULT 1;

UPDATE public.universes
SET peaceful_fleet_speed = COALESCE(NULLIF(peaceful_fleet_speed, 1), fleet_speed),
    war_fleet_speed = COALESCE(NULLIF(war_fleet_speed, 1), fleet_speed),
    holding_fleet_speed = COALESCE(NULLIF(holding_fleet_speed, 1), fleet_speed);

CREATE OR REPLACE FUNCTION public.calculate_mission_fleet_speed_multiplier(
    p_universe_id uuid,
    p_mission_type text
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_mission text := upper(coalesce(p_mission_type, 'TRANSPORT'));
    v_speed numeric;
BEGIN
    SELECT CASE
        WHEN v_mission IN ('TRANSPORT','DEPLOY','COLONIZE','EXPEDITION') THEN peaceful_fleet_speed
        WHEN v_mission IN ('ATTACK','ESPIONAGE','RECYCLE','RECYCLE_ATTACK','HARVEST') THEN war_fleet_speed
        WHEN v_mission IN ('ACS_HOLD','HOLDING','DEFEND') THEN holding_fleet_speed
        ELSE fleet_speed
    END
    INTO v_speed
    FROM public.universes
    WHERE id = p_universe_id;

    IF v_speed IS NULL OR v_speed <= 0 THEN
        RAISE EXCEPTION 'Invalid fleet speed for mission %', v_mission;
    END IF;

    RETURN v_speed;
END
$function$;

CREATE OR REPLACE FUNCTION public.calculate_player_fleet_fuel_for_distance(
    p_distance numeric,
    p_flight_time_seconds numeric,
    p_player_id uuid,
    p_ship_id text,
    p_quantity bigint,
    p_speed_percent numeric DEFAULT 100
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ship_speed numeric;
    v_base_consumption numeric;
    v_fuel_reduction numeric := 0;
    v_spd numeric;
    v_consumption numeric;
BEGIN
    IF p_distance < 0 OR p_flight_time_seconds <= 0 OR p_quantity <= 0 OR p_speed_percent <= 0
    THEN
        RAISE EXCEPTION 'Invalid fleet fuel parameters';
    END IF;

    v_base_consumption := public.calculate_player_ship_fuel_consumption(p_player_id, p_ship_id);
    v_ship_speed := public.calculate_player_ship_speed(p_player_id, p_ship_id);
    v_spd := 35000 / greatest(p_flight_time_seconds * p_speed_percent * 10 - 10, 1)
        * sqrt(p_distance * 10 / greatest(v_ship_speed, 1));
    v_consumption := p_quantity * v_base_consumption * p_distance / 35000
        * power((v_spd / 10) + 1, 2);
    v_fuel_reduction := least(
        greatest(coalesce(public.get_player_lifeform_effect(p_player_id, 'fuel_reduction_percent'), 0), 0),
        30
    );
    v_consumption := v_consumption * greatest(0, 1 - v_fuel_reduction / 100);

    RETURN greatest(1, ceil(v_consumption));
END
$function$;

REVOKE EXECUTE ON FUNCTION public.calculate_mission_fleet_speed_multiplier(uuid, text)
  FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.get_universe_evolution_monitor(uuid)
  FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.get_universe_evolution_monitor_public(uuid)
  FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_universe_evolution_monitor_public(uuid)
  TO anon, authenticated;
