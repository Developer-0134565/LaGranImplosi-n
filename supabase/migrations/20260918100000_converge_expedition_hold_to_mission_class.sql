-- =============================================================================
-- CONVERGE EXPEDITION HOLD/DELAY TO THE CANONICAL MISSION SPEED CLASS
-- -----------------------------------------------------------------------------
-- Fleet sweep 2026-09-18 (finding): calculate_expedition_delay_seconds resolved
-- the universe multiplier from the LEGACY generic column universes.fleet_speed
-- instead of the canonical mission classifier. EXPEDITION belongs to the PEACEFUL
-- class, so the authoritative multiplier is
--     public.calculate_mission_fleet_speed_multiplier(universe_id, 'EXPEDITION')
-- (-> peaceful_fleet_speed), exactly like every dispatch RPC does.
--
-- Why it is a divergence: it made the expedition hold/delay the only LIVE path
-- that still used universes.fleet_speed as a universal multiplier.
--
-- Numeric impact on live data: NONE today — fleet_speed = peaceful_fleet_speed = 1
-- in both live universes (verified LIVE 2026-09-18), so the returned delay is
-- identical before/after. This is an architectural convergence, not a balance change.
--
-- Untouched: signature, volatility (STABLE), SECURITY INVOKER (no new DEFINER
-- surface), ACLs, holding base (3600 s), multiplier set (2/3/5), evolution factor
-- (calculate_universe_scaling(E).fleet_movement_scale = E^(1/3)) and the
-- time-anchored evolution read (calculate_universe_evolution_rate_at).
-- =============================================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.calculate_expedition_delay_seconds(p_fleet_id uuid, p_multiplier numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_universe_id uuid;
    v_fleet_speed numeric;
    v_evolution numeric;
    v_fleet_scale numeric;
    v_fleet_rate numeric;
    v_holding_seconds numeric := 3600;
    v_additional_delay numeric;
    v_arrives_at timestamptz;
BEGIN
    IF p_multiplier NOT IN (2,3,5) THEN
        RAISE EXCEPTION 'Delay multiplier must be 2, 3 or 5';
    END IF;
    SELECT p.universe_id, fm.arrives_at
    INTO v_universe_id, v_arrives_at
    FROM public.fleet_movements fm
    JOIN public.planets p ON p.id = fm.origin_planet_id
    WHERE fm.id = p_fleet_id AND fm.mission_type = 'EXPEDITION';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Expedition fleet % not found', p_fleet_id;
    END IF;

    -- Canonical mission speed class (EXPEDITION -> peaceful_fleet_speed).
    v_fleet_speed := public.calculate_mission_fleet_speed_multiplier(v_universe_id, 'EXPEDITION');

    v_evolution := public.calculate_universe_evolution_rate_at(v_universe_id, v_arrives_at);
    SELECT fleet_movement_scale INTO v_fleet_scale
    FROM public.calculate_universe_scaling(v_evolution);
    v_fleet_rate := v_fleet_speed * v_fleet_scale;
    v_additional_delay := floor((v_holding_seconds * p_multiplier) / v_fleet_rate);
    RETURN greatest(v_additional_delay, 1);
END;
$function$;

COMMIT;
