-- COMPLETE THE FLEET CARGO LIFECYCLE — DEPLOY / COLONIZE / EXPEDITION — LA GRAN IMPLOSIÓN
-- --------------------------------------------------------------------------------------------
-- `load_fleet_cargo` already exposes the post-dispatch cargo contract, but three arrival handlers
-- still left, lost or overwrote a VALID carried cargo. This migration fixes ONLY those handlers.
--
-- Evidence (deployed bodies read read-only before the change):
--   resolve_deploy_arrival    transferred ships only, then status=COMPLETED + returns_at=NULL:
--                             the cargo stayed on a COMPLETED row and was never delivered (stranded).
--   resolve_colonize_arrival  created the colony with planet_resources = 0/0/0 and completed the
--                             fleet: the cargo was lost.
--   resolve_expedition_arrival (outcome RESOURCES) did `UPDATE fleet_movements SET metal=<find>,...`:
--                             a SET that destroyed any pre-existing cargo (including the other two
--                             resources, which were forced to 0). Only ONE `metal=` assignment exists
--                             in that body, and no other expedition helper writes fleet_movements
--                             resources, so cargo cannot be clobbered anywhere else.
--
-- OGameX reference (design source): DeploymentMission:83-85 delivers the mission resources to the
-- destination planet; ColonisationMission:125-126 delivers them to the newly created colony;
-- ExpeditionMission:218-220 computes `mission->metal + returnResources->metal` (ADD, never SET).
--
-- NOT touched by this migration: ATTACK (out of scope, pending product decision), RECYCLE (its worker
-- intentionally SETs the harvested debris), ACS_HOLD/HOLDING/DEFEND, PG-09 loot semantics, the cargo
-- calculation helpers (`load_fleet_cargo`, `calculate_fleet_cargo_capacity`,
-- `calculate_player_ship_cargo_capacity`) beyond the mission whitelist, and the frontend.
--
-- Idempotency: DEPLOY and COLONIZE keep their ARRIVED→COMPLETED state guard (a replay raises, so the
-- delivery is never applied twice) and resolve_expedition_arrival keeps its `expedition_results`
-- early return (a replay of the same fleet never reaches the resource UPDATE again).

-- 1) DEPLOY — deliver the carried cargo to the destination planet, then complete the fleet with
--    zeroed cargo (it has been unloaded).
CREATE OR REPLACE FUNCTION public.resolve_deploy_arrival(p_fleet_id uuid)
 RETURNS TABLE(fleet_id uuid, destination_planet_id uuid, transferred_ships bigint, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_fleet RECORD;
    v_total_ships bigint;
BEGIN

    SELECT
        fm.id,
        fm.destination_planet_id,
        fm.mission_type,
        fm.status,
        fm.arrives_at,
        fm.metal,
        fm.crystal,
        fm.deuterium
    INTO v_fleet
    FROM public.fleet_movements AS fm
    WHERE fm.id = p_fleet_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Fleet not found';
    END IF;

    IF v_fleet.mission_type <> 'DEPLOY' THEN
        RAISE EXCEPTION 'Fleet is not a DEPLOY mission';
    END IF;

    IF v_fleet.status <> 'ARRIVED' THEN
        RAISE EXCEPTION
            'Deploy must be ARRIVED. Current status: %',
            v_fleet.status;
    END IF;

    IF v_fleet.destination_planet_id IS NULL THEN
        RAISE EXCEPTION 'Deploy has no destination';
    END IF;

    SELECT
        COALESCE(SUM(fms.quantity), 0)
    INTO v_total_ships
    FROM public.fleet_movement_ships AS fms
    WHERE fms.fleet_id = p_fleet_id;

    -- 1a. Deliver the carried cargo to the destination planet. The destination economy is settled
    --     through the arrival event first (same pattern as resolve_transport_arrival), so the credit
    --     is anchored to the mission timeline and never to the worker execution time.
    IF COALESCE(v_fleet.metal,0) <> 0
       OR COALESCE(v_fleet.crystal,0) <> 0
       OR COALESCE(v_fleet.deuterium,0) <> 0 THEN
        PERFORM public.update_planet_resources_until(
            v_fleet.destination_planet_id,
            v_fleet.arrives_at
        );

        UPDATE public.planet_resources pr
        SET metal = pr.metal + v_fleet.metal,
            crystal = pr.crystal + v_fleet.crystal,
            deuterium = pr.deuterium + v_fleet.deuterium,
            updated_at = clock_timestamp()
        WHERE pr.planet_id = v_fleet.destination_planet_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Destination planet resources not found';
        END IF;
    END IF;

    -- 1b. Transfer the ships (unchanged).
    INSERT INTO public.planet_ships (
        planet_id,
        ship_id,
        quantity
    )
    SELECT
        v_fleet.destination_planet_id,
        fms.ship_id,
        fms.quantity
    FROM public.fleet_movement_ships AS fms
    WHERE fms.fleet_id = p_fleet_id
    ON CONFLICT (planet_id, ship_id)
    DO UPDATE
    SET quantity =
        public.planet_ships.quantity
        + EXCLUDED.quantity;

    -- 1c. Complete the fleet and unload it (the cargo now lives in the destination planet).
    UPDATE public.fleet_movements AS fm
    SET
        status = 'COMPLETED',
        returns_at = NULL,
        metal = 0,
        crystal = 0,
        deuterium = 0
    WHERE fm.id = p_fleet_id;

    RETURN QUERY
    SELECT
        v_fleet.id,
        v_fleet.destination_planet_id,
        v_total_ships,
        'COMPLETED'::text;

END;
$function$;

-- 2) COLONIZE — seed the new colony with the carried cargo and unload the fleet.
CREATE OR REPLACE FUNCTION public.resolve_colonize_arrival(p_fleet_id uuid)
 RETURNS TABLE(fleet_id uuid, new_planet_id uuid, galaxy integer, system integer, "position" integer, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_fleet record;
    v_origin record;
    v_ship_qty bigint := 0;
    v_new uuid;
    v_fields integer := 100;
BEGIN
    SELECT fm.* INTO v_fleet FROM public.fleet_movements fm WHERE fm.id=p_fleet_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Fleet not found'; END IF;
    IF v_fleet.mission_type<>'COLONIZE' THEN RAISE EXCEPTION 'Fleet is not COLONIZE'; END IF;
    IF v_fleet.status<>'ARRIVED' THEN RAISE EXCEPTION 'Colonize must be ARRIVED'; END IF;
    IF v_fleet.destination_planet_id IS NOT NULL THEN RAISE EXCEPTION 'Colonize target must be an empty coordinate'; END IF;

    SELECT p.* INTO v_origin FROM public.planets p WHERE p.id=v_fleet.origin_planet_id FOR UPDATE;
    SELECT COALESCE(SUM(fms.quantity),0) INTO v_ship_qty
    FROM public.fleet_movement_ships fms
    WHERE fms.fleet_id=p_fleet_id AND fms.ship_id='colony_ship';
    IF v_ship_qty<=0 THEN RAISE EXCEPTION 'Colonize requires colony ship'; END IF;

    IF EXISTS(
        SELECT 1 FROM public.planets p
        WHERE p.universe_id=v_origin.universe_id
          AND p.galaxy=v_fleet.destination_galaxy
          AND p.system=v_fleet.destination_system
          AND p.position=v_fleet.destination_position
          AND NOT p.is_destroyed
    ) THEN
        -- A late worker must not extend the flight. The retry return is anchored
        -- to the original arrival event. The carried cargo is preserved: the fleet
        -- returns it to the origin through the generic RETURNING settlement.
        UPDATE public.fleet_movements fm
        SET status='RETURNING', returns_at=v_fleet.arrives_at+(fm.arrives_at-fm.started_at)
        WHERE fm.id=p_fleet_id;
        RETURN QUERY SELECT v_fleet.id,NULL::uuid,v_fleet.destination_galaxy,v_fleet.destination_system,v_fleet.destination_position,'RETURNING'::text;
        RETURN;
    END IF;

    INSERT INTO public.planets(
        universe_id,player_id,name,galaxy,system,position,
        temperature_min,temperature_max,fields_total,fields_used,is_homeworld,is_destroyed
    ) VALUES(
        v_origin.universe_id,v_fleet.player_id,
        'Colony '||v_fleet.destination_galaxy||':'||v_fleet.destination_system||':'||v_fleet.destination_position,
        v_fleet.destination_galaxy,v_fleet.destination_system,v_fleet.destination_position,
        -20,20,v_fields,0,false,false
    ) RETURNING id INTO v_new;

    -- 2a. The carried cargo seeds the new colony (OGameX: ColonisationMission delivers the mission
    --     resources to the created planet). A brand-new planet has no resources row yet, so this is
    --     its initial state; the ON CONFLICT branch only adds if a row somehow already existed.
    INSERT INTO public.planet_resources(planet_id,metal,crystal,deuterium)
    VALUES(v_new,COALESCE(v_fleet.metal,0),COALESCE(v_fleet.crystal,0),COALESCE(v_fleet.deuterium,0))
    ON CONFLICT(planet_id) DO UPDATE
       SET metal = public.planet_resources.metal + EXCLUDED.metal,
           crystal = public.planet_resources.crystal + EXCLUDED.crystal,
           deuterium = public.planet_resources.deuterium + EXCLUDED.deuterium,
           updated_at = clock_timestamp();

    DELETE FROM public.fleet_movement_ships
    WHERE fleet_id=p_fleet_id AND ship_id='colony_ship';

    -- 2b. The fleet is consumed by the colonisation; the delivered cargo is unloaded.
    UPDATE public.fleet_movements fm
    SET destination_planet_id=v_new,status='COMPLETED',returns_at=NULL,
        metal=0,crystal=0,deuterium=0
    WHERE fm.id=p_fleet_id;

    RETURN QUERY SELECT v_fleet.id,v_new,v_fleet.destination_galaxy,v_fleet.destination_system,v_fleet.destination_position,'COMPLETED'::text;
END;
$function$;

-- 3) EXPEDITION / RESOURCES — add the find to the carried cargo instead of overwriting it.
--    Exact-match, EOL-canonicalised substitution (same technique as migration 20260923095315).
DO $patch_expedition$
DECLARE
    v_def text;
    v_old text;
    v_new text;
    v_occ integer;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'resolve_expedition_arrival';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'CARGO-LIFECYCLE: resolve_expedition_arrival not found';
    END IF;

    v_old := $frag$   UPDATE public.fleet_movements SET metal=CASE WHEN v_reward.resource_type='METAL' THEN v_reward.final_resource_amount ELSE 0 END,crystal=CASE WHEN v_reward.resource_type='CRYSTAL' THEN v_reward.final_resource_amount ELSE 0 END,deuterium=CASE WHEN v_reward.resource_type='DEUTERIUM' THEN v_reward.final_resource_amount ELSE 0 END WHERE id=p_fleet_id;$frag$;

    v_new := $frag$   -- Carried cargo is REAL cargo: the find is ADDED to it, never a SET (OGameX adds
   -- the find to the mission resources as well). The expedition_results row below keeps recording
   -- ONLY the find, so the report, the reward tier and the weight accounting stay unchanged.
   UPDATE public.fleet_movements SET metal=COALESCE(metal,0)+CASE WHEN v_reward.resource_type='METAL' THEN v_reward.final_resource_amount ELSE 0 END,crystal=COALESCE(crystal,0)+CASE WHEN v_reward.resource_type='CRYSTAL' THEN v_reward.final_resource_amount ELSE 0 END,deuterium=COALESCE(deuterium,0)+CASE WHEN v_reward.resource_type='DEUTERIUM' THEN v_reward.final_resource_amount ELSE 0 END WHERE id=p_fleet_id;$frag$;

    v_old := replace(replace(v_old, chr(13)||chr(10), chr(10)), chr(13), '');
    v_new := replace(replace(v_new, chr(13)||chr(10), chr(10)), chr(13), '');
    IF position(chr(13)||chr(10) in v_def) > 0 THEN
        v_old := replace(v_old, chr(10), chr(13)||chr(10));
        v_new := replace(v_new, chr(10), chr(13)||chr(10));
    END IF;

    SELECT (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) INTO v_occ;
    IF v_occ <> 1 THEN
        RAISE EXCEPTION 'CARGO-LIFECYCLE: RESOURCES fragment matched % time(s), expected 1', v_occ;
    END IF;

    EXECUTE replace(v_def, v_old, v_new);
END;
$patch_expedition$;

-- 4) The three handlers above now preserve or deliver the cargo, so the mission whitelist of
--    load_fleet_cargo can admit DEPLOY / COLONIZE / EXPEDITION (OGameX allows resources on these
--    missions). ATTACK and RECYCLE stay excluded (out of scope by mission decision).
DO $patch_whitelist$
DECLARE
    v_def text;
    v_old text;
    v_new text;
    v_occ integer;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'load_fleet_cargo';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'CARGO-LIFECYCLE: load_fleet_cargo not found';
    END IF;

    v_old := $frag$    IF v_fleet.mission_type NOT IN ('TRANSPORT','ESPIONAGE','ACS_HOLD') THEN$frag$;
    v_new := $frag$    -- DEPLOY/COLONIZE/EXPEDITION are admitted once their handlers deliver the cargo
    -- (see the header of this migration); ATTACK and RECYCLE remain excluded.
    IF v_fleet.mission_type NOT IN ('TRANSPORT','ESPIONAGE','ACS_HOLD','DEPLOY','COLONIZE','EXPEDITION') THEN$frag$;

    v_old := replace(replace(v_old, chr(13)||chr(10), chr(10)), chr(13), '');
    v_new := replace(replace(v_new, chr(13)||chr(10), chr(10)), chr(13), '');
    IF position(chr(13)||chr(10) in v_def) > 0 THEN
        v_old := replace(v_old, chr(10), chr(13)||chr(10));
        v_new := replace(v_new, chr(10), chr(13)||chr(10));
    END IF;

    SELECT (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) INTO v_occ;
    IF v_occ <> 1 THEN
        RAISE EXCEPTION 'CARGO-LIFECYCLE: mission whitelist fragment matched % time(s), expected 1', v_occ;
    END IF;

    EXECUTE replace(v_def, v_old, v_new);
END;
$patch_whitelist$;
