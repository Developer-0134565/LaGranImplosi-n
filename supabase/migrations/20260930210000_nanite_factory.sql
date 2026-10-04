-- NANITE FACTORY — definition + 2^N build-speed integration (2026-09-30)
-- ================================================================================================
-- SOURCE (lanedirt/OGameX `main`, verified today, current paths):
--   app/GameObjects/StationObjects.php
--     id 15 · machine_name 'nano_factory'
--     requirements = [ GameObjectRequirement('computer_technology', 10),
--                     GameObjectRequirement('robot_factory', 10) ]
--     price = new GameObjectPrice(1000000, 500000, 100000, 0, 2)
--     valid_planet_types = [PlanetType::Planet]
--
--   app/Services/PlanetService.php — the 2^N divisor and, CRUCIALLY, its SCOPE:
--     getBuildingConstructionTime():
--         special case for the factory itself (drops the max(4 - next_level/2, 1) factor)
--         time_hours = (metal + crystal) / (2500 * max(4 - next_level/2, 1)
--                            * (1 + robot_factory) * universe_speed * 2^nanite)
--     getUnitConstructionTime()   (ships AND defences share this one):
--         time_hours = (metal + crystal)
--                      / (2500 * (1 + shipyard) * universe_speed * 2^nanite)
--     getTechnologyResearchTime(): NO `$nanitefactory_level` anywhere.
--         ⇒ the Nanite Factory accelerates BUILDINGS and UNITS, never RESEARCH. That is an explicit
--           type distinction upstream, and Q6 requires respecting it.
--         ⇒ upstream's unit formula also has NO (1 + robot_factory) factor. LGI deliberately diverges
--           there (product decision recorded in 20260930090000_robot_factory.sql and certified by
--           tests/robot_factory.sql). That divergence is PRESERVED: the Nanite Factory enters as an
--           INDEPENDENT multiplicative divisor so both effects compose. Reverting the robot_factory
--           scope here would silently reopen a closed decision, so it is not touched.
--
-- LGI ADAPTATION (one coherent time source, nothing else changed)
--   LGI derives every build time from `base_build_time_seconds`, not from (metal + crystal): that
--   table-wide convention is a recorded LGI difference (Q9) and is NOT changed here. The Nanite Factory
--   is integrated as `calculate_nanite_factory_build_speed(planet)` = 2^level, mirroring the already
--   certified `calculate_robot_factory_build_speed` pattern, folded into the SAME effective rate.
--   Research is deliberately NOT touched: `calculate_research_time` stays byte-identical.
--
-- SECURITY: the helper is read-only, SECURITY INVOKER, fixed search_path, EXECUTE for authenticated
--   + service_role (the robot factory helper's posture). No new client surface: the row and its
--   prerequisites are enforced by the existing dispatchers.
--
-- MUST NOT TOUCH: research times, fleet travel, combat, expeditions, economy ticks.

begin;

-- ---------------------------------------------------------------- 1. definition (OGameX price/factor/kind verbatim)
insert into public.building_definitions(
    id, name, description, base_metal, base_crystal, base_deuterium,
    cost_factor, time_factor, base_build_time_seconds, valid_kinds)
values (
    'nano_factory', 'Nanite Factory',
    'Nanorobotic factory: every level halves the construction time of buildings, ships and defences (2^level). It does not affect research.',
    1000000, 500000, 100000, 2, 2, 60, '{PLANET}')
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

-- ---------------------------------------------------------------- 2. prerequisites (OGameX: computer_technology 10 + robot_factory 10)
insert into public.building_prerequisites(building_id, prerequisite_building_id, required_level)
values ('nano_factory', 'robot_factory', 10)
on conflict (building_id, prerequisite_building_id) do update
   set required_level = excluded.required_level;

insert into public.building_research_prerequisites(building_id, research_id, required_level)
values ('nano_factory', 'computer_technology', 10)
on conflict (building_id, research_id) do update
   set required_level = excluded.required_level;

-- ---------------------------------------------------------------- 3. the single rule: 2^level
create or replace function public.calculate_nanite_factory_build_speed(p_planet_id uuid)
returns numeric
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
    select power(2, coalesce(
        (select max(pb.level) from public.planet_buildings pb
          where pb.planet_id = p_planet_id and pb.building_id = 'nano_factory'), 0));
$function$;

revoke all on function public.calculate_nanite_factory_build_speed(uuid) from public, anon;
grant execute on function public.calculate_nanite_factory_build_speed(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------- 4. fold it into the ONE effective rate
-- 4.1 buildings: the planet-aware overload already divided by the robot factory; add the nanite one.
create or replace function public.calculate_building_time(p_building_id text, p_target_level integer, p_universe_id uuid, p_planet_id uuid)
returns numeric
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
    select public.calculate_building_time(p_building_id, p_target_level, p_universe_id)
           / public.calculate_robot_factory_build_speed(p_planet_id)
           / public.calculate_nanite_factory_build_speed(p_planet_id);
$function$;

-- 4.2 ships and 4.3 defences: guarded text patch, so the rest of the certified body cannot drift.
do $$
declare
    v_def text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_def from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'calculate_ship_build_time';
    if v_def is null then raise exception 'NANITE_PATCH: calculate_ship_build_time not found'; end if;
    v_new := replace(v_def,
        E'    v_building_rate := v_building_speed * v_scaling * public.calculate_robot_factory_build_speed(p_planet_id);',
        E'    v_building_rate := v_building_speed * v_scaling\n                               * public.calculate_robot_factory_build_speed(p_planet_id)\n                               * public.calculate_nanite_factory_build_speed(p_planet_id);');
    if v_new = v_def then raise exception 'NANITE_PATCH: calculate_ship_build_time anchor not found'; end if;
    execute v_new;

    select pg_get_functiondef(p.oid) into v_def from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'calculate_defense_build_time';
    if v_def is null then raise exception 'NANITE_PATCH: calculate_defense_build_time not found'; end if;
    v_new := replace(v_def,
        E'v_building_rate := v_building_speed * sqrt(v_evolution) * public.calculate_robot_factory_build_speed(p_planet_id);',
        E'v_building_rate := v_building_speed * sqrt(v_evolution)\n                               * public.calculate_robot_factory_build_speed(p_planet_id)\n                               * public.calculate_nanite_factory_build_speed(p_planet_id);');
    if v_new = v_def then raise exception 'NANITE_PATCH: calculate_defense_build_time anchor not found'; end if;
    execute v_new;
end;
$$;

-- ---------------------------------------------------------------- 5. post-conditions (fail loudly)
do $$
declare
    v_bad integer;
begin
    if not exists (select 1 from public.building_definitions
                    where id = 'nano_factory' and base_metal = 1000000 and base_crystal = 500000
                      and base_deuterium = 100000 and cost_factor = 2 and valid_kinds = '{PLANET}') then
        raise exception 'NANITE: definition drifted from the OGameX price/kind';
    end if;
    if (select count(*) from public.building_prerequisites
         where building_id = 'nano_factory' and prerequisite_building_id = 'robot_factory'
           and required_level = 10) <> 1 then
        raise exception 'NANITE: robot_factory 10 prerequisite missing';
    end if;
    if (select count(*) from public.building_research_prerequisites
         where building_id = 'nano_factory' and research_id = 'computer_technology'
           and required_level = 10) <> 1 then
        raise exception 'NANITE: computer_technology 10 prerequisite missing';
    end if;
    -- research MUST NOT depend on the nanite factory: upstream getTechnologyResearchTime has no such term
    if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname = 'calculate_research_time'
                  and p.prosrc ilike '%nanite%') then
        raise exception 'NANITE: research time must not depend on the nanite factory (OGameX)';
    end if;
end;
$$;

commit;
