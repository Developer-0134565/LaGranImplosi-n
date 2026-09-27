-- =====================================================================
-- RESEARCH LAB + RESEARCH BUILDING GATES + INTERGALACTIC RESEARCH NETWORK
-- LGI ↔ OGameX — owner-approved product decision (2026-09-26)
-- =====================================================================
-- OGameX reference (structural):
--   app/GameObjects/StationObjects.php  :: `research_lab` id 31 — price 200/400/200, factor 2,
--                                          valid_planet_types = [Planet], no requirements
--   app/GameObjects/ResearchObjects.php :: the 16 `new GameObjectRequirement('research_lab', N)` gates
--   app/Services/PlanetService.php      :: getResearchNetworkLabLevel() — IRN effective lab level
--
-- Adopted rules:
--   * Research Lab: 200 metal / 400 crystal / 200 deuterium, cost factor 2, PLANET only, no level cap and no
--     prerequisites (OGameX declares none: available from the start).
--   * The 16 research → research_lab gates verbatim from OGameX (OGameX `armor_technology` ↔ LGI
--     `armour_technology`; every other id matches).
--   * IRN: effective lab level = own lab level + (when IRN > 0) the sum of the N highest lab levels among the
--     player's OTHER planets that satisfy the research's lab requirement (N = IRN level, own planet excluded),
--     exactly as OGameX `getResearchNetworkLabLevel`.
--
-- LGI adaptation (documented, not invented):
--   * LGI's research time curve is its own (`base_research_time_seconds × time_factor^(level-1) / speed`) and
--     has no laboratory term, unlike OGame's `(metal+crystal)/(1000·(1+lab))`. OGameX's rule is therefore
--     ported as the equivalent divisor ratio `(1 + own_lab) / (1 + effective_lab)`, which equals 1 whenever
--     IRN is 0 or no eligible lab exists → zero behaviour change without IRN, and the same relative reduction
--     OGameX applies.
--   * The certified 3-argument `calculate_research_time` overloads are left untouched (research_lifecycle.sql
--     asserts their equivalence); the dispatchers switch to a new 4-argument overload.
--   * The gate mechanism itself (`research_building_prerequisites` + `check_research_building_prerequisites`,
--     consumed by `start_research` and `can_start_research`) was already certified and intentionally empty:
--     this migration only fills its content.
-- =====================================================================

insert into public.building_definitions
    (id, name, description, base_metal, base_crystal, base_deuterium, cost_factor,
     base_build_time_seconds, time_factor, max_level, valid_kinds)
values
    ('research_lab', 'Laboratorio de investigación',
     'Reúne el equipamiento necesario para investigar. Necesario para casi todas las tecnologías; solo puede construirse en planetas.',
     200, 400, 200, 2, 60, 2, null, '{PLANET}')
on conflict (id) do nothing;

-- OGameX ResearchObjects: research → research_lab level (16 gates, verbatim).
insert into public.research_building_prerequisites(research_id, building_id, required_level) values
    ('energy_technology', 'research_lab', 1),
    ('laser_technology', 'research_lab', 1),
    ('ion_technology', 'research_lab', 4),
    ('hyperspace_technology', 'research_lab', 7),
    ('plasma_technology', 'research_lab', 4),
    ('combustion_drive', 'research_lab', 1),
    ('impulse_drive', 'research_lab', 2),
    ('hyperspace_drive', 'research_lab', 7),
    ('espionage_technology', 'research_lab', 3),
    ('computer_technology', 'research_lab', 1),
    ('astrophysics', 'research_lab', 3),
    ('intergalactic_research_network', 'research_lab', 10),
    ('graviton_technology', 'research_lab', 12),
    ('weapons_technology', 'research_lab', 4),
    ('shielding_technology', 'research_lab', 6),
    ('armour_technology', 'research_lab', 2)
on conflict do nothing;

-- ---------------------------------------------------------------------
-- OGameX PlanetService::getResearchNetworkLabLevel() — planet-scoped variant.
-- ---------------------------------------------------------------------
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
    v_own integer := 0;
    v_irn integer := 0;
    v_required integer := 0;
    v_network integer := 0;
begin
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

-- ---------------------------------------------------------------------
-- Research time with the laboratory network (OGameX divisor ratio).
-- Mirrors the certified table shape of calculate_research_time(uuid,text,integer) because
-- can_start_research consumes `crt.final_time_seconds`. Equals the canonical value when IRN = 0.
-- ---------------------------------------------------------------------
drop function if exists public.calculate_research_time(uuid, uuid, text, integer);

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
    v_universe_id uuid;
    v_base_time numeric;
    v_speed numeric;
    v_base numeric;
    v_own integer := 0;
    v_effective integer := 0;
begin
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

-- ---------------------------------------------------------------------
-- CERTIFIED-DISPATCHER PATCHES — the two research paths use the network-aware time.
-- Anchors are whitespace-independent (the call expression itself), and both replacements are asserted.
-- ---------------------------------------------------------------------
do $patch$
declare
    v_src text;
    v_old text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'start_research';

    if v_src is null then
        raise exception 'PATCH TARGET MISSING: start_research';
    end if;
    if position('select crt.final_time_seconds into v_research_time' in v_src) > 0 then
        return;
    end if;

    v_old := 'v_research_time:=public.calculate_research_time(p_player_id,p_planet_id,p_research_id,v_target_level);';
    v_new := 'select crt.final_time_seconds into v_research_time from public.calculate_research_time(p_player_id,p_planet_id,p_research_id,v_target_level) crt;';

    if position(v_old in v_src) = 0 then
        raise exception 'PATCH ANCHOR NOT FOUND: start_research scalar time call';
    end if;
    execute replace(v_src, v_old, v_new);
end;
$patch$;

do $patch$
declare
    v_src text;
    v_old text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'can_start_research';

    if v_src is null then
        raise exception 'PATCH TARGET MISSING: can_start_research';
    end if;
    if position('calculate_research_time(p_player_id,p_planet_id,p_research_id,v_target_level)' in v_src) > 0 then
        return;
    end if;

    v_old := 'calculate_research_time(p_player_id,p_research_id,v_target_level)';
    v_new := 'calculate_research_time(p_player_id,p_planet_id,p_research_id,v_target_level)';

    if position(v_old in v_src) = 0 then
        raise exception 'PATCH ANCHOR NOT FOUND: can_start_research time call';
    end if;
    execute replace(v_src, v_old, v_new);
end;
$patch$;

-- ACL: least privilege, no anon bypass (the AI service actor uses service_role).
revoke all on function public.get_research_network_lab_level(uuid, uuid, text) from public;
revoke all on function public.calculate_research_time(uuid, uuid, text, integer) from public;

grant execute on function public.get_research_network_lab_level(uuid, uuid, text) to authenticated, service_role;
grant execute on function public.calculate_research_time(uuid, uuid, text, integer) to authenticated, service_role;
