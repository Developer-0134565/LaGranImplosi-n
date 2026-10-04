-- Sibling of 20260930240000: the same "past event + already-advanced planet clock" trap also froze
-- ARRIVED movements, so the cargo was never delivered and the fleet never advanced.
--
-- THE DEFECT (measured on LIVE, 2026-09-30)
--   `resolve_transport_arrival` / `resolve_deploy_arrival` settle the DESTINATION with
--       update_planet_resources_until(destination_planet_id, v_fleet.arrives_at)
--   and `resolve_expedition_return` settles the ORIGIN with `v_return_at`. The settlement guard
--   correctly refuses to move a planet's clock backwards, so when that body's clock had already been
--   advanced past the event timestamp (an ordinary player action such as start_building /
--   cancel_building / load_fleet_cargo / the merchant, or the UI's sync_current_planet_resources) the
--   call raised, and the per-fleet handler in process_fleet_movements downgraded it to a WARNING.
--   Nothing rolled back and nothing surfaced, so the movement stayed 'ARRIVED' forever.
--   Measured: transport with arrives_at 2h in the past against a destination already settled to
--   now() => status ARRIVED, forever, cargo never delivered.
--
-- THE FIX
--   One clamp each: greatest(<event timestamp>, last_calculated_at). When the event is still in the
--   FUTURE -- the normal certified path -- this is a no-op and the arrival-time anchoring is
--   byte-identical. When it is behind, there is no elapsed time left to credit, so settling at the
--   current clock grants zero extra production and lets the delivery finish.
--
-- NOT CHANGED: delivered amounts, arrival-event anchoring, costs, times, the settlement guard itself,
-- and every deployed function SIGNATURE (resolve_deploy_arrival keeps `transferred_ships`).

create or replace function public.resolve_transport_arrival(p_fleet_id uuid)
returns table(fleet_id uuid, destination_planet_id uuid, delivered_metal numeric, delivered_crystal numeric, delivered_deuterium numeric, status text, returns_at timestamptz)
language plpgsql
set search_path to 'public', 'pg_temp'
as $$
DECLARE
    v_fleet RECORD;
    v_duration interval;
    v_returns_at timestamptz;
    v_settle_at timestamptz;
BEGIN
    SELECT fm.id, fm.origin_planet_id, fm.destination_planet_id, fm.mission_type, fm.status,
           fm.started_at, fm.arrives_at, fm.metal, fm.crystal, fm.deuterium
    INTO v_fleet
    FROM public.fleet_movements fm
    WHERE fm.id = p_fleet_id
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'Fleet not found'; END IF;
    IF v_fleet.mission_type <> 'TRANSPORT' THEN RAISE EXCEPTION 'Fleet is not a TRANSPORT mission'; END IF;
    IF v_fleet.status <> 'ARRIVED' THEN RAISE EXCEPTION 'Transport must be ARRIVED. Current status: %', v_fleet.status; END IF;
    IF v_fleet.destination_planet_id IS NULL THEN RAISE EXCEPTION 'Transport has no destination'; END IF;

    v_duration := v_fleet.arrives_at - v_fleet.started_at;

    -- Settlement belongs to the event timestamp, not the worker execution time. This
    -- preserves offline production and prevents a late worker from granting
    -- production after the transport has already arrived.
    --
    -- FIX 2026-09-30: floor the anchor at the destination's own clock. A destination already settled
    -- past `arrives_at` used to raise forever (the worker only warns), freezing the cargo undelivered.
    SELECT greatest(v_fleet.arrives_at, pr.last_calculated_at) INTO v_settle_at
      FROM public.planet_resources pr WHERE pr.planet_id = v_fleet.destination_planet_id;

    PERFORM public.update_planet_resources_until(
        v_fleet.destination_planet_id,
        coalesce(v_settle_at, v_fleet.arrives_at)
    );

    UPDATE public.planet_resources pr
    SET metal = pr.metal + v_fleet.metal,
        crystal = pr.crystal + v_fleet.crystal,
        deuterium = pr.deuterium + v_fleet.deuterium,
        updated_at = clock_timestamp()
    WHERE pr.planet_id = v_fleet.destination_planet_id;

    IF NOT FOUND THEN RAISE EXCEPTION 'Destination planet resources not found'; END IF;

    -- Keep the scheduled timeline anchored to the original arrival event.
    v_returns_at := v_fleet.arrives_at + v_duration;

    UPDATE public.fleet_movements fm
    SET metal = 0,
        crystal = 0,
        deuterium = 0,
        status = 'RETURNING',
        returns_at = v_returns_at
    WHERE fm.id = p_fleet_id;

    RETURN QUERY
    SELECT v_fleet.id, v_fleet.destination_planet_id,
           v_fleet.metal, v_fleet.crystal, v_fleet.deuterium,
           'RETURNING'::text, v_returns_at;
END;
$$;

create or replace function public.resolve_deploy_arrival(p_fleet_id uuid)
returns table(fleet_id uuid, destination_planet_id uuid, transferred_ships bigint, status text)
language plpgsql
set search_path to 'public', 'pg_temp'
as $$
DECLARE
    v_fleet RECORD;
    v_total_ships bigint;
    v_settle_at timestamptz;
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
    --
    --     FIX 2026-09-30: floor the anchor at the destination's own clock so an already-settled
    --     destination cannot freeze the delivery forever.
    IF COALESCE(v_fleet.metal,0) <> 0
       OR COALESCE(v_fleet.crystal,0) <> 0
       OR COALESCE(v_fleet.deuterium,0) <> 0 THEN
        SELECT greatest(v_fleet.arrives_at, pr.last_calculated_at) INTO v_settle_at
          FROM public.planet_resources pr WHERE pr.planet_id = v_fleet.destination_planet_id;

        PERFORM public.update_planet_resources_until(
            v_fleet.destination_planet_id,
            coalesce(v_settle_at, v_fleet.arrives_at)
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
$$;

create or replace function public.resolve_expedition_return(p_fleet_id uuid)
returns table(fleet_id uuid, origin_planet_id uuid, delivered_metal numeric, delivered_crystal numeric, delivered_deuterium numeric, status text)
language plpgsql
set search_path to 'public', 'pg_temp'
as $$
DECLARE
    v_fleet RECORD;
    v_return_at timestamptz;
    v_settle_at timestamptz;
BEGIN
    SELECT fm.id, fm.origin_planet_id, fm.mission_type, fm.status,
           fm.metal, fm.crystal, fm.deuterium, fm.returns_at
    INTO v_fleet
    FROM public.fleet_movements fm
    WHERE fm.id = p_fleet_id
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'Fleet not found: %', p_fleet_id; END IF;
    IF v_fleet.mission_type <> 'EXPEDITION' THEN RAISE EXCEPTION 'Fleet is not an EXPEDITION'; END IF;
    IF v_fleet.status <> 'RETURNING' THEN RAISE EXCEPTION 'Expedition must be RETURNING. Current status: %', v_fleet.status; END IF;

    v_return_at := COALESCE(v_fleet.returns_at, now());

    -- A late worker must settle the planet only through the scheduled return
    -- event. Later economic queue events are then processed chronologically by
    -- process_planet_tick/process_universe_tick instead of being skipped.
    --
    -- FIX 2026-09-30: floor the anchor at the origin's own clock so an already-settled origin cannot
    -- freeze the expedition (and lose its ships) forever.
    SELECT greatest(v_return_at, pr.last_calculated_at) INTO v_settle_at
      FROM public.planet_resources pr WHERE pr.planet_id = v_fleet.origin_planet_id;

    PERFORM public.update_planet_resources_until(v_fleet.origin_planet_id, coalesce(v_settle_at, v_return_at));

    INSERT INTO public.planet_ships(planet_id, ship_id, quantity)
    SELECT v_fleet.origin_planet_id, fms.ship_id, fms.quantity
    FROM public.fleet_movement_ships fms
    WHERE fms.fleet_id = p_fleet_id
    ON CONFLICT(planet_id, ship_id)
    DO UPDATE SET quantity = public.planet_ships.quantity + EXCLUDED.quantity;

    UPDATE public.planet_resources pr
    SET metal = pr.metal + v_fleet.metal,
        crystal = pr.crystal + v_fleet.crystal,
        deuterium = pr.deuterium + v_fleet.deuterium,
        updated_at = clock_timestamp()
    WHERE pr.planet_id = v_fleet.origin_planet_id;

    IF NOT FOUND THEN RAISE EXCEPTION 'Origin planet resources not found'; END IF;

    UPDATE public.fleet_movements
    SET metal = 0, crystal = 0, deuterium = 0, status = 'COMPLETED'
    WHERE id = p_fleet_id AND status = 'RETURNING';

    fleet_id := v_fleet.id;
    origin_planet_id := v_fleet.origin_planet_id;
    delivered_metal := v_fleet.metal;
    delivered_crystal := v_fleet.crystal;
    delivered_deuterium := v_fleet.deuterium;
    status := 'COMPLETED';
    RETURN NEXT;
END;
$$;

-- Self-verifying: each clamp is present, the guard is untouched, and the signatures are unchanged.
do $post$
declare v_src text; v_guard text; v_ret text;
begin
  foreach v_src in array array[
    'resolve_transport_arrival','resolve_deploy_arrival','resolve_expedition_return' ]
  loop
    if (select p.prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname=v_src) not ilike '%last_calculated_at%' then
      raise exception 'POSTCONDITION FAILED: % is not clamped', v_src;
    end if;
  end loop;

  select pg_get_function_result(p.oid) into v_ret from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='resolve_deploy_arrival';
  if v_ret not ilike '%transferred_ships%' then
    raise exception 'POSTCONDITION FAILED: the deploy signature changed (%s)', v_ret;
  end if;

  select p.prosrc into v_guard from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='update_planet_resources_until_raw';
  if v_guard not ilike '%INVALID_RESOURCE_TIMESTAMP%' then
    raise exception 'POSTCONDITION FAILED: the settlement guard was weakened';
  end if;
end $post$;