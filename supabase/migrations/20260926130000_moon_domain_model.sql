-- MOON DOMAIN MODEL (2026-09-26) — accepted product+technical decision
-- --------------------------------------------------------------------------------------------
-- A moon is a REAL domain entity, not a planet with a flag: same coordinates as its planet, own identity
-- (`kind`), own parent link, own buildings/resources and its own destruction rules.
--
-- Accepted model (user decision, 2026-09-26):
--   * `planets.kind` = 'PLANET' | 'MOON' (existing rows default to PLANET);
--   * `planets.parent_planet_id` links a moon to its planet (one moon per planet);
--   * the global UNIQUE (universe_id, galaxy, system, position) is REPLACED by partial unique indexes so a moon
--     can share its planet's coordinates, and one moon per coordinate is still enforced;
--   * every coordinate lookup that means "a planet" must filter `kind = 'PLANET'`
--     (`20260926130800_coordinate_lookup_kind_filter`);
--   * ownership rules unchanged: a moon belongs to its planet's owner.
--
-- OGameX evidence (@ 7c420bad): `PlanetType::Moon`, `PlanetServiceFactory::createMoonForPlanet`,
-- `PlanetService::getPlanetFieldMax` (lunar base = +3 fields/level), `StationObjects` ids 41/42/43.
-- Certified by `supabase/tests/moon_engine.sql`.

begin;

alter table public.planets add column if not exists kind text not null default 'PLANET';
alter table public.planets add column if not exists parent_planet_id uuid;
alter table public.planets add column if not exists moon_diameter_km integer;
alter table public.planets add column if not exists jump_gate_cooldown_until timestamp with time zone;

comment on column public.planets.kind is
$c$'PLANET' or 'MOON'. A moon shares its parent planet's coordinates, universe and owner and has its own resources,
buildings and destruction rules. Existing rows default to PLANET.$c$;
comment on column public.planets.parent_planet_id is
$c$For a moon, the planet it orbits (kind = 'PLANET', same universe/galaxy/system/position and owner). NULL for a
planet. One moon per planet (partial unique index).$c$;
comment on column public.planets.moon_diameter_km is
$c$Moon diameter in km (OGameX: floor(sqrt(x + 3 × debris / 100 000) × 1000), x ∈ [10,20], capped at 8 944 km). NULL
for planets.$c$;
comment on column public.planets.jump_gate_cooldown_until is
$c$Absolute UTC timestamp until which a moon's jump gate refuses to teleport ships again (OGameX
JumpGateService::calculateCooldown). NULL or past = ready.$c$;

alter table public.planets drop constraint if exists planets_kind_check;
alter table public.planets add constraint planets_kind_check check (kind in ('PLANET', 'MOON'));

alter table public.planets drop constraint if exists planets_moon_shape_check;
alter table public.planets add constraint planets_moon_shape_check check (
    (kind = 'PLANET' and parent_planet_id is null and moon_diameter_km is null)
    or (kind = 'MOON' and parent_planet_id is not null and moon_diameter_km is not null and moon_diameter_km > 0
        and is_homeworld = false)
);

alter table public.planets drop constraint if exists planets_parent_planet_id_fkey;
alter table public.planets add constraint planets_parent_planet_id_fkey
    foreign key (parent_planet_id) references public.planets(id) on delete cascade;

alter table public.planets drop constraint if exists planets_universe_id_galaxy_system_position_key;

create unique index if not exists planets_coordinates_planet_uq
    on public.planets(universe_id, galaxy, system, position) where kind = 'PLANET';
create unique index if not exists planets_coordinates_moon_uq
    on public.planets(universe_id, galaxy, system, position) where kind = 'MOON';
create unique index if not exists planets_moon_parent_uq
    on public.planets(parent_planet_id) where parent_planet_id is not null;
create index if not exists planets_parent_planet_idx
    on public.planets(parent_planet_id) where parent_planet_id is not null;

-- --------------------------------------------------------------------- 3) cross-row consistency
create or replace function public.enforce_planet_kind_consistency()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_parent public.planets%rowtype;
begin
    if new.kind = 'PLANET' then
        new.parent_planet_id := null;
        new.moon_diameter_km := null;
        return new;
    end if;

    select p.* into v_parent from public.planets p where p.id = new.parent_planet_id;

    if not found then
        raise exception 'MOON_PARENT_MISSING: %', new.parent_planet_id;
    end if;
    if v_parent.kind <> 'PLANET' then
        raise exception 'MOON_PARENT_NOT_A_PLANET: %', new.parent_planet_id;
    end if;
    if v_parent.is_destroyed then
        raise exception 'MOON_PARENT_DESTROYED: %', new.parent_planet_id;
    end if;
    if v_parent.universe_id <> new.universe_id or v_parent.galaxy <> new.galaxy
       or v_parent.system <> new.system or v_parent.position <> new.position then
        raise exception 'MOON_MUST_SHARE_PARENT_COORDINATES: %', new.parent_planet_id;
    end if;
    if v_parent.player_id is distinct from new.player_id then
        raise exception 'MOON_OWNER_MUST_MATCH_PARENT: %', new.parent_planet_id;
    end if;

    return new;
end;
$function$;

comment on function public.enforce_planet_kind_consistency() is
$c$BEFORE INSERT OR UPDATE trigger on planets: a moon must point at a live planet sharing its universe, coordinates
and owner; a planet must not carry moon fields. Existing ownership contracts are untouched — a moon simply follows
its planet's owner.$c$;

drop trigger if exists trg_enforce_planet_kind_consistency on public.planets;
create trigger trg_enforce_planet_kind_consistency
    before insert or update on public.planets
    for each row
    execute function public.enforce_planet_kind_consistency();

-- --------------------------------------------------------------------- 4) moon field capacity
create or replace function public.calculate_moon_field_capacity(p_lunar_base_level integer)
returns integer
language sql
immutable
as $function$
    select 1 + 3 * greatest(0, coalesce(p_lunar_base_level, 0));
$function$;

comment on function public.calculate_moon_field_capacity(integer) is
$c$Effective field capacity of a moon = 1 + 3 × lunar_base level (OGameX PlanetService::getPlanetFieldMax adds 3
fields per lunar base level on top of the stored field_max of 1).$c$;

/*
  `start_building` and `can_start_building` compare `fields_used >= fields_total`; for a moon the stored
  `fields_total` is kept equal to the effective capacity, so both keep working untouched.
*/
create or replace function public.sync_moon_field_capacity()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
    if new.building_id <> 'lunar_base' then
        return new;
    end if;

    update public.planets p
       set fields_total = public.calculate_moon_field_capacity(new.level)
     where p.id = new.planet_id
       and p.kind = 'MOON';

    return new;
end;
$function$;

comment on function public.sync_moon_field_capacity() is
$c$AFTER INSERT OR UPDATE trigger on planet_buildings: keeps a moon's stored fields_total equal to
1 + 3 × lunar_base level. Planets are not touched.$c$;

drop trigger if exists trg_sync_moon_field_capacity on public.planet_buildings;
create trigger trg_sync_moon_field_capacity
    after insert or update on public.planet_buildings
    for each row
    execute function public.sync_moon_field_capacity();

revoke all on function public.enforce_planet_kind_consistency() from public, anon, authenticated;
revoke all on function public.sync_moon_field_capacity() from public, anon, authenticated;
revoke all on function public.calculate_moon_field_capacity(integer) from public, anon, authenticated;
grant execute on function public.calculate_moon_field_capacity(integer) to service_role;

commit;

