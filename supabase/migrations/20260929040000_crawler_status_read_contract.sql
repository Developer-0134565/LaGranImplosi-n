-- CRAWLER — read contract for the hangar / economy surface (2026-09-29)
-- ============================================================================================
-- GAP (backend -> UI). The crawler was IMPLEMENTED and CERTIFIED on 2026-09-26
-- (`20260926140000` definitions, `20260926140200` economy integration, fixture
-- `supabase/tests/fusion_and_crawler.sql`). The economy already applies, server-side:
--
--   * effective units  = least(crawler_count, (metal_mine + crystal_mine + deuterium_synthesizer) * 8)
--   * production bonus = floor(mine_base * 0.0002 * effective)      (i.e. +0.02 % per unit)
--   * energy draw      = effective * 50
--
-- but NO client contract exposed any of it and no UI showed it. The hangar renders the raw
-- `planet_ships` count only, so a player with 1 000 crawlers on a planet capped at 240 had no
-- way to learn that 760 units were doing nothing. That is a "result exists but is not reflected
-- to the player" gap, not a missing mechanic.
--
-- WHAT THIS IS NOT. No new rule, no new number, no new source of truth: every expression below is
-- copied verbatim from the certified `calculate_planet_production`. The economy function is
-- deliberately NOT modified (it is the certified core), so the duplication is bounded by
-- `supabase/tests/crawler_status_contract.sql`, which asserts this contract agrees with
-- `calculate_planet_production` on the effective count AND on the production delta it produces.
-- Any future drift between the two fails the fixture loudly.
--
-- OWNERSHIP. Same fail-closed shape as `get_planet_economy_overview`: the player is derived from
-- `auth.uid()` only, the planet must belong to that player, and a foreign/other-player planet
-- returns ZERO ROWS rather than an error or a value. The client cannot pass a player id, cannot
-- pass a cap, and cannot pass a bonus; it only receives computed facts.
--
-- The crawler is planet-only (`ship_definitions.valid_kinds = '{PLANET}'`), so the cap term is the
-- three mine levels exactly as the economy does it; moons have no mines and no crawlers.
-- ============================================================================================

begin;

create or replace function public.get_planet_crawler_status(p_planet_id uuid)
returns table (
    crawler_count             bigint,
    crawler_cap               bigint,
    crawler_effective         bigint,
    crawler_bonus_percent     numeric,
    crawler_energy_per_hour   numeric
)
language plpgsql
security definer
set search_path = 'public', 'pg_temp'
as $function$
declare
    v_player_id  uuid;
    v_planet     uuid;
    v_metal      integer;
    v_crystal    integer;
    v_deuterium  integer;
    v_count      bigint;
    v_cap        bigint;
    v_effective  bigint;
begin
    -- authority chain: auth.uid() -> players.user_id -> owned planet. No client-supplied identity.
    select pl.id into v_player_id
      from public.players pl
     where pl.user_id = auth.uid();

    select p.id into v_planet
      from public.planets p
     where p.id = p_planet_id
       and p.player_id = v_player_id
       and p.is_destroyed = false;

    if v_planet is null then
        return;                      -- fail closed: foreign / unknown / destroyed planet
    end if;

    select coalesce(max(level) filter (where building_id = 'metal_mine'), 0),
           coalesce(max(level) filter (where building_id = 'crystal_mine'), 0),
           coalesce(max(level) filter (where building_id = 'deuterium_synthesizer'), 0)
      into v_metal, v_crystal, v_deuterium
      from public.planet_buildings
     where planet_id = v_planet;

    select coalesce(sum(ps.quantity), 0)
      into v_count
      from public.planet_ships ps
     where ps.planet_id = v_planet
       and ps.ship_id = 'crawler';

    -- verbatim from calculate_planet_production
    v_cap       := (v_metal + v_crystal + v_deuterium)::bigint * 8;
    v_effective := least(v_count, v_cap);

    return query
    select v_count,
           v_cap,
           v_effective,
           (0.0002 * v_effective * 100)::numeric,   -- +0.02 % per effective unit
           (v_effective * 50)::numeric;              -- 50 energy per effective unit
end;
$function$;

-- client surface: authenticated only, never anon, never PUBLIC.
revoke all on function public.get_planet_crawler_status(uuid) from public, anon;
grant execute on function public.get_planet_crawler_status(uuid) to authenticated;

do $guard$
declare
    v_client boolean;
    v_service boolean;
begin
    -- 1. ACL: EXECUTE for authenticated, and NOT for anon / PUBLIC.
    select has_function_privilege('authenticated', 'public.get_planet_crawler_status(uuid)', 'EXECUTE')
      into v_client;
    if not v_client then
        raise exception 'CRAWLER_STATUS: authenticated must be able to execute the contract';
    end if;
    if has_function_privilege('anon', 'public.get_planet_crawler_status(uuid)', 'EXECUTE')
       or has_function_privilege('public', 'public.get_planet_crawler_status(uuid)', 'EXECUTE') then
        raise exception 'CRAWLER_STATUS: the anonymous surface must stay closed';
    end if;

    -- 2. the engine must keep its grant (read-only, but the service role is the server path).
    select has_function_privilege('service_role', 'public.get_planet_crawler_status(uuid)', 'EXECUTE')
      into v_service;
    if not v_service then
        raise exception 'CRAWLER_STATUS: service_role lost EXECUTE';
    end if;

    -- 3. SECURITY DEFINER with a pinned search_path (no injection surface).
    if not exists (
        select 1 from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname = 'get_planet_crawler_status'
           and p.prosecdef
           and p.proconfig @> array['search_path=public, pg_temp']
    ) then
        raise exception 'CRAWLER_STATUS: SECURITY DEFINER with a pinned search_path is required';
    end if;
end;
$guard$;

commit;
