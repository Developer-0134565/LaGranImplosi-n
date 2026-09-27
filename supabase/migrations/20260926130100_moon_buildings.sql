-- MOON BUILDINGS — definitions, kind gating and the missing building→research prerequisite (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- OGameX `StationObjects` (@ 7c420bad):
--   lunar_base     id 41, 20 000 / 40 000 / 20 000, factor 2, MOON only, no requirements
--   sensor_phalanx id 42, 20 000 / 40 000 / 10 000, factor 2, MOON only, requires lunar_base 1
--   jump_gate      id 43, 2 000 000 / 4 000 000 / 2 000 000, factor 2, MOON only,
--                  requires lunar_base 1 + hyperspace_technology 7
--
-- LGI had no way to say "this building only exists on a moon" (`building_definitions` had no valid-types column)
-- and no building→research prerequisite table (only the mirror, `research_building_prerequisites`). Both gaps are
-- closed HERE, explicitly and generically, instead of hardcoding moon rules inside a dispatcher:
--   * `building_definitions.valid_kinds text[] not null default '{PLANET}'`;
--   * `building_research_prerequisites(building_id, research_id, required_level)` — the mirror of the existing
--     `research_building_prerequisites`;
--   * a BEFORE INSERT guard on `building_queue` (the same no-regression pattern used for fleet slots) that enforces
--     both. `start_building` keeps enforcing `building_prerequisites` itself and is NOT modified.
--
-- Time model: every existing building uses base_build_time_seconds = 60 and time_factor = 2, so the three moon
-- buildings reuse that same LGI convention (no new time model is invented).
begin;

alter table public.building_definitions
    add column if not exists valid_kinds text[] not null default '{PLANET}';

comment on column public.building_definitions.valid_kinds is
$c$Planet kinds on which the building may be raised ('PLANET' and/or 'MOON'). Default '{PLANET}' preserves the
behaviour of every pre-existing building. Enforced by the building_queue insert guard.$c$;

update public.building_definitions set valid_kinds = '{PLANET}' where valid_kinds is null;

insert into public.building_definitions(id, name, description, base_metal, base_crystal, base_deuterium,
    cost_factor, base_build_time_seconds, time_factor, max_level, valid_kinds)
values
    ('lunar_base', 'Lunar Base', 'Expands the infrastructure of a moon: +3 fields per level.',
     20000, 40000, 20000, 2, 60, 2, null, '{MOON}'),
    ('sensor_phalanx', 'Sensor Phalanx', 'Scans fleets in flight over nearby systems of the same galaxy.',
     20000, 40000, 10000, 2, 60, 2, null, '{MOON}'),
    ('jump_gate', 'Jump Gate', 'Teleports ships between the owner''s moons.',
     2000000, 4000000, 2000000, 2, 60, 2, null, '{MOON}')
on conflict (id) do update
    set name = excluded.name,
        description = excluded.description,
        base_metal = excluded.base_metal,
        base_crystal = excluded.base_crystal,
        base_deuterium = excluded.base_deuterium,
        cost_factor = excluded.cost_factor,
        base_build_time_seconds = excluded.base_build_time_seconds,
        time_factor = excluded.time_factor,
        valid_kinds = excluded.valid_kinds;

insert into public.building_prerequisites(building_id, prerequisite_building_id, required_level)
values ('sensor_phalanx', 'lunar_base', 1), ('jump_gate', 'lunar_base', 1)
on conflict do nothing;

create table if not exists public.building_research_prerequisites (
    building_id text not null references public.building_definitions(id) on delete cascade,
    research_id text not null references public.research_definitions(id) on delete cascade,
    required_level integer not null check (required_level > 0),
    primary key (building_id, research_id)
);

comment on table public.building_research_prerequisites is
$c$Research required to raise a building (OGameX GameObjectRequirement with a research id). Mirror of the existing
`research_building_prerequisites` (research requiring a building) introduced by the research mechanism on
2026-09-25. Enforced by the building_queue insert guard; `start_building` itself is untouched.$c$;

insert into public.building_research_prerequisites(building_id, research_id, required_level)
values ('jump_gate', 'hyperspace_technology', 7)
on conflict do nothing;

create or replace function public.enforce_building_kind_and_research()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_kind text;
    v_valid text[];
    v_missing text;
begin
    select p.kind, d.valid_kinds into v_kind, v_valid
      from public.planets p
      join public.building_definitions d on d.id = new.building_id
     where p.id = new.planet_id;

    if v_kind is null then
        raise exception 'BUILDING_PLANET_OR_DEFINITION_NOT_FOUND: % / %', new.planet_id, new.building_id;
    end if;

    if not (v_kind = any (v_valid)) then
        raise exception 'BUILDING_NOT_AVAILABLE_FOR_KIND: % is not available on a %', new.building_id, v_kind;
    end if;

    select brp.research_id into v_missing
      from public.building_research_prerequisites brp
     where brp.building_id = new.building_id
       and coalesce(public.get_player_research_level(
                     (select p.player_id from public.planets p where p.id = new.planet_id),
                     brp.research_id), 0) < brp.required_level
     limit 1;

    if v_missing is not null then
        raise exception 'BUILDING_RESEARCH_PREREQUISITES_NOT_MET: %', v_missing;
    end if;

    return new;
end;
$function$;

comment on function public.enforce_building_kind_and_research() is
$c$BEFORE INSERT trigger on building_queue: enforces `building_definitions.valid_kinds` (a moon building can only be
queued on a moon) and `building_research_prerequisites` (e.g. jump_gate needs hyperspace_technology 7). Building to
building requirements stay in `building_prerequisites`, which `start_building` already enforces.$c$;

drop trigger if exists trg_enforce_building_kind_and_research on public.building_queue;
create trigger trg_enforce_building_kind_and_research
    before insert on public.building_queue
    for each row
    execute function public.enforce_building_kind_and_research();

revoke all on function public.enforce_building_kind_and_research() from public, anon, authenticated;

commit;
