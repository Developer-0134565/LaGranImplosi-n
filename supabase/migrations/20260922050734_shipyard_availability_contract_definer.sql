-- ============================================================================
-- SHIPYARD — CLIENT AVAILABILITY CONTRACT (Phase A closeout)
-- ----------------------------------------------------------------------------
-- Problem, measured LIVE 2026-09-22 (NOT inferred from a README):
--
--   can_build_ship() was the only production availability contract still declared
--   SECURITY INVOKER while depending on helpers that are intentionally NOT
--   client-executable:
--     · check_ship_requirements(uuid,text)   -> ACL postgres/service_role only
--     · calculate_ship_build_time(uuid,text) -> SECURITY INVOKER, reads
--                                               public.universes, which has no
--                                               SELECT grant for client roles
--   Through the Data API the call therefore aborted with
--     ERROR 42501 permission denied for function check_ship_requirements
--   for an authenticated owner and for anon alike, and the frontend threw while
--   loading the Shipyard view.
--
--   can_build_ship() also had NO identity gate at all, unlike the two contracts
--   already closed by the project:
--     · can_build_defense(...)   SECURITY DEFINER + auth.uid() + PLAYER_NOT_OWNED
--     · can_start_research(...)  SECURITY DEFINER + auth.uid() + PLAYER_NOT_OWNED
--   Making it SECURITY DEFINER without adding those gates would have turned it
--   into a foreign-player oracle: its `reason` reflects another player's
--   building/research levels. Both defects are closed here, together, because
--   the fix for the first one is what would have created the second.
--
-- Design — the project's own pattern, no new infrastructure:
--
--   client -> carefully bounded SECURITY DEFINER contract -> internal helpers
--          -> authoritative result
--
-- Explicitly NOT done in this migration:
--   · no GRANT SELECT ON public.universes to anon/authenticated;
--   · no EXECUTE ON public.check_ship_requirements to anon/authenticated;
--   · no is_guest branch, no username trust, no client-supplied ownership;
--   · no change to costs, build times, prerequisites, queue shape or lifecycle;
--   · calculate_ship_build_time keeps its current PUBLIC EXECUTE (parity with
--     calculate_defense_build_time; deferred P3 hygiene, not this mission).
-- ============================================================================

create or replace function public.can_build_ship(p_player_id uuid, p_planet_id uuid, p_ship_id text, p_quantity bigint default 1)
returns table(allowed boolean, reason text, ship_id text, quantity bigint, metal_cost numeric, crystal_cost numeric, deuterium_cost numeric, build_time_seconds numeric)
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $can_build_ship$
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
        RETURN QUERY
        SELECT
            false,
            'AUTHENTICATION_REQUIRED',
            p_ship_id,
            p_quantity,
            0::numeric,
            0::numeric,
            0::numeric,
            0::numeric;
        RETURN;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.players pl
        WHERE pl.id = p_player_id
          AND pl.user_id = auth.uid()
    ) THEN
        RETURN QUERY
        SELECT
            false,
            'PLAYER_NOT_OWNED',
            p_ship_id,
            p_quantity,
            0::numeric,
            0::numeric,
            0::numeric,
            0::numeric;
        RETURN;
    END IF;

    IF p_quantity <= 0 THEN
        RETURN QUERY
        SELECT
            false,
            'Quantity must be greater than 0',
            p_ship_id,
            p_quantity,
            0::numeric,
            0::numeric,
            0::numeric,
            0::numeric;
        RETURN;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.planets p
        WHERE p.id = p_planet_id
          AND p.player_id = p_player_id
          AND NOT p.is_destroyed
    ) THEN
        RETURN QUERY
        SELECT
            false,
            'Planet does not belong to player',
            p_ship_id,
            p_quantity,
            0::numeric,
            0::numeric,
            0::numeric,
            0::numeric;
        RETURN;
    END IF;

    SELECT r.reason
    INTO v_reason
    FROM public.check_ship_requirements(
        p_planet_id,
        p_ship_id
    ) AS r
    WHERE NOT r.allowed
    LIMIT 1;

    SELECT
        c.metal,
        c.crystal,
        c.deuterium
    INTO
        v_metal,
        v_crystal,
        v_deuterium
    FROM public.calculate_ship_cost(
        p_ship_id,
        p_quantity
    ) AS c;

    IF v_reason IS NOT NULL THEN
        RETURN QUERY
        SELECT
            false,
            v_reason,
            p_ship_id,
            p_quantity,
            v_metal,
            v_crystal,
            v_deuterium,
            0::numeric;
        RETURN;
    END IF;

    SELECT
        pr.metal,
        pr.crystal,
        pr.deuterium
    INTO
        v_metal_available,
        v_crystal_available,
        v_deuterium_available
    FROM public.get_current_planet_resources(p_planet_id) AS pr;

    IF v_metal_available < v_metal THEN
        RETURN QUERY
        SELECT
            false,
            'Not enough metal',
            p_ship_id,
            p_quantity,
            v_metal,
            v_crystal,
            v_deuterium,
            0::numeric;
        RETURN;
    END IF;

    IF v_crystal_available < v_crystal THEN
        RETURN QUERY
        SELECT
            false,
            'Not enough crystal',
            p_ship_id,
            p_quantity,
            v_metal,
            v_crystal,
            v_deuterium,
            0::numeric;
        RETURN;
    END IF;

    IF v_deuterium_available < v_deuterium THEN
        RETURN QUERY
        SELECT
            false,
            'Not enough deuterium',
            p_ship_id,
            p_quantity,
            v_metal,
            v_crystal,
            v_deuterium,
            0::numeric;
        RETURN;
    END IF;

    v_time := public.calculate_ship_build_time(
        p_planet_id,
        p_ship_id
    );

    RETURN QUERY
    SELECT
        true,
        'OK',
        p_ship_id,
        p_quantity,
        v_metal,
        v_crystal,
        v_deuterium,
        v_time;
END;
$can_build_ship$;

-- ACL: the contract stays the only client-facing point and the internal helpers
-- stay closed. Mirrors can_build_defense exactly.
revoke all on function public.can_build_ship(uuid, uuid, text, bigint) from public, anon, authenticated;
grant execute on function public.can_build_ship(uuid, uuid, text, bigint) to authenticated;

-- ---------------------------------------------------------------------------
-- Post-conditions: proves the fix landed AND that nothing was widened.
-- ---------------------------------------------------------------------------
do $shipyard_a$
begin
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace='public'::regnamespace and p.proname='can_build_ship'
      and p.prosecdef
      and pg_get_userbyid(p.proowner)='postgres'
      and coalesce(array_to_string(p.proconfig,','),'') like '%search_path=public, pg_temp%'
  ) then
    raise exception 'SHIPYARD-A: can_build_ship is not a bounded definer with a fixed search_path';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace='public'::regnamespace and p.proname='can_build_ship'
      and p.prosrc like '%AUTHENTICATION_REQUIRED%'
      and p.prosrc like '%PLAYER_NOT_OWNED%'
  ) then
    raise exception 'SHIPYARD-A: can_build_ship has no identity gate';
  end if;

  if has_function_privilege('anon','public.can_build_ship(uuid,uuid,text,bigint)','EXECUTE') then
    raise exception 'SHIPYARD-A: anon must not execute can_build_ship';
  end if;

  if not has_function_privilege('authenticated','public.can_build_ship(uuid,uuid,text,bigint)','EXECUTE') then
    raise exception 'SHIPYARD-A: authenticated lost EXECUTE on can_build_ship';
  end if;

  if not has_function_privilege('service_role','public.can_build_ship(uuid,uuid,text,bigint)','EXECUTE') then
    raise exception 'SHIPYARD-A: service_role lost EXECUTE on can_build_ship';
  end if;

  if has_table_privilege('anon','public.universes','SELECT')
     or has_table_privilege('authenticated','public.universes','SELECT') then
    raise exception 'SHIPYARD-A: universes must not be granted to client roles';
  end if;

  if has_function_privilege('anon','public.check_ship_requirements(uuid,text)','EXECUTE')
     or has_function_privilege('authenticated','public.check_ship_requirements(uuid,text)','EXECUTE') then
    raise exception 'SHIPYARD-A: check_ship_requirements must stay internal';
  end if;

  if has_function_privilege('anon','public.calculate_ship_build_time(uuid,text)','EXECUTE')
     and has_table_privilege('anon','public.universes','SELECT') then
    raise exception 'SHIPYARD-A: unexpected client access to the build-time helper';
  end if;
end
$shipyard_a$;
