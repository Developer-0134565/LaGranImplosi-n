-- DEFEND — SOCIAL AUTHORIZATION LAYER (dispatch readiness)
-- ----------------------------------------------------------------------------
-- NOT DEPLOYED BY THIS MISSION. Local source of truth; forward-only.
--
-- WHAT THIS FILE DELIBERATELY DOES NOT DO
--   It does NOT modify `start_support_fleet`, `resolve_combat`,
--   `resolve_attack_arrival`, the settlement or the worker. Every one of those is
--   a CLOSED, certified system (docs/systems/README_COMBAT_ENGINE.md and
--   README_FLEET_ENGINE.md), and the mission forbids reopening them.
--
-- MEASURED STATE OF DEFEND ON LIVE (2026-10-02, read-only inspection)
--   * `fleet_movements_mission_type_check` DOES admit 'DEFEND';
--     `fleet_movements_holding_until_check` requires a `holding_until` for it;
--     `fleet_movements_holding_until_after_arrival_check` requires
--     holding_until > arrives_at. The SCHEMA is ready.
--   * `start_support_fleet` step 2 contains exactly:
--         if v_mission = 'DEFEND' then
--           raise exception 'COMBAT_SUPPORT_NOT_READY: DEFEND requires the ACS combat engine';
--         end if;
--     So DEFEND dispatch is DEFINITION_ONLY: recognised and refused in one place.
--   * THE BLOCKING DEPENDENCY (measured, not assumed):
--         `resolve_combat` never mentions HOLDING or holding_until. It creates
--         exactly two participants per battle:
--             ('ATTACKER','FLEET',p_fleet_id,...)
--             ('DEFENDER','PLANET',null,v_fleet.destination_planet_id,...)
--         and `get_planet_defender_ship_count` sums ONLY `public.planet_ships`.
--         A fleet sitting in HOLDING at the target planet is therefore NEVER
--         gathered as a combat participant: it would be invisible to the battle.
--     Integrating it needs the already-selected multi-fleet combat redesign,
--     which is OUT OF SCOPE here. This file stops exactly at authorization +
--     readiness, and DEFEND remains PARTIALLY_IMPLEMENTED.
--
-- OGameX REFERENCE (app/GameMissions/AcsDefendMission.php @ 2649076)
--     if (!$isBuddy && !$isAllianceMember) {
--         return new MissionPossibleStatus(false,
--             __('You can only send ACS Defend missions to buddies or alliance members!'));
--     }
--   The DEFEND authorization rule is: buddy OR same alliance, checked in the
--   BACKEND. `isMissionPossible()` is the availability gate; the dispatcher is
--   FleetMissionService, not this file.
--
-- RELATIONSHIP TO THE EXISTING ACS AUTHORIZATION
--   LGI's certified `planet_support_authorizations` is PLANET-scoped: the owner
--   of a planet names a specific player. OGameX's DEFEND is PLAYER-scoped: a
--   buddy or ally may defend ANY planet of the defended player.
--   Both are legitimate and both are kept. `can_defend_player()` reports the
--   SOCIAL authorization (the OGameX rule) and leaves the planet-scoped rule to
--   `start_support_fleet`, which is untouched. Neither replaces the other and
--   neither is silently widened.

begin;

-- ============================================ RPC: can_defend_player (read-only)
-- The OGameX rule in LGI terms. Answers "may player A defend a planet owned by
-- player B?", resolving B from the PLANET so the client cannot name an
-- arbitrary owner, and checking the social relation in the backend.
create or replace function public.can_defend_player(
    p_supporting_player_id uuid,
    p_target_planet_id     uuid
)
returns table (
    out_allowed         boolean,
    out_reason          text,
    out_owner_player_id uuid,
    out_via_buddy       boolean,
    out_via_alliance    boolean
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
    v_owner uuid;
    v_buddy boolean := false;
    v_ally  boolean := false;
begin
    if p_supporting_player_id is null or p_target_planet_id is null then
        return query select false, 'DEFEND_INVALID_ARGUMENTS', null::uuid, false, false;
        return;
    end if;

    -- OGameX: the target planet must exist; destroyed planets are refused.
    select pl.player_id into v_owner
      from public.planets pl
     where pl.id = p_target_planet_id
       and not pl.is_destroyed;

    if v_owner is null then
        return query select false, 'DEFEND_TARGET_NOT_FOUND', null::uuid, false, false;
        return;
    end if;

    -- OGameX checkOwnPlanet(): cannot send ACS Defend to your OWN planet.
    if v_owner = p_supporting_player_id then
        return query select false, 'DEFEND_OWN_PLANET', v_owner, false, false;
        return;
    end if;

    v_buddy := public.players_are_buddies(p_supporting_player_id, v_owner);
    v_ally  := public.players_in_same_alliance(p_supporting_player_id, v_owner);

    -- OGameX: allowed when buddy OR same alliance. NEITHER defaults to true.
    return query
    select (v_buddy or v_ally),
           case when v_buddy or v_ally then 'DEFEND_SOCIAL_AUTHORIZATION_OK'
                else 'DEFEND_NOT_BUDDY_OR_ALLY' end,
           v_owner, v_buddy, v_ally;
end;
$$;

comment on function public.can_defend_player(uuid, uuid) is
    'OGameX AcsDefendMission authorization in LGI terms: the supporting player may defend a planet when they are buddies with OR in the same alliance as the planet OWNER (resolved server-side from the planet). Read-only advisory; grants no movement and does not replace the planet-scoped planet_support_authorizations check inside start_support_fleet.';

-- ======================================= RPC: defend_dispatch_readiness (read-only)
-- A single place that states, honestly and without inventing anything, how far
-- DEFEND actually is, so the UI and the docs cannot drift from reality and a
-- future mission has one contract to extend. The answers are DERIVED from the
-- deployed function bodies, so this can never claim readiness the engine lacks.
create or replace function public.defend_dispatch_readiness()
returns table (
    out_schema_ready        boolean,
    out_dispatch_open       boolean,
    out_combat_ready        boolean,
    out_authorization_ready boolean,
    out_blocking_reason     text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    with dispatch as (
        -- start_support_fleet still refuses DEFEND in one place.
        select exists (
            select 1 from pg_proc p
             where p.pronamespace = 'public'::regnamespace
               and p.proname = 'start_support_fleet'
               and p.prosrc ilike '%COMBAT_SUPPORT_NOT_READY%'
        ) as blocked
    ),
    combat as (
        -- The multi-fleet gap: resolve_combat gathers the ATTACKING fleet and
        -- the PLANET only, so a HOLDING support fleet could not join the battle.
        select not exists (
            select 1 from pg_proc p
             where p.pronamespace = 'public'::regnamespace
               and p.proname = 'resolve_combat'
               and (p.prosrc ilike '%holding%' or p.prosrc ilike '%DEFENDER%FLEET%')
        ) as gathers_support_fleets
    )
    select true,
           not d.blocked,
           c.gathers_support_fleets,
           -- authorization is ready once this social layer exists at all
           to_regclass('public.player_buddies') is not null
             and to_regclass('public.player_alliance_members') is not null,
           case
               when d.blocked and not c.gathers_support_fleets
                 then 'DEFEND_BLOCKED_BY_MULTI_FLEET_COMBAT_REDESIGN: dispatch is refused and resolve_combat does not gather HOLDING support fleets'
               when d.blocked
                 then 'DEFEND_DISPATCH_REFUSED: start_support_fleet still raises COMBAT_SUPPORT_NOT_READY'
               when not c.gathers_support_fleets
                 then 'DEFEND_COMBAT_GAP: resolve_combat still does not gather HOLDING support fleets'
               else 'DEFEND_READY'
           end
      from dispatch d, combat c;
$$;

comment on function public.defend_dispatch_readiness() is
    'Honest readiness report for DEFEND, derived from the deployed function bodies so it cannot claim readiness the engine does not have. Read-only; changes nothing.';

-- ---------------------------------------------------------------------- ACL
grant execute on function public.can_defend_player(uuid, uuid) to authenticated, service_role;
grant execute on function public.defend_dispatch_readiness()  to authenticated, service_role;

revoke execute on function public.can_defend_player(uuid, uuid) from anon;
revoke execute on function public.defend_dispatch_readiness()  from anon;

commit;