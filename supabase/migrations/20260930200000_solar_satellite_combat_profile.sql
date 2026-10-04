-- SOLAR SATELLITE — combat profile correction (2026-09-30)
-- ============================================================================================
-- Audited end to end (docs/audits/SOLAR_SATELLITE_AUDIT_2026-09-30.md). The satellite life cycle is
-- already complete: it builds through `start_ship`, costs 0/2000/500, needs shipyard 1, debits on
-- start, completes through `process_shipyard_queue_until`, and `calculate_planet_production` adds
-- floor((T_max + 140)/6) per unit. `supabase/tests/solar_satellite.sql` certifies 24 assertions LIVE.
--
-- ONE definition value is wrong against BOTH sources.
--
-- SOURCE (lanedirt/OGameX `main`, app/GameObjects/CivilShipObjects.php):
--     new GameObjectProperties($solarSatellite, 2000, 1, 0, 0, 0, 1)
--     signature: (parent, structural_integrity, shield, attack, speed, capacity, fuel)
--     => shield 1 · ATTACK 0 · speed 0 · capacity 0 · fuel 1
-- Classic OGame documents the same solar satellite: structural 2000, shield 1, ATTACK 0, speed 0.
--
-- WHAT LGI HAD
--     attack = 1, shield = 1, speed = 0, cargo_capacity = 0, fuel_consumption = 0, hull = 200
-- That combat/fuel profile is byte-identical to LGI's CRAWLER row, which is the signature of a
-- copy-paste in the original catalog seed rather than a decision: the two objects differ only in hull.
--
-- WHY IT MATTERS (measured, not assumed)
--     `get_combat_unit_snapshot()` and `initialize_combat_unit_state()` select `sd.attack` for EVERY row
--     of `planet_ships` with quantity > 0, with no ship_type filter. A planet holding N satellites
--     therefore contributes N attack to its defence line today. Upstream contributes 0: a satellite is a
--     damage sponge (shield 1, hull 200 = SI 2000/10 under the project's hull convention), never a
--     weapon. 200 satellites on a planet is a real number in this game.
--
-- SCOPE
--     One data value, one object. No combat engine change, no formula change, no queue change, no UI
--     change, no new RPC. `hull`, `shield`, `speed` and `cargo_capacity` already match the upstream
--     profile and are NOT touched.
--
-- GUARD
--     The UPDATE is a no-op unless the row still carries the exact audited value, so re-running this
--     migration can never overwrite a later deliberate change.

begin;

do $$
declare
    v_rows integer;
    v_attack integer;
begin
    select attack into v_attack from public.ship_definitions where id = 'solar_satellite';
    if v_attack is null then
        raise exception 'SOLAR_SATELLITE_ATTACK: solar_satellite is not in the catalog';
    end if;
    if v_attack = 1 then
        update public.ship_definitions set attack = 0 where id = 'solar_satellite';
    end if;
    select count(*) into v_rows from public.ship_definitions
     where id = 'solar_satellite' and attack = 0;
    if v_rows <> 1 then
        raise exception 'SOLAR_SATELLITE_ATTACK: expected attack 0 after the correction, found %', v_attack;
    end if;
    -- the rest of the upstream profile must be exactly what we audited
    if not exists (
        select 1 from public.ship_definitions
         where id = 'solar_satellite' and shield = 1 and hull = 200
           and speed = 0 and cargo_capacity = 0
           and base_metal = 0 and base_crystal = 2000 and base_deuterium = 500
           and valid_kinds = '{PLANET,MOON}') then
        raise exception 'SOLAR_SATELLITE_ATTACK: the rest of the definition drifted from the audited profile';
    end if;
end;
$$;

-- DOCUMENTED, NOT CHANGED — `fuel_consumption` stays 0 while upstream stores 1.
-- A satellite has speed 0, so `calculate_fleet_travel_time` raises 'Ship speed must be greater than zero'
-- before any fuel is ever computed, and this fixture proves the refusal. The upstream value has no
-- reachable behaviour, and the classic value could not be established from a primary source here, so
-- changing it would be an invention. Recorded as a divergence, not silently "fixed".

commit;
