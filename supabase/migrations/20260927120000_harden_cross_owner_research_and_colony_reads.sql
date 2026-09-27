-- ============================================================================
-- HARDENING — cross-owner read oracles around BUILDINGS and RESEARCH (2026-09-27)
-- ----------------------------------------------------------------------------
-- FINDING (measured LIVE 2026-09-27, reproduced as `authenticated`):
--   Five client-callable SECURITY DEFINER contracts take the target of the read from a CLIENT PARAMETER and had no
--   ownership gate at all, so any signed-in player could read another empire's buildings/research without ever
--   dispatching an espionage mission:
--
--     get_research_network_lab_level(p_player_id, p_planet_id, p_research_id)
--         -> research_lab level of ANY planet plus the intergalactic_research_network level of ANY player
--            (and the sum of the best N lab levels of that empire).
--     calculate_research_time(p_player_id, p_planet_id, p_research_id, p_target_level)
--         -> the same leak observed through the returned duration.
--     calculate_max_colony_slots(p_player_id) / check_colony_cap(p_player_id)
--         -> astrophysics level, colony cap and planet count of ANY player.
--     calculate_player_category_scores(p_player_id)
--         -> recomputes a whole foreign empire's economy/research/military buckets (expensive: generate_series over
--            every building level x calculate_building_cost), i.e. also a compute amplifier.
--
-- WHY THIS IS A DEFECT AND NOT A DESIGN CHOICE
--   * The certified espionage system deliberately does NOT report buildings or research: the report contract
--     (`espionage_reports.fleet` / `defenses`) carries ships and defence only, and OGameX gates those sections
--     behind `canRevealData(...)`. Nothing in LGI makes a foreign planet's building/research level public, and the
--     only public score surface is `get_universe_ranking_by_category`, never an arbitrary `p_player_id`.
--   * The repository already certifies this exact gate for sibling contracts: `inspect_demolition` /
--     `start_demolition` (identity -> ownership), `calculate_planet_storage` (owner or nothing) and
--     `can_start_building` (`20260926240000_harden_can_start_building_ownership`). This migration applies the
--     same, already-certified idiom — no new pattern, no new rule, no product decision.
--
-- SHAPE OF THE GATE (identical identity check to the certified `inspect_demolition`)
--   auth.uid() IS NOT NULL AND the player is not the caller   -> refused
--   auth.uid() IS NULL                                        -> unchanged (the engine workers and the AI service
--                                                                actor always run without a JWT: verified LIVE that
--                                                                process_fleet_movements / resolve_colonize_arrival /
--                                                                recalculate_player_points / run_ranking_worker are
--                                                                all `authenticated = false`)
--   The planet-scoped helpers additionally require the planet to belong to that player: otherwise a caller could
--   pass its OWN player id together with a FOREIGN planet id and the leak would survive the identity gate.
--
-- REASONS: 'PLAYER_NOT_OWNED_BY_AUTH_USER' / 'PLANET_NOT_OWNED_BY_AUTH_USER' (the `inspect_demolition` vocabulary).
-- `check_colony_cap` keeps its TABLE shape and reports the refusal as a blocked row (`allowed = false`), exactly
-- like `can_start_building` / `inspect_demolition`; its numeric fields stay NULL because a refused caller gets
-- nothing ("datos mínimos necesarios").
--
-- Verified by `supabase/tests/cross_owner_research_and_colony_reads.sql`.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- 1. get_research_network_lab_level — player + planet ownership
-- ---------------------------------------------------------------------------
create or replace function public.get_research_network_lab_level(
    p_player_id uuid,
    p_planet_id uuid,
    p_research_id text
)
returns integer
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_auth_user uuid := auth.uid();
    v_own integer := 0;
    v_irn integer := 0;
    v_required integer := 0;
    v_network integer := 0;
begin
    /* Identity: the caller may only read its own empire. No JWT -> engine/AI caller, unchanged. */
    if v_auth_user is not null and not exists (
        select 1 from public.players pl where pl.id = p_player_id and pl.user_id = v_auth_user
    ) then
        raise exception 'PLAYER_NOT_OWNED_BY_AUTH_USER';
    end if;

    /* Ownership: the queried planet must be one of that player's own bodies. */
    if v_auth_user is not null and not exists (
        select 1
        from public.planets p
        join public.players pl on pl.id = p.player_id
        where p.id = p_planet_id
          and pl.user_id = v_auth_user
          and not p.is_destroyed
    ) then
        raise exception 'PLANET_NOT_OWNED_BY_AUTH_USER';
    end if;

    select coalesce(pb.level, 0) into v_own
    from public.planet_buildings pb
    where pb.planet_id = p_planet_id and pb.building_id = 'research_lab';

    v_own := coalesce(v_own, 0);

    /* OGameX: the network only exists while the player owns the technology. */
    v_irn := coalesce(public.get_player_research_level(p_player_id, 'intergalactic_research_network'), 0);
    if v_irn <= 0 then
        return v_own;
    end if;

    v_required := coalesce((select rbp.required_level
                              from public.research_building_prerequisites rbp
                             where rbp.research_id = p_research_id
                               and rbp.building_id = 'research_lab'), 0);

    /* Highest N lab levels of the player's OTHER planets that could run this research.
       Labs are planet-only (OGameX valid_planet_types = [Planet]), so moons never contribute. */
    select coalesce(sum(t.lvl), 0) into v_network
    from (
        select pb.level as lvl
        from public.planets p
        join public.planet_buildings pb
          on pb.planet_id = p.id and pb.building_id = 'research_lab'
        where p.player_id = p_player_id
          and p.is_destroyed = false
          and p.kind = 'PLANET'
          and p.id <> p_planet_id
          and pb.level >= v_required
        order by pb.level desc
        limit v_irn
    ) t;

    return v_own + coalesce(v_network, 0);
end;
$function$;

comment on function public.get_research_network_lab_level(uuid, uuid, text) is
$c$OGameX PlanetService::getResearchNetworkLabLevel() (planet-scoped variant) with the certified LGI ownership gate:
an `authenticated` caller may only resolve its OWN player and OWN planet ('PLAYER_NOT_OWNED_BY_AUTH_USER' /
'PLANET_NOT_OWNED_BY_AUTH_USER'); without a JWT (engine workers, AI service actor) the helper is unchanged.$c$;

-- ---------------------------------------------------------------------------
-- 2. calculate_research_time — player + planet ownership
-- ---------------------------------------------------------------------------
create or replace function public.calculate_research_time(
    p_player_id uuid,
    p_planet_id uuid,
    p_research_id text,
    p_target_level integer
)
returns table(
    research_id text,
    target_level integer,
    base_time_seconds numeric,
    research_speed numeric,
    final_time_seconds numeric
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_auth_user uuid := auth.uid();
    v_universe_id uuid;
    v_base_time numeric;
    v_speed numeric;
    v_base numeric;
    v_own integer := 0;
    v_effective integer := 0;
begin
    if v_auth_user is not null and not exists (
        select 1 from public.players pl where pl.id = p_player_id and pl.user_id = v_auth_user
    ) then
        raise exception 'PLAYER_NOT_OWNED_BY_AUTH_USER';
    end if;

    if v_auth_user is not null and not exists (
        select 1
        from public.planets p
        join public.players pl on pl.id = p.player_id
        where p.id = p_planet_id
          and pl.user_id = v_auth_user
          and not p.is_destroyed
    ) then
        raise exception 'PLANET_NOT_OWNED_BY_AUTH_USER';
    end if;

    select p.universe_id into v_universe_id from public.players p where p.id = p_player_id;
    if v_universe_id is null then
        raise exception 'Player not found: %', p_player_id;
    end if;

    select rd.base_research_time_seconds into v_base_time
    from public.research_definitions rd where rd.id = p_research_id;
    if v_base_time is null then
        raise exception 'Research definition not found: %', p_research_id;
    end if;

    select u.research_speed into v_speed from public.universes u where u.id = v_universe_id;

    v_base := public.calculate_research_time(p_research_id, p_target_level, v_universe_id);
    v_own := coalesce((select pb.level from public.planet_buildings pb
                        where pb.planet_id = p_planet_id and pb.building_id = 'research_lab'), 0);

    if p_planet_id is null then
        v_effective := v_own;
    else
        v_effective := coalesce(public.get_research_network_lab_level(p_player_id, p_planet_id, p_research_id), v_own);
    end if;

    if v_effective > v_own then
        v_base := round(v_base * ((1 + v_own)::numeric / (1 + v_effective)), 4);
    end if;

    return query select p_research_id, p_target_level, v_base_time, v_speed, v_base;
end;
$function$;

comment on function public.calculate_research_time(uuid, uuid, text, integer) is
$c$Network-aware research time (OGameX divisor ratio via get_research_network_lab_level) with the certified
ownership gate: an `authenticated` caller may only resolve its OWN player and OWN planet, so the laboratory level of
a foreign empire can no longer be inferred from the returned duration.$c$;

-- ---------------------------------------------------------------------------
-- 3. calculate_max_colony_slots — player ownership
-- ---------------------------------------------------------------------------
create or replace function public.calculate_max_colony_slots(p_player_id uuid)
returns integer
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_auth_user uuid := auth.uid();
begin
    if v_auth_user is not null and not exists (
        select 1 from public.players pl where pl.id = p_player_id and pl.user_id = v_auth_user
    ) then
        raise exception 'PLAYER_NOT_OWNED_BY_AUTH_USER';
    end if;

    return 1 + greatest(1, round(coalesce(public.get_player_research_level(p_player_id, 'astrophysics'), 0) / 2.0)::integer);
end;
$function$;

comment on function public.calculate_max_colony_slots(uuid) is
$c$Owner-approved colony cap (1 + max(1, round(astrophysics / 2))) with the certified ownership gate, so the
astrophysics level of a foreign player can no longer be read back as a colony cap.$c$;

-- ---------------------------------------------------------------------------
-- 4. check_colony_cap — player ownership, refusal as a blocked row
-- ---------------------------------------------------------------------------
create or replace function public.check_colony_cap(p_player_id uuid)
returns table(allowed boolean, reason text, max_slots integer, current_planets integer, astrophysics_level integer)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_auth_user uuid := auth.uid();
    v_astro integer;
    v_max integer;
    v_current integer;
begin
    if v_auth_user is not null and not exists (
        select 1 from public.players pl where pl.id = p_player_id and pl.user_id = v_auth_user
    ) then
        /* Blocked row, the same shape can_start_building / inspect_demolition use. The numbers stay NULL. */
        return query select false, 'PLAYER_NOT_OWNED_BY_AUTH_USER'::text, null::integer, null::integer, null::integer;
        return;
    end if;

    v_astro := coalesce(public.get_player_research_level(p_player_id, 'astrophysics'), 0);
    v_max := public.calculate_max_colony_slots(p_player_id);

    select count(*) into v_current
      from public.planets p
     where p.player_id = p_player_id
       and p.kind = 'PLANET'
       and p.is_destroyed = false;

    return query select
        (v_current < v_max),
        case when v_current < v_max then 'OK' else 'COLONY_CAP_REACHED' end,
        v_max,
        v_current,
        v_astro;
end;
$function$;

comment on function public.check_colony_cap(uuid) is
$c$Colony-cap preview for the OWNER (and the service actor). A foreign caller receives the blocked row
(allowed = false, reason = 'PLAYER_NOT_OWNED_BY_AUTH_USER', numbers NULL) instead of another player's astrophysics
level and colony count.$c$;

-- ---------------------------------------------------------------------------
-- 5. calculate_player_category_scores — player ownership
-- ---------------------------------------------------------------------------
create or replace function public.calculate_player_category_scores(p_player_id uuid)
returns table(economy_points bigint, research_points bigint, military_points bigint)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_auth_user uuid := auth.uid();
begin
    if v_auth_user is not null and not exists (
        select 1 from public.players pl where pl.id = p_player_id and pl.user_id = v_auth_user
    ) then
        raise exception 'PLAYER_NOT_OWNED_BY_AUTH_USER';
    end if;

    return query
    with planets_of_player as (
        select p.id
        from public.planets p
        where p.player_id = p_player_id and p.is_destroyed = false
    ),
    building_cost as (
        select pop.id as planet_id,
               coalesce((select sum(bc.metal + bc.crystal + bc.deuterium)
                           from public.planet_buildings pb
                           cross join lateral generate_series(1, pb.level) lvl
                           cross join lateral public.calculate_building_cost(pb.building_id, lvl) bc
                          where pb.planet_id = pop.id
                            and pb.building_id not in ('sensor_phalanx', 'jump_gate')), 0) as full_cost,
               coalesce((select sum(bc.metal + bc.crystal + bc.deuterium)
                           from public.planet_buildings pb
                           cross join lateral generate_series(1, pb.level) lvl
                           cross join lateral public.calculate_building_cost(pb.building_id, lvl) bc
                          where pb.planet_id = pop.id
                            and pb.building_id in ('sensor_phalanx', 'jump_gate')), 0) as station_cost,
               coalesce((select sum(pd.quantity * (dd.metal_cost + dd.crystal_cost + dd.deuterium_cost))
                           from public.planet_defenses pd
                           join public.defense_definitions dd on dd.id = pd.defense_id
                          where pd.planet_id = pop.id), 0) as defense_cost,
               coalesce((select sum(ps.quantity * (sd.base_metal + sd.base_crystal + sd.base_deuterium))
                           from public.planet_ships ps
                           join public.ship_definitions sd on sd.id = ps.ship_id
                          where ps.planet_id = pop.id and sd.ship_type = 'combat'), 0) as military_ships,
               coalesce((select sum(ps.quantity * (sd.base_metal + sd.base_crystal + sd.base_deuterium))
                           from public.planet_ships ps
                           join public.ship_definitions sd on sd.id = ps.ship_id
                          where ps.planet_id = pop.id and coalesce(sd.ship_type, 'civil') <> 'combat'), 0) as civil_ships
        from planets_of_player pop
    ),
    research_cost as (
        select coalesce(sum(rc.metal + rc.crystal + rc.deuterium), 0) as cost
        from public.player_research pr
        cross join lateral generate_series(1, pr.level) lvl
        cross join lateral public.calculate_research_cost(pr.research_id, lvl) rc
        where pr.player_id = p_player_id
    ),
    transit_cost as (
        select coalesce(sum(case when sd.ship_type = 'combat'
                                 then fms.quantity * (sd.base_metal + sd.base_crystal + sd.base_deuterium)
                                 else 0 end), 0) as military,
               coalesce(sum(case when coalesce(sd.ship_type, 'civil') <> 'combat'
                                 then fms.quantity * (sd.base_metal + sd.base_crystal + sd.base_deuterium)
                                 else 0 end), 0) as civil
        from public.fleet_movements fm
        join public.fleet_movement_ships fms on fms.fleet_id = fm.id
        join public.ship_definitions sd on sd.id = fms.ship_id
        where fm.player_id = p_player_id
          and fm.status not in ('COMPLETED', 'CANCELLED')
    )
    select
        coalesce((select sum(floor((b.full_cost + b.defense_cost + 0.5 * b.civil_ships + 0.5 * b.station_cost) / 1000))::bigint
                    from building_cost b), 0)
        + coalesce((select floor((0.5 * t.civil) / 1000)::bigint from transit_cost t), 0),
        coalesce((select floor(r.cost / 1000)::bigint from research_cost r), 0),
        coalesce((select sum(floor((b.defense_cost + b.military_ships + 0.5 * b.civil_ships + 0.5 * b.station_cost) / 1000))::bigint
                    from building_cost b), 0)
        + coalesce((select floor((t.military + 0.5 * t.civil) / 1000)::bigint from transit_cost t), 0);
end;
$function$;

comment on function public.calculate_player_category_scores(uuid) is
$c$OGameX HighscoreService bucket calculator (economy/research/military) with the certified ownership gate: the only
public score surface is `get_universe_ranking_by_category`, so an `authenticated` caller can no longer use this
contract to recompute (or read) another empire's buckets. The ranking workers run without a JWT and are unchanged.$c$;

-- ---------------------------------------------------------------------------
-- ACL: unchanged, re-asserted (least privilege, never anon).
-- ---------------------------------------------------------------------------
revoke all on function public.get_research_network_lab_level(uuid, uuid, text) from public, anon;
revoke all on function public.calculate_research_time(uuid, uuid, text, integer) from public, anon;
revoke all on function public.calculate_max_colony_slots(uuid) from public, anon;
revoke all on function public.check_colony_cap(uuid) from public, anon;
revoke all on function public.calculate_player_category_scores(uuid) from public, anon;

grant execute on function public.get_research_network_lab_level(uuid, uuid, text) to authenticated, service_role;
grant execute on function public.calculate_research_time(uuid, uuid, text, integer) to authenticated, service_role;
grant execute on function public.calculate_max_colony_slots(uuid) to authenticated, service_role;
grant execute on function public.check_colony_cap(uuid) to authenticated, service_role;
grant execute on function public.calculate_player_category_scores(uuid) to authenticated, service_role;

commit;
