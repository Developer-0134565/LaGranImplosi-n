-- BUILDING PREREQUISITES FOR RESEARCH — LA GRAN IMPLOSIÓN
-- --------------------------------------------------------------------------------------------
-- OGameX evidence (ResearchObjects.php, exhaustive extraction of the 16 research objects): 14 technologies
-- require `research_lab` at a fixed level (energy 1, armour 2, espionage 3, astrophysics 3, combustion 1,
-- impulse 2, laser 1, computer 1, shielding 6, ion 4, plasma 4, graviton 12, weapon 4, hyperspace 7,
-- hyperspace_drive 7, IRN 10) and the remaining requirements are research→research (already implemented in
-- `research_prerequisites`).
--
-- LGI reality: `building_definitions` has 8 rows and **no research laboratory**, so today there is NO
-- OGameX-backed building requirement that maps to a building that exists. Introducing the laboratory is a
-- PRODUCT DECISION (already recorded: it also gates IRN and graviton) and is explicitly NOT taken here.
-- Therefore this migration implements the MECHANISM with **zero content rows**: populating it would block
-- every gated research for every existing player, which is precisely the automatic product decision the
-- mission forbids.
--
-- Architecture decision: the existing `building_prerequisites(building_id, prerequisite_building_id,
-- required_level)` is a **building → building** table (that is how `start_building` consumes it), so research
-- rows would misuse it. The research dimension gets its own table, mirroring the existing prerequisite tables
-- (RLS enabled + `deny_direct_api_access`, SELECT granted but denied by policy, full access for service_role).
--
-- Semantics (OGameX parity): the requirement is evaluated **on the planet where the research is started**,
-- exactly like OGameX's per-planet `ObjectService::objectRequirementsMet($machine_name, $planet)`.
--
-- Authority: one shared helper is the single source of truth for the building dimension and it is consumed by
-- BOTH surfaces — the client contract `can_start_research` (availability + UI) and the write authority
-- `start_research` (the only path that charges resources and enqueues). No client-supplied identity is used:
-- `can_start_research`/`start_research` keep their existing `auth.uid()` → `players.user_id` → planet gates,
-- so a foreign planet/building can never satisfy a requirement.

-- 1) The table (mechanism only; intentionally empty in production).
create table if not exists public.research_building_prerequisites (
    research_id    text not null references public.research_definitions(id) on delete cascade,
    building_id    text not null references public.building_definitions(id) on delete cascade,
    required_level integer not null default 1,
    created_at     timestamptz not null default now(),
    constraint research_building_prerequisites_level_check check (required_level >= 1),
    primary key (research_id, building_id)
);

comment on table public.research_building_prerequisites is
$c$Building prerequisites of a research (OGameX: `research_lab` level N). Evaluated per planet, on the planet
where the research is started. The table is intentionally EMPTY: LGI has no research laboratory building, and
inventing one (or silently blocking research) is a product decision, not an implementation detail.
Mechanism certified by supabase/tests/research_building_prerequisites.sql.$c$;

alter table public.research_building_prerequisites enable row level security;

drop policy if exists deny_direct_api_access on public.research_building_prerequisites;
create policy deny_direct_api_access on public.research_building_prerequisites
    for all to anon, authenticated using (false);

grant select on public.research_building_prerequisites to anon, authenticated;
grant all on public.research_building_prerequisites to service_role;

-- 2) Shared helper: the only place that decides the building dimension (used by both authorities).
create or replace function public.check_research_building_prerequisites(p_planet_id uuid, p_research_id text)
returns table(building_id text, required_level integer, current_level integer, satisfied boolean)
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
    select rbp.building_id,
           rbp.required_level,
           coalesce(pb.level, 0) as current_level,
           coalesce(pb.level, 0) >= rbp.required_level as satisfied
    from public.research_building_prerequisites rbp
    left join public.planet_buildings pb
           on pb.planet_id = p_planet_id
          and pb.building_id = rbp.building_id
    where rbp.research_id = p_research_id
    order by rbp.building_id;
$function$;

revoke all on function public.check_research_building_prerequisites(uuid, text) from public;
revoke all on function public.check_research_building_prerequisites(uuid, text) from anon;
revoke all on function public.check_research_building_prerequisites(uuid, text) from authenticated;
grant execute on function public.check_research_building_prerequisites(uuid, text) to service_role;

-- 3) Client contract: the availability payload now carries both dimensions in the SAME jsonb
--    (research entries keep their exact shape and gain `kind`; building entries add `building_id`).
DO $patch_can_start$
DECLARE
    v_def text;
    v_old text;
    v_new text;
    v_occ integer;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'can_start_research';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'RESEARCH-PREREQ: can_start_research not found';
    END IF;

    v_old := $frag$    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'research_id',rp.prerequisite_research_id,
      'required_level',rp.required_level,
      'current_level',coalesce(pr.level,0),
      'satisfied',coalesce(pr.level,0)>=rp.required_level
    ) ORDER BY rp.prerequisite_research_id),'[]'::jsonb)
    INTO v_prerequisites
    FROM public.research_prerequisites rp
    LEFT JOIN public.player_research pr ON pr.player_id=p_player_id AND pr.research_id=rp.prerequisite_research_id
    WHERE rp.research_id=p_research_id;$frag$;

    v_new := $frag$    SELECT coalesce(jsonb_agg(x.entry ORDER BY x.sort_key),'[]'::jsonb)
    INTO v_prerequisites
    FROM (
      SELECT 'research:'||rp.prerequisite_research_id AS sort_key,
             jsonb_build_object(
               'kind','research',
               'research_id',rp.prerequisite_research_id,
               'required_level',rp.required_level,
               'current_level',coalesce(pr.level,0),
               'satisfied',coalesce(pr.level,0)>=rp.required_level
             ) AS entry
        FROM public.research_prerequisites rp
        LEFT JOIN public.player_research pr ON pr.player_id=p_player_id AND pr.research_id=rp.prerequisite_research_id
       WHERE rp.research_id=p_research_id
      UNION ALL
      SELECT 'building:'||bp.building_id AS sort_key,
             jsonb_build_object(
               'kind','building',
               'building_id',bp.building_id,
               'required_level',bp.required_level,
               'current_level',bp.current_level,
               'satisfied',bp.satisfied
             ) AS entry
        FROM public.check_research_building_prerequisites(p_planet_id, p_research_id) bp
    ) x;$frag$;

    v_old := replace(replace(v_old, chr(13)||chr(10), chr(10)), chr(13), '');
    v_new := replace(replace(v_new, chr(13)||chr(10), chr(10)), chr(13), '');
    IF position(chr(13)||chr(10) in v_def) > 0 THEN
        v_old := replace(v_old, chr(10), chr(13)||chr(10));
        v_new := replace(v_new, chr(10), chr(13)||chr(10));
    END IF;

    SELECT (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) INTO v_occ;
    IF v_occ <> 1 THEN
        RAISE EXCEPTION 'RESEARCH-PREREQ: prerequisites fragment matched % time(s), expected 1', v_occ;
    END IF;

    EXECUTE replace(v_def, v_old, v_new);
END;
$patch_can_start$;

-- 4) Write authority: the same helper gates the path that charges and enqueues (no bypass via any RPC).
DO $patch_start_research$
DECLARE
    v_def text;
    v_old text;
    v_new text;
    v_occ integer;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'start_research';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'RESEARCH-PREREQ: start_research not found';
    END IF;

    v_old := $frag$    if not public.can_research(p_player_id, p_research_id, v_target_level) then
        raise exception 'RESEARCH_REQUIREMENTS_NOT_MET';
    end if;$frag$;

    v_new := $frag$    if not public.can_research(p_player_id, p_research_id, v_target_level) then
        raise exception 'RESEARCH_REQUIREMENTS_NOT_MET';
    end if;

    -- Building prerequisites (OGameX: `research_lab` level N), evaluated on the planet that starts the
    -- research. Same error code as the research dimension: the runnable state is the same rejection.
    if exists (
        select 1
        from public.check_research_building_prerequisites(p_planet_id, p_research_id) bp
        where not bp.satisfied
    ) then
        raise exception 'RESEARCH_REQUIREMENTS_NOT_MET';
    end if;$frag$;

    v_old := replace(replace(v_old, chr(13)||chr(10), chr(10)), chr(13), '');
    v_new := replace(replace(v_new, chr(13)||chr(10), chr(10)), chr(13), '');
    IF position(chr(13)||chr(10) in v_def) > 0 THEN
        v_old := replace(v_old, chr(10), chr(13)||chr(10));
        v_new := replace(v_new, chr(10), chr(13)||chr(10));
    END IF;

    SELECT (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) INTO v_occ;
    IF v_occ <> 1 THEN
        RAISE EXCEPTION 'RESEARCH-PREREQ: start_research guard fragment matched % time(s), expected 1', v_occ;
    END IF;

    EXECUTE replace(v_def, v_old, v_new);
END;
$patch_start_research$;
