-- FUSION PLANT + CRAWLER — economy integration (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- OGameX evidence (@ 7c420bad):
--   `BuildingObjects` id 12 fusion_plant: 900/360/180 factor 1.8; requirements deuterium_synthesizer 5 +
--     energy_technology 3; energy `30·L·(1.05 + 0.01·energy_technology)^L`; deuterium `−10·L·1.1^L`.
--     `GameObjectProduction::calculateMine` multiplies the object's deuterium formula by the universe speed exactly
--     like mine output; the energy formula is NOT speed-scaled.
--   `CivilShipObjects` id 217 crawler: 2 000/2 000/1 000; shipyard 4 + combustion_drive 4 + armour_technology 4 +
--     laser_technology 4; PLANET only. Bonus `floor(mine_output × 0.0002 × effective_units)` per resource on the MINE
--     part only; `effective_units = min(owned, (metal_mine + crystal_mine + deuterium_synthesizer) × 8)`; energy
--     50 per effective unit at 100 % overload.
--   `ObjectService::isObjectValidForPlanetType`: an EMPTY `valid_planet_types` means "both kinds" — so LGI storages
--     and the shipyard are legal on a moon (OGameX declares nothing for them), mines/solar/fusion/crawler are
--     planet-only, and lunar_base/sensor_phalanx/jump_gate are moon-only.
--
-- LGI adaptation, documented: `calculate_planet_production` returns rates already scaled by economy × production and
-- `update_planet_resources_until_raw` divides by that combined rate to recover the "base per hour" before applying
-- the evolution-weighted seconds. The reactor's fuel burn is therefore expressed as
-- `10·L·1.1^L × economy × production`, which the settlement turns back into exactly `10·L·1.1^L` base per hour — the
-- same universe-speed scaling OGameX applies. The crawler bonus is applied to the mine base term, keeping LGI's
-- multiplicative chain instead of OGameX's additive production index (ordering documented in README_ECONOMY.md).
--
-- Fuel policy: the reactor runs ONLY while the planet holds deuterium (official OGame: a reactor without fuel stops).
-- OGameX's own code applies the deuterium formula unconditionally, which would let an empty tank keep producing
-- energy; LGI implements the OGame rule so no free energy can exist. Recorded as a deliberate adaptation.
begin;

insert into public.building_definitions(id, name, description, base_metal, base_crystal, base_deuterium, cost_factor,
    base_build_time_seconds, time_factor, max_level, valid_kinds)
values ('fusion_plant', 'Fusion Plant', 'Burns deuterium to produce energy.',
    900, 360, 180, 1.8, 60, 2, null, '{PLANET}')
on conflict (id) do update
    set name = excluded.name, description = excluded.description, base_metal = excluded.base_metal,
        base_crystal = excluded.base_crystal, base_deuterium = excluded.base_deuterium,
        cost_factor = excluded.cost_factor, base_build_time_seconds = excluded.base_build_time_seconds,
        time_factor = excluded.time_factor, valid_kinds = excluded.valid_kinds;

insert into public.building_prerequisites(building_id, prerequisite_building_id, required_level)
values ('fusion_plant', 'deuterium_synthesizer', 5)
on conflict (building_id, prerequisite_building_id) do nothing;

insert into public.building_research_prerequisites(building_id, research_id, required_level)
values ('fusion_plant', 'energy_technology', 3)
on conflict (building_id, research_id) do nothing;

alter table public.ship_definitions
    add column if not exists valid_kinds text[] not null default '{PLANET,MOON}';

comment on column public.ship_definitions.valid_kinds is
$c$Planet kinds on which the ship may be queued ('PLANET', 'MOON' or both). Default '{PLANET,MOON}' preserves the
behaviour of every pre-existing ship (OGameX declares no valid_planet_types for them, which means both kinds).
Enforced by the shipyard_queue insert guard.$c$;

insert into public.ship_definitions(id, name, description, ship_type, base_metal, base_crystal, base_deuterium,
    base_build_time_seconds, attack, shield, hull, cargo_capacity, fuel_consumption, speed, valid_kinds)
values ('crawler', 'Crawler', 'Mining drone: +0.02 % mine production per effective unit (cap: 8 per mine level).',
    'civil', 2000, 2000, 1000, 60, 1, 1, 4000, 0, 0, 0, '{PLANET}')
on conflict (id) do update
    set name = excluded.name, description = excluded.description, base_metal = excluded.base_metal,
        base_crystal = excluded.base_crystal, base_deuterium = excluded.base_deuterium,
        base_build_time_seconds = excluded.base_build_time_seconds, attack = excluded.attack,
        shield = excluded.shield, hull = excluded.hull, cargo_capacity = excluded.cargo_capacity,
        fuel_consumption = excluded.fuel_consumption, speed = excluded.speed, valid_kinds = excluded.valid_kinds;

insert into public.ship_prerequisites(ship_id, prerequisite_type, building_id, research_id, required_level)
select v.ship_id, v.prerequisite_type, v.building_id, v.research_id, v.required_level
from (values
    ('crawler', 'building', 'shipyard', null::text, 4),
    ('crawler', 'research', null::text, 'combustion_drive', 4),
    ('crawler', 'research', null::text, 'armour_technology', 4),
    ('crawler', 'research', null::text, 'laser_technology', 4)
) as v(ship_id, prerequisite_type, building_id, research_id, required_level)
where not exists (
    select 1 from public.ship_prerequisites sp
     where sp.ship_id = v.ship_id and sp.prerequisite_type = v.prerequisite_type
       and sp.building_id is not distinct from v.building_id
       and sp.research_id is not distinct from v.research_id);

update public.building_definitions
   set valid_kinds = '{PLANET,MOON}'
 where id in ('metal_storage', 'crystal_storage', 'deuterium_tank', 'shipyard');

commit;
