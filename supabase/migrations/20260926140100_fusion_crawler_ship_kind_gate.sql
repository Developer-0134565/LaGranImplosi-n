-- SHIP KIND GATE (single server-side authority) — 2026-09-26
-- --------------------------------------------------------------------------------------------
-- OGameX declares the crawler as planet-only (`CivilShipObjects`: `valid_planet_types = [PlanetType::Planet]`) while
-- every other LGI ship declares none, which OGameX reads as "both kinds" (`ObjectService::isObjectValidForPlanetType`:
-- `if (empty($object->valid_planet_types)) { return true; }`). The authority is this trigger, mirroring the building
-- gate, so the UI is never the decider.
begin;

create or replace function public.enforce_ship_kind()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_kind text;
    v_valid text[];
begin
    select p.kind, d.valid_kinds into v_kind, v_valid
      from public.planets p
      join public.ship_definitions d on d.id = new.ship_id
     where p.id = new.planet_id;

    if v_kind is null then
        raise exception 'SHIP_PLANET_OR_DEFINITION_NOT_FOUND: % / %', new.planet_id, new.ship_id;
    end if;

    if not (v_kind = any (v_valid)) then
        raise exception 'SHIP_NOT_AVAILABLE_FOR_KIND: % is not available on a %', new.ship_id, v_kind;
    end if;

    return new;
end;
$function$;

comment on function public.enforce_ship_kind() is
$c$BEFORE INSERT trigger on shipyard_queue: enforces `ship_definitions.valid_kinds` (the crawler is planet-only). The
same pattern as `trg_enforce_building_kind_and_research`, so the authority is server-side and unique.$c$;

drop trigger if exists trg_enforce_ship_kind on public.shipyard_queue;
create trigger trg_enforce_ship_kind
    before insert on public.shipyard_queue
    for each row
    execute function public.enforce_ship_kind();

revoke all on function public.enforce_ship_kind() from public, anon, authenticated;

commit;
