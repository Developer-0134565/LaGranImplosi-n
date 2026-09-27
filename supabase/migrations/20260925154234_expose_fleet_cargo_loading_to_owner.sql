-- EXPOSE FLEET CARGO LOADING TO THE FLEET OWNER — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- LGI's cargo model is POST-DISPATCH and deliberate: the fleet exists and is OUTBOUND.
-- `load_fleet_cargo` already implemented the economy contract (production settlement, capacity
-- check, availability check, FOR UPDATE locks, planet debit + fleet credit) but had NO identity or
-- ownership gate and NO client EXECUTE grant, so no player could ever use it (0 callers, 0 grants).
--
-- This migration adds ONLY the missing authority layer and the client grant:
--   * auth.uid() is mandatory;
--   * the fleet's player must belong to auth.uid();
--   * the fleet's origin planet must belong to that same player (defence in depth);
--   * the mission must be one whose settlement preserves/delivers the cargo;
--   * EXECUTE -> authenticated + service_role (PUBLIC/anon revoked).
--
-- The economy logic is preserved verbatim: capacity via calculate_fleet_cargo_capacity (per-ship
-- cargo_capacity + hyperspace_technology 5%/level), availability via planet_resources FOR UPDATE,
-- additive credit to fleet_movements.metal/crystal/deuterium.
--
-- OGameX reference (design source for the behaviour LGI lacked): resources are validated against the
-- planet's availability and the fleet's TOTAL cargo capacity and then travel with the mission
-- (GameMission::start / startMissionSanityChecks; PlanetService::deductResourcesAndUnitsAtomic).
-- LGI keeps its own post-dispatch loader (deliberate custom mechanic) instead of dispatch-time
-- parameters; the observable outcome is equivalent for the missions whitelisted below.
--
-- Missions deliberately NOT whitelisted (evidence in docs/systems/README_FLEET_ENGINE.md §24):
--   DEPLOY     -> resolve_deploy_arrival transfers ships only; the cargo would be stranded
--   COLONIZE   -> resolve_colonize_arrival completes the fleet without delivering resources
--                 (OGameX delivers them: ColonisationMission:125-126)
--   RECYCLE    -> the fleet worker SETS metal/crystal to the harvested debris (cargo overwritten)
--   EXPEDITION -> the RESOURCES outcome SETS the cargo to the find (OGameX ADDS it)
--   ATTACK     -> LGI fleet cargo is not part of the battle model; the certified loot contract
--                 (PG-09) ignores pre-loaded cargo, while OGameX caps the return with surviving
--                 cargo capacity -> would require a combat-domain product decision

CREATE OR REPLACE FUNCTION public.load_fleet_cargo(
    p_fleet_id uuid,
    p_metal numeric DEFAULT 0,
    p_crystal numeric DEFAULT 0,
    p_deuterium numeric DEFAULT 0
)
RETURNS TABLE(fleet_id uuid, metal numeric, crystal numeric, deuterium numeric, total_cargo numeric, cargo_capacity numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_auth_user uuid := auth.uid();
    v_fleet RECORD;
    v_owner uuid;
    v_resources RECORD;
    v_capacity numeric;
    v_existing numeric;
    v_total numeric;
BEGIN
    -- 1. Identity: the caller must be an authenticated Supabase user.
    IF v_auth_user IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    IF p_metal < 0 OR p_crystal < 0 OR p_deuterium < 0 THEN
        RAISE EXCEPTION 'Cargo cannot be negative';
    END IF;

    SELECT fm.id, fm.player_id, fm.origin_planet_id, fm.status, fm.mission_type,
           fm.metal, fm.crystal, fm.deuterium
    INTO v_fleet
    FROM public.fleet_movements fm
    WHERE fm.id = p_fleet_id
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'Fleet not found'; END IF;

    -- 2. Ownership: the fleet belongs to a player owned by the authenticated user.
    SELECT pl.id INTO v_owner
    FROM public.players pl
    WHERE pl.id = v_fleet.player_id
      AND pl.user_id = v_auth_user;

    IF v_owner IS NULL THEN
        RAISE EXCEPTION 'Fleet does not belong to authenticated user';
    END IF;

    -- 3. Defence in depth: the cargo is debited from the fleet's own origin planet.
    IF NOT EXISTS (
        SELECT 1 FROM public.planets p
        WHERE p.id = v_fleet.origin_planet_id
          AND p.player_id = v_fleet.player_id
          AND NOT p.is_destroyed
    ) THEN
        RAISE EXCEPTION 'CARGO_ORIGIN_NOT_OWNED';
    END IF;

    -- 4. Lifecycle: cargo may only be loaded while the fleet is OUTBOUND.
    IF v_fleet.status <> 'OUTBOUND' THEN
        RAISE EXCEPTION 'Cargo can only be loaded while fleet is OUTBOUND';
    END IF;

    -- 5. Mission eligibility: only missions whose settlement preserves or delivers the cargo.
    IF v_fleet.mission_type NOT IN ('TRANSPORT','ESPIONAGE','ACS_HOLD') THEN
        RAISE EXCEPTION 'CARGO_MISSION_NOT_SUPPORTED: mission % cannot carry loaded cargo', v_fleet.mission_type;
    END IF;

    PERFORM public.update_planet_resources_until(v_fleet.origin_planet_id, now());

    v_capacity := public.calculate_fleet_cargo_capacity(p_fleet_id);
    v_existing := COALESCE(v_fleet.metal,0) + COALESCE(v_fleet.crystal,0) + COALESCE(v_fleet.deuterium,0);
    v_total := v_existing + p_metal + p_crystal + p_deuterium;
    IF v_total > v_capacity THEN
        RAISE EXCEPTION 'Cargo exceeds fleet capacity: % / %', v_total, v_capacity;
    END IF;

    SELECT pr.metal, pr.crystal, pr.deuterium
    INTO v_resources
    FROM public.planet_resources pr
    WHERE pr.planet_id = v_fleet.origin_planet_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Planet resources not found'; END IF;

    IF v_resources.metal < p_metal THEN RAISE EXCEPTION 'Insufficient metal'; END IF;
    IF v_resources.crystal < p_crystal THEN RAISE EXCEPTION 'Insufficient crystal'; END IF;
    IF v_resources.deuterium < p_deuterium THEN RAISE EXCEPTION 'Insufficient deuterium'; END IF;

    UPDATE public.planet_resources pr
    SET metal = pr.metal - p_metal,
        crystal = pr.crystal - p_crystal,
        deuterium = pr.deuterium - p_deuterium,
        updated_at = now()
    WHERE pr.planet_id = v_fleet.origin_planet_id;

    UPDATE public.fleet_movements fm
    SET metal = fm.metal + p_metal,
        crystal = fm.crystal + p_crystal,
        deuterium = fm.deuterium + p_deuterium
    WHERE fm.id = p_fleet_id;

    RETURN QUERY
    SELECT fm.id, fm.metal, fm.crystal, fm.deuterium,
           fm.metal + fm.crystal + fm.deuterium, v_capacity
    FROM public.fleet_movements fm
    WHERE fm.id = p_fleet_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.load_fleet_cargo(uuid, numeric, numeric, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.load_fleet_cargo(uuid, numeric, numeric, numeric) FROM anon;
GRANT EXECUTE ON FUNCTION public.load_fleet_cargo(uuid, numeric, numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.load_fleet_cargo(uuid, numeric, numeric, numeric) TO service_role;
