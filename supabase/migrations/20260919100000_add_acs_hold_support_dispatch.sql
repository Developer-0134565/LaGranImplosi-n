-- ============================================================================
-- ACS_HOLD / HOLDING — FASE A (player-facing support dispatch)
-- ----------------------------------------------------------------------------
-- Scope of this migration (bounded):
--   1. repair the two legacy movement constraints that still blocked every
--      ACS_HOLD/HOLDING row (forward-only correction, no history edit);
--   2. durable holding window rule (holding_until > arrives_at);
--   3. minimal per-request idempotency key (no generic request infrastructure);
--   4. minimal explicit support-authorization policy (destination owner consent);
--   5. ONE support dispatcher: start_support_fleet(...) with support_mission=ACS_HOLD.
--
-- Explicitly NOT in this migration:
--   * DEFEND dispatch (BLOCKED BY COMBAT ENGINE — rejected inside the dispatcher);
--   * HOLDING as a player-facing mission (rejected as an internal lifecycle state);
--   * holding fuel tick (see README_FLEET_ENGINE §22: NOT IMPLEMENTED);
--   * maximum holding duration (product decision — no arbitrary constant invented);
--   * ACS combat integration and UI.
--
-- Canonical fleet pipeline reuse (no parallel formula is introduced here):
--   calculate_player_ship_speed -> calculate_mission_fleet_speed_multiplier(u,'ACS_HOLD')
--   -> E^(1/3) -> lifeform/item modifiers -> calculate_fleet_travel_time
--   -> calculate_player_fleet_fuel_for_distance
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Forward correction: the original table constraints still enforced the
--    7-mission / 5-status set, so the holding lifecycle introduced by
--    20260919053220_add_fleet_holding_lifecycle was unreachable in LIVE
--    (the newer constraints were added under different names).
--    The newer `*_check` constraints remain the single authority.
-- ---------------------------------------------------------------------------
ALTER TABLE public.fleet_movements
  DROP CONSTRAINT IF EXISTS fleet_movements_mission_type_chk;

ALTER TABLE public.fleet_movements
  DROP CONSTRAINT IF EXISTS fleet_movements_status_chk;

-- ---------------------------------------------------------------------------
-- 2. Holding window rule: a support movement must hold strictly after arrival.
--    The window is an absolute UTC timestamp; nothing is recalculated later.
-- ---------------------------------------------------------------------------
ALTER TABLE public.fleet_movements
  DROP CONSTRAINT IF EXISTS fleet_movements_holding_until_after_arrival_check;

ALTER TABLE public.fleet_movements
  ADD CONSTRAINT fleet_movements_holding_until_after_arrival_check
  CHECK (holding_until IS NULL OR holding_until > arrives_at);

-- ---------------------------------------------------------------------------
-- 3. Minimal idempotency: one durable key per player request.
--    Scope is intentionally limited to preventing a duplicated dispatch from
--    creating two movements (double ship/fuel deduction). No generic
--    request-key infrastructure is introduced.
-- ---------------------------------------------------------------------------
ALTER TABLE public.fleet_movements
  ADD COLUMN IF NOT EXISTS idempotency_key uuid NULL;

CREATE UNIQUE INDEX IF NOT EXISTS fleet_movements_player_idempotency_key_uq
  ON public.fleet_movements(player_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 4. Minimal explicit support-authorization policy.
--    L.G.I. has no alliance/buddy/consent structure in LIVE, so a destination
--    owner must grant an explicit, revocable, planet-scoped authorization to a
--    specific foreign player before that player can hold a fleet there.
--    Planet existence is NEVER treated as authorization.
--    This is a temporary product policy, not an imported social system.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.planet_support_authorizations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  destination_planet_id uuid NOT NULL REFERENCES public.planets(id) ON DELETE CASCADE,
  owner_player_id uuid NOT NULL REFERENCES public.players(id) ON DELETE CASCADE,
  guest_player_id uuid NOT NULL REFERENCES public.players(id) ON DELETE CASCADE,
  authorized_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NULL,
  revoked_at timestamptz NULL,
  CONSTRAINT planet_support_authorizations_distinct_players_check
    CHECK (owner_player_id <> guest_player_id),
  CONSTRAINT planet_support_authorizations_expiry_check
    CHECK (expires_at IS NULL OR expires_at > authorized_at),
  CONSTRAINT planet_support_authorizations_destination_guest_key
    UNIQUE (destination_planet_id, guest_player_id)
);

ALTER TABLE public.planet_support_authorizations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS deny_direct_api_access ON public.planet_support_authorizations;
CREATE POLICY deny_direct_api_access ON public.planet_support_authorizations
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

CREATE INDEX IF NOT EXISTS planet_support_authorizations_guest_idx
  ON public.planet_support_authorizations(guest_player_id)
  WHERE revoked_at IS NULL;

-- Grant: the destination owner explicitly authorises a foreign player.
CREATE OR REPLACE FUNCTION public.grant_planet_support_authorization(
  p_player_id uuid,
  p_planet_id uuid,
  p_guest_player_id uuid,
  p_expires_at timestamptz DEFAULT NULL
)
RETURNS TABLE(
  authorization_id uuid,
  destination_planet_id uuid,
  owner_player_id uuid,
  guest_player_id uuid,
  authorized_at timestamptz,
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_auth_user uuid := auth.uid();
  v_planet_owner uuid;
  v_id uuid;
begin
  if v_auth_user is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1 from public.players pl
    where pl.id = p_player_id and pl.user_id = v_auth_user
  ) then
    raise exception 'Player does not belong to authenticated user';
  end if;

  if p_planet_id is null or p_guest_player_id is null then
    raise exception 'Planet and guest player are required';
  end if;

  if p_guest_player_id = p_player_id then
    raise exception 'SUPPORT_AUTHORIZATION_SELF: a support authorization requires a foreign player';
  end if;

  select p.player_id into v_planet_owner
  from public.planets p
  where p.id = p_planet_id
    and not p.is_destroyed
  for update;

  if not found then
    raise exception 'PLANET_NOT_FOUND_OR_DESTROYED';
  end if;

  if v_planet_owner is distinct from p_player_id then
    raise exception 'PLANET_NOT_OWNED_BY_PLAYER';
  end if;

  if not exists (select 1 from public.players pl where pl.id = p_guest_player_id) then
    raise exception 'GUEST_PLAYER_NOT_FOUND';
  end if;

  if p_expires_at is not null and p_expires_at <= now() then
    raise exception 'SUPPORT_AUTHORIZATION_EXPIRY_IN_PAST';
  end if;

  insert into public.planet_support_authorizations(
    destination_planet_id, owner_player_id, guest_player_id, authorized_at, expires_at, revoked_at
  )
  values (
    p_planet_id, p_player_id, p_guest_player_id, now(), p_expires_at, null
  )
  on conflict (destination_planet_id, guest_player_id)
  do update set owner_player_id = excluded.owner_player_id,
                authorized_at = excluded.authorized_at,
                expires_at = excluded.expires_at,
                revoked_at = null
  returning planet_support_authorizations.id into v_id;

  return query
  select a.id, a.destination_planet_id, a.owner_player_id, a.guest_player_id, a.authorized_at, a.expires_at
  from public.planet_support_authorizations a
  where a.id = v_id;
end;
$function$;

-- Revoke: the destination owner withdraws the authorization.
CREATE OR REPLACE FUNCTION public.revoke_planet_support_authorization(
  p_player_id uuid,
  p_planet_id uuid,
  p_guest_player_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_auth_user uuid := auth.uid();
  v_updated int;
begin
  if v_auth_user is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1 from public.players pl
    where pl.id = p_player_id and pl.user_id = v_auth_user
  ) then
    raise exception 'Player does not belong to authenticated user';
  end if;

  update public.planet_support_authorizations a
  set revoked_at = now()
  where a.destination_planet_id = p_planet_id
    and a.owner_player_id = p_player_id
    and a.guest_player_id = p_guest_player_id
    and a.revoked_at is null;

  get diagnostics v_updated = row_count;
  return v_updated > 0;
end;
$function$;



-- ---------------------------------------------------------------------------
-- 5. Single support dispatcher.
--    Player-facing missions: ACS_HOLD only.
--      DEFEND  -> COMBAT_SUPPORT_NOT_READY (closed until the combat engine)
--      HOLDING -> rejected: it is an internal lifecycle state, not a mission
--    Acceptance is atomic: validate -> calculate -> check/deduct fuel and ships
--    -> create movement + composition, all inside this single transaction.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.start_support_fleet(
  p_player_id uuid,
  p_origin_planet_id uuid,
  p_destination_planet_id uuid,
  p_ships jsonb,
  p_support_mission text,
  p_holding_until timestamptz,
  p_idempotency_key uuid
)
RETURNS TABLE(
  fleet_id uuid,
  ship_id text,
  quantity bigint,
  origin_planet_id uuid,
  destination_planet_id uuid,
  mission_type text,
  status text,
  started_at timestamptz,
  arrives_at timestamptz,
  holding_until timestamptz,
  fuel_consumed numeric,
  idempotent_replay boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_auth_user uuid := auth.uid();
  v_mission text := upper(coalesce(p_support_mission, ''));
  v_fleet_id uuid;
  v_existing_id uuid;
  v_origin_owner uuid;
  v_universe_id uuid;
  v_dest_owner uuid;
  v_dest_universe uuid;
  v_dest_destroyed boolean;
  v_distance numeric;
  v_min_speed numeric := null;
  v_ship_id text;
  v_quantity bigint;
  v_available bigint;
  v_count int := 0;
  v_ship_speed numeric;
  v_fleet_class numeric;
  v_evolution numeric;
  v_bonus numeric := 1;
  v_fleet_rate numeric;
  v_travel_time numeric;
  v_started_at timestamptz;
  v_arrives_at timestamptz;
  v_fuel numeric := 0;
  v_resources record;
begin
  -- 1. Identity. The client-supplied p_player_id is never trusted alone.
  if v_auth_user is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1 from public.players pl
    where pl.id = p_player_id and pl.user_id = v_auth_user
  ) then
    raise exception 'Player does not belong to authenticated user';
  end if;

  -- 2. Mission gate.
  if v_mission = 'DEFEND' then
    raise exception 'COMBAT_SUPPORT_NOT_READY: DEFEND requires the ACS combat engine';
  end if;

  if v_mission = 'HOLDING' then
    raise exception 'HOLDING_IS_INTERNAL_STATE: HOLDING is a movement lifecycle state, not a dispatchable mission';
  end if;

  if v_mission <> 'ACS_HOLD' then
    raise exception 'Invalid support mission type: %', v_mission;
  end if;

  -- 3. Idempotency: same request -> same movement, never a second deduction.
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED';
  end if;

  select fm.id into v_existing_id
  from public.fleet_movements fm
  where fm.player_id = p_player_id
    and fm.idempotency_key = p_idempotency_key;

  if v_existing_id is not null then
    return query
    select fm.id, fms.ship_id, fms.quantity, fm.origin_planet_id, fm.destination_planet_id,
           fm.mission_type, fm.status, fm.started_at, fm.arrives_at, fm.holding_until,
           fm.fuel_consumed, true
    from public.fleet_movements fm
    join public.fleet_movement_ships fms on fms.fleet_id = fm.id
    where fm.id = v_existing_id
    order by fms.ship_id;
    return;
  end if;

  -- 4. Composition shape.
  if p_ships is null or jsonb_typeof(p_ships) <> 'object' or p_ships = '{}'::jsonb then
    raise exception 'Fleet composition must be a non-empty JSON object';
  end if;

  -- 5. Origin ownership.
  select p.player_id, p.universe_id into v_origin_owner, v_universe_id
  from public.planets p
  where p.id = p_origin_planet_id
    and not p.is_destroyed
  for update;

  if not found or v_origin_owner <> p_player_id then
    raise exception 'Origin planet does not belong to player';
  end if;

  -- 6. Destination: foreign, same universe, not destroyed, and explicitly
  --    authorised by its owner. Existence alone is not authorization.
  if p_destination_planet_id is null then
    raise exception 'Destination planet is required for ACS_HOLD';
  end if;

  if p_destination_planet_id = p_origin_planet_id then
    raise exception 'ACS_HOLD_DESTINATION_OWN_PLANET: support target must be a foreign planet';
  end if;

  select p.player_id, p.universe_id, p.is_destroyed
    into v_dest_owner, v_dest_universe, v_dest_destroyed
  from public.planets p
  where p.id = p_destination_planet_id;

  if not found then
    raise exception 'Destination planet not found';
  end if;

  if v_dest_destroyed then
    raise exception 'Destination planet is destroyed';
  end if;

  if v_dest_universe <> v_universe_id then
    raise exception 'Destination planet belongs to another universe';
  end if;

  if v_dest_owner is null or v_dest_owner = p_player_id then
    raise exception 'ACS_HOLD destination must be a foreign planet';
  end if;

  if not exists (
    select 1 from public.planet_support_authorizations a
    where a.destination_planet_id = p_destination_planet_id
      and a.owner_player_id = v_dest_owner
      and a.guest_player_id = p_player_id
      and a.revoked_at is null
      and (a.expires_at is null or a.expires_at > now())
  ) then
    raise exception 'SUPPORT_AUTHORIZATION_REQUIRED: the destination owner has not authorised player % on planet %',
      p_player_id, p_destination_planet_id;
  end if;

  -- 7. Composition validation + slowest effective ship (canonical helper).
  for v_ship_id, v_quantity in
    select key, value::bigint from jsonb_each_text(p_ships) order by key
  loop
    v_count := v_count + 1;

    if v_quantity is null or v_quantity <= 0 then
      raise exception 'Invalid quantity for %', v_ship_id;
    end if;

    if not exists (select 1 from public.ship_definitions sd where sd.id = v_ship_id) then
      raise exception 'Unknown ship: %', v_ship_id;
    end if;

    select ps.quantity into v_available
    from public.planet_ships ps
    where ps.planet_id = p_origin_planet_id and ps.ship_id = v_ship_id
    for update;

    if coalesce(v_available, 0) < v_quantity then
      raise exception 'Not enough %: available %, requested %', v_ship_id, coalesce(v_available, 0), v_quantity;
    end if;

    v_ship_speed := public.calculate_player_ship_speed(p_player_id, v_ship_id);

    if v_ship_speed is null or v_ship_speed <= 0 then
      raise exception 'Ship % cannot participate because its effective speed is %', v_ship_id, v_ship_speed;
    end if;

    v_min_speed := case when v_min_speed is null then v_ship_speed else least(v_min_speed, v_ship_speed) end;
  end loop;

  if v_count = 0 then
    raise exception 'Fleet composition contains no usable ships';
  end if;

  -- 8. Canonical speed/travel pipeline (ACS_HOLD -> holding_fleet_speed).
  v_distance := public.calculate_fleet_distance(p_origin_planet_id, p_destination_planet_id);
  v_fleet_class := public.calculate_mission_fleet_speed_multiplier(v_universe_id, 'ACS_HOLD');
  v_evolution := public.calculate_universe_evolution_rate(v_universe_id);
  v_bonus := 1 + (
    coalesce(public.get_active_expedition_item_effect(p_player_id, p_origin_planet_id, 'fleet_speed_percent'), 0)
    + coalesce(public.get_active_lifeform_research_effect(p_player_id, 'fleet_speed_percent'), 0)
  ) / 100;
  v_fleet_rate := v_fleet_class * power(v_evolution, 1.0 / 3.0) * v_bonus;
  v_travel_time := greatest(public.calculate_fleet_travel_time(v_distance, v_min_speed, v_fleet_rate, 100), 1);
  v_started_at := now();
  v_arrives_at := v_started_at + (v_travel_time * interval '1 second');

  -- 9. Holding window: absolute UTC timestamp, in the future and after arrival.
  --    No maximum duration is enforced: that remains a product decision.
  if p_holding_until is null then
    raise exception 'HOLDING_UNTIL_REQUIRED';
  end if;

  if p_holding_until <= now() then
    raise exception 'HOLDING_UNTIL_NOT_IN_FUTURE: %', p_holding_until;
  end if;

  if p_holding_until <= v_arrives_at then
    raise exception 'HOLDING_UNTIL_BEFORE_ARRIVAL: holding_until %, arrives_at %', p_holding_until, v_arrives_at;
  end if;

  -- 10. Fuel: canonical player-aware helper, computed once with the outbound
  --     flight time. Holding fuel is NOT implemented (no invented deuterium tick).
  for v_ship_id, v_quantity in
    select key, value::bigint from jsonb_each_text(p_ships) order by key
  loop
    v_fuel := v_fuel + public.calculate_player_fleet_fuel_for_distance(
      v_distance, v_travel_time, p_player_id, v_ship_id, v_quantity, 100
    );
  end loop;

  perform public.update_planet_resources_until(p_origin_planet_id, v_started_at);

  select * into v_resources
  from public.planet_resources pr
  where pr.planet_id = p_origin_planet_id
  for update;

  if not found then
    raise exception 'Planet resources not found';
  end if;

  if v_resources.deuterium < v_fuel then
    raise exception 'Insufficient deuterium for fleet fuel: required %, available %', v_fuel, v_resources.deuterium;
  end if;


  -- 11. Atomic acceptance: fuel, ships and movement commit together or not at all.
  begin
    update public.planet_resources
    set deuterium = deuterium - v_fuel,
        updated_at = clock_timestamp()
    where planet_id = p_origin_planet_id;

    for v_ship_id, v_quantity in
      select key, value::bigint from jsonb_each_text(p_ships) order by key
    loop
      update public.planet_ships ps
      set quantity = ps.quantity - v_quantity
      where ps.planet_id = p_origin_planet_id and ps.ship_id = v_ship_id;

      if not found then
        raise exception 'Not enough %: concurrent modification', v_ship_id;
      end if;
    end loop;

    insert into public.fleet_movements(
      player_id, origin_planet_id, destination_planet_id, mission_type,
      started_at, arrives_at, status, destination_galaxy, destination_system,
      destination_position, expedition_hold_seconds, fuel_consumed,
      holding_until, idempotency_key
    )
    select p_player_id, p_origin_planet_id, p_destination_planet_id, 'ACS_HOLD',
           v_started_at, v_arrives_at, 'OUTBOUND', d.galaxy, d.system, d.position,
           0, v_fuel, p_holding_until, p_idempotency_key
    from public.planets d
    where d.id = p_destination_planet_id
    returning id into v_fleet_id;

    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity)
    select v_fleet_id, key, value::bigint
    from jsonb_each_text(p_ships) order by key;
  exception when unique_violation then
    -- Lost the race against an identical concurrent request: the partial work of
    -- this call is rolled back by this subtransaction and the durable movement of
    -- the winner is returned instead.
    select fm.id into v_fleet_id
    from public.fleet_movements fm
    where fm.player_id = p_player_id and fm.idempotency_key = p_idempotency_key;

    if v_fleet_id is null then
      raise;
    end if;
  end;

  return query
  select fm.id, fms.ship_id, fms.quantity, fm.origin_planet_id, fm.destination_planet_id,
         fm.mission_type, fm.status, fm.started_at, fm.arrives_at, fm.holding_until,
         fm.fuel_consumed, false
  from public.fleet_movements fm
  join public.fleet_movement_ships fms on fms.fleet_id = fm.id
  where fm.id = v_fleet_id
  order by fms.ship_id;
end;
$function$;


-- ---------------------------------------------------------------------------
-- 6. ACLs: player-facing contracts only, no anonymous execution, no direct
--    table access to the authorization policy.
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.start_support_fleet(uuid, uuid, uuid, jsonb, text, timestamptz, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.start_support_fleet(uuid, uuid, uuid, jsonb, text, timestamptz, uuid)
  TO authenticated;

REVOKE EXECUTE ON FUNCTION public.grant_planet_support_authorization(uuid, uuid, uuid, timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.grant_planet_support_authorization(uuid, uuid, uuid, timestamptz)
  TO authenticated;

REVOKE EXECUTE ON FUNCTION public.revoke_planet_support_authorization(uuid, uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revoke_planet_support_authorization(uuid, uuid, uuid)
  TO authenticated;

COMMIT;

