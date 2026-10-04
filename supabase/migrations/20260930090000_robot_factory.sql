-- ROBOT FACTORY — definition + planet-wide build-speed integration (2026-09-30)
-- ============================================================================================
-- SOURCE (verified against CURRENT upstream, not the obsolete `application/Settings/*` path):
--   * lanedirt/OGameX `main` @ 2649076, `app/GameObjects/StationObjects.php`
--       id 14, machine_name `robot_factory`, `GameObjectPrice(400, 120, 200, 0, 2)`
--       (metal, crystal, deuterium, energy, factor) and NO `requirements` (prerequisite-free).
--       OGameX gives the object NO production/build-time field: it defines the building but does
--       not implement the speed effect, so the effect below comes from the classic source.
--   * Classic OGame official wiki (sidian.app/s/ogame-wiki "Robotics Factory", 2026-05-16):
--       cost 400/120/200, 2x cost factor, no prerequisites, no energy cost, no stated max level;
--       BUILD TIME REDUCTION:  Build time(L) = Base time / (1 + R)    (R = Robotics Factory level)
--       and the shipyard page confirms the same divisor for shipyard construction.
--
-- PRODUCT DECISION (product owner, 2026-09-30) — DELIBERATE DIVERGENCE, recorded:
--   LGI applies the (1 + R) divisor to the WHOLE planetary construction engine: buildings, research,
--   ships and defences. Classic OGame documents it against building and shipyard times; extending it
--   to research is an LGI decision, not an upstream claim.
--   The classic Nanite Factory term (2^N) is NOT implemented: LGI has no `nanite_factory`, so N = 0
--   and the divisor reduces to exactly `1 + R`.
--
-- MUST NOT TOUCH (proved by the regression fixture): fleet travel time, combat, expeditions,
--   economy ticks, resource production per hour, cooldowns.
--
-- INTEGRATION — one single definition of the rule, ONE point per queue family (never copied per
-- dispatcher). LGI already funnels every queue through a time helper:
--   * `calculate_ship_build_time(uuid,text)`      receives the planet -> rate multiplied in place
--   * `calculate_defense_build_time(uuid,text)`  receives the planet -> rate multiplied in place
--   * `calculate_research_time(uuid,uuid,text,int)` is the ONLY research entry the dispatchers use
--     (`start_research` and `can_start_research` both call it) and it already receives the planet
--   * buildings: the core `calculate_building_time(text,int,uuid)` takes a UNIVERSE, not a planet,
--     so a planet-aware OVERLOAD is added and the two call sites (`start_building`,
--     `get_planet_building_preview`) are repointed. The 3-arg core is left byte-identical.
--
-- PIPELINE (single consistent interpretation; the divisor is multiplicative, so its position
-- relative to the other rates is mathematically irrelevant — it is folded into the effective rate
-- exactly where the existing rates already are):
--   buildings : base·time_factor^(L-1) / (building_speed·scaling·(1+R)) / (1+item_bonus%)
--   research  : base·time_factor^(L-1) / (research_speed·scaling)      / (1+R) / IRN multiplier
--   ships     : base / shipyard / (building_speed·scaling·(1+R))
--   defences  : base / shipyard / (building_speed·sqrt(evolution)·(1+R))
--
-- EXISTING QUEUES: an upgrade affects only queues STARTED afterwards. LGI stores an absolute
--   `finishes_at` at enqueue time and its workers compare `now() >= finishes_at`; nothing rewrites a
--   queued timestamp. Classic OGame shortens the REMAINING time of an already queued item, so this
--   is a DOCUMENTED DIVERGENCE, not an oversight.
--
-- SELF BUILD TIME: neither source states the construction time OF the Robotics Factory itself. LGI's
--   own facility buildings (shipyard, research_lab, fusion_plant) all use time_factor 2 and
--   base_build_time_seconds 60, so that convention is used. LGI-internal precedent, not upstream.

begin;

-- ---------------------------------------------------------------- 1. definition
insert into public.building_definitions(
    id, name, description, base_metal, base_crystal, base_deuterium,
    cost_factor, time_factor, base_build_time_seconds, valid_kinds)
values (
    'robot_factory', 'Robotics Factory',
    'Builds construction robots: every level shortens EVERY construction on the planet (buildings, research, ships, defences) by a factor of (1 + level).',
    400, 120, 200, 2, 2, 60, '{PLANET}')
on conflict (id) do update
   set name = excluded.name,
       description = excluded.description,
       base_metal = excluded.base_metal,
       base_crystal = excluded.base_crystal,
       base_deuterium = excluded.base_deuterium,
       cost_factor = excluded.cost_factor,
       time_factor = excluded.time_factor,
       base_build_time_seconds = excluded.base_build_time_seconds,
       valid_kinds = excluded.valid_kinds;

-- ------------------------------------------------- 2. the single rule (1 + R)
create or replace function public.calculate_robot_factory_build_speed(p_planet_id uuid)
returns numeric
language sql
stable
as $function$
    select 1 + coalesce(
        (select max(pb.level) from public.planet_buildings pb
          where pb.planet_id = p_planet_id and pb.building_id = 'robot_factory'), 0);
$function$;

-- --------------------- 3. planet-aware overload for BUILDINGS (core stays intact)
create or replace function public.calculate_building_time(
    p_building_id text, p_target_level integer, p_universe_id uuid, p_planet_id uuid)
returns numeric
language sql
stable
as $function$
    select public.calculate_building_time(p_building_id, p_target_level, p_universe_id)
           / public.calculate_robot_factory_build_speed(p_planet_id);
$function$;

-- ------------------- 4. patch the four queue families (asserted, fail-loud patching)
-- Each replacement targets an exact fragment of the LIVE body. If an anchor is missing the whole
-- migration aborts instead of silently shipping a half-integrated mechanic.
do $patch$
declare
    v_def text;
    v_base text;
    v_oid oid;
begin
    -- (a) SHIPS: fold the divisor into the effective rate (planet is already a parameter).
    select p.oid, pg_get_functiondef(p.oid) into v_oid, v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'calculate_ship_build_time';
    if v_def is null then
        raise exception 'ROBOT_FACTORY: calculate_ship_build_time not found';
    end if;
    v_base := v_def;
    v_def := replace(v_def,
        'v_building_rate := v_building_speed * v_scaling;',
        'v_building_rate := v_building_speed * v_scaling * public.calculate_robot_factory_build_speed(p_planet_id);');
    if v_def = v_base then raise exception 'ROBOT_FACTORY: ship rate anchor not found'; end if;
    execute v_def;

    -- (b) DEFENCES: same, with this family's own scaling term.
    select p.oid, pg_get_functiondef(p.oid) into v_oid, v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'calculate_defense_build_time';
    if v_def is null then
        raise exception 'ROBOT_FACTORY: calculate_defense_build_time not found';
    end if;
    v_base := v_def;
    v_def := replace(v_def,
        'v_building_rate := v_building_speed * sqrt(v_evolution);',
        'v_building_rate := v_building_speed * sqrt(v_evolution) * public.calculate_robot_factory_build_speed(p_planet_id);');
    if v_def = v_base then raise exception 'ROBOT_FACTORY: defence rate anchor not found'; end if;
    execute v_def;

    -- (c) RESEARCH: the single entry both research dispatchers use, and it already has the planet.
    select p.oid, pg_get_functiondef(p.oid) into v_oid, v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.oid = 'public.calculate_research_time(uuid,uuid,text,integer)'::regprocedure;
    if v_def is null then
        raise exception 'ROBOT_FACTORY: calculate_research_time(uuid,uuid,text,integer) not found';
    end if;
    v_base := v_def;
    v_def := replace(v_def,
        'v_base := public.calculate_research_time(p_research_id, p_target_level, v_universe_id);',
        'v_base := public.calculate_research_time(p_research_id, p_target_level, v_universe_id) / public.calculate_robot_factory_build_speed(p_planet_id);');
    if v_def = v_base then raise exception 'ROBOT_FACTORY: research anchor not found'; end if;
    execute v_def;

    -- (d1) BUILDINGS: repoint start_building at the planet-aware overload.
    select p.oid, pg_get_functiondef(p.oid) into v_oid, v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'start_building';
    if v_def is null then
        raise exception 'ROBOT_FACTORY: start_building not found';
    end if;
    v_base := v_def;
    v_def := replace(v_def,
        'public.calculate_building_time(p_building_id,v_target_level,v_universe_id)',
        'public.calculate_building_time(p_building_id,v_target_level,v_universe_id,p_planet_id)');
    if v_def = v_base then raise exception 'ROBOT_FACTORY: start_building anchor not found'; end if;
    execute v_def;

    -- (d2) BUILDINGS: repoint the read contract so the UI shows the same duration.
    select p.oid, pg_get_functiondef(p.oid) into v_oid, v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'get_planet_building_preview';
    if v_def is null then
        raise exception 'ROBOT_FACTORY: get_planet_building_preview not found';
    end if;
    v_base := v_def;
    v_def := replace(v_def,
        'public.calculate_building_time(v_def.def_id, v_eval.target_level, v_universe_id)',
        'public.calculate_building_time(v_def.def_id, v_eval.target_level, v_universe_id, p_planet_id)');
    if v_def = v_base then raise exception 'ROBOT_FACTORY: building preview anchor not found'; end if;
    execute v_def;
end;
$patch$;

-- ------------------------------------------------------------ 5. grants
grant execute on function public.calculate_robot_factory_build_speed(uuid) to authenticated, service_role;
grant execute on function public.calculate_building_time(text, integer, uuid, uuid) to authenticated, service_role;

do $guard$
declare
    v_ok boolean;
begin
    -- 1. the definition exists with the OGameX/classic cost and is planet-only.
    if not exists (
        select 1 from public.building_definitions
         where id = 'robot_factory'
           and base_metal = 400 and base_crystal = 120 and base_deuterium = 200
           and cost_factor = 2 and valid_kinds = '{PLANET}'
    ) then
        raise exception 'ROBOT_FACTORY: definition missing or does not match the source cost';
    end if;

    -- 2. it declares no prerequisite, because no source declares one.
    if exists (select 1 from public.building_prerequisites where building_id = 'robot_factory')
       or exists (select 1 from public.building_research_prerequisites where building_id = 'robot_factory') then
        raise exception 'ROBOT_FACTORY: unexpected prerequisite on robot_factory';
    end if;

    -- 3. the rule really reached the four families.
    select (
        (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = 'calculate_ship_build_time')
        and (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = 'calculate_defense_build_time')
        and (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = 'start_building')
        and (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = 'get_planet_building_preview')
        and (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public'
            and p.oid = 'public.calculate_research_time(uuid,uuid,text,integer)'::regprocedure)
    ) like '%calculate_robot_factory_build_speed%' into v_ok;
    if not v_ok then
        raise exception 'ROBOT_FACTORY: the rule did not reach every queue family';
    end if;

    -- 4. the universe-only building core is untouched (other callers keep their behaviour).
    if (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.oid = 'public.calculate_building_time(text,integer,uuid)'::regprocedure)
       like '%robot_factory%' then
        raise exception 'ROBOT_FACTORY: the universe-only building core must stay unmodified';
    end if;

    -- 5. production and the fleet engine must not mention the building at all.
    if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public'
                  and p.proname in ('calculate_planet_production', 'calculate_planet_energy_balance',
                                    'calculate_fleet_travel_time', 'calculate_mission_fleet_speed_multiplier',
                                    'calculate_fleet_distance')
                  and p.prosrc ilike '%robot_factory%') then
        raise exception 'ROBOT_FACTORY: the building leaked into production or the fleet engine';
    end if;

    -- 6. the helper must not be reachable by anon.
    if has_function_privilege('anon', 'public.calculate_robot_factory_build_speed(uuid)', 'EXECUTE') then
        raise exception 'ROBOT_FACTORY: the anonymous surface must stay closed';
    end if;
end;
$guard$;

commit;

--
-- PREREQUISITES: none, because both sources say none. OGameX additionally gates the SHIPYARD behind
--   `robot_factory 2`; LGI does not enforce that today and its certification fixtures build ships on
--   planets with no robot factory. Adding it would invalidate every existing empire, so it is NOT
--   added here — flagged as a product decision.
--
-- valid_kinds: the classic wiki files it under Facilities and lists only Lunar Base / Sensor
--   Phalanx / Jump Gate as moon buildings -> PLANET only. OGameX leaves `valid_planet_types` unset
--   (which under its convention means both) — divergence recorded.
-- ============================================================================================
