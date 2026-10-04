-- PLANET TEMPERATURE SYSTEM — position-derived temperature, deuterium factor, solar satellites (2026-09-30)
-- ================================================================================================
-- SOURCE — verified against CURRENT upstream (paths are the live `app/GameObjects/*` tree, NOT the obsolete
-- `application/Settings/*`), plus the merged upstream PR that fixed the temperature range:
--
--   * lanedirt/OGameX `main` `app/Factories/PlanetServiceFactory.php` → `planetData(int $planetPosition, bool)`
--     gives, PER POSITION 1..15, the field range and the TEMPERATURE BAND (verbatim):
--         1 [220,260]   2 [170,210]   3 [120,160]   4 [70,110]   5 [60,100]
--         6 [50,90]     7 [40,80]     8 [30,70]     9 [20,60]    10 [10,50]
--        11 [0,40]     12 [-10,30]   13 [-50,-10]  14 [-90,-50]  15 [-130,-90]
--     and, for an out-of-range position, the fallback band [0,40]. The 12→13 step is a 40-degree jump
--     upstream; it is reproduced verbatim and NOT smoothed.
--
--   * lanedirt/OGameX PR #514 (MERGED into main, closes issue #513 "Planet temperature max is too high"),
--     commit "Correct temp_min/max assignment in planet creation":
--         "Random temperature between the min and max values is assigned to temp_max, then temp_min is
--          calculated as temp_max - 40."
--     ⇒ THE ENFORCED RANGE IS EXACTLY 40 DEGREES (temp_min = temp_max − 40). This is also corroborated by
--     the real client capture in `template/template.txt` ("-21°C to 19°C" ⇒ max − min = 40).
--
--   * lanedirt/OGameX `app/GameObjects/BuildingObjects.php:86` (deuterium synthesizer, OGAMEX DIRECT):
--         10 * level * 1.1 ** level * (1.44 - 0.004 * getPlanetTempAvg())
--     and `tests/Unit/ResourceProductionTest::testDeuteriumProductionTemperatureDependency` pins it:
--         T_avg 5   ⇒ 10*1*1.1^1*(1.44−0.02) = 15.62 → ceil 16
--         T_avg 110 ⇒ 10*1*1.1^1*(1.44−0.44) = 11.00 → ceil 11     (cold > hot)
--
--   * lanedirt/OGameX `app/GameObjects/CivilShipObjects.php:171` (solar satellite, OGAMEX DIRECT):
--         floor((getPlanetTempMax() + 140) / 6) * amount
--     `getObjectProduction()` additionally floors energy, which is a no-op on this expression.
--
--   * lanedirt/OGameX `PlanetService::getPlanetTempAvg()` = (int) round((temp_min + temp_max) / 2).
--     With the 40-degree range this is exactly `temp_max − 20`, so the two documented classic variants of
--     the satellite formula are the SAME NUMBER: floor((T_avg + 160)/6) ≡ floor((T_max + 140)/6).
--     LGI therefore implements the OGameX spelling and there is no variant conflict to decide.
--
--   * lanedirt/OGameX `PlanetServiceFactory::setupMoonProperties()` (and `app/Jobs/CreateLegorMoon.php`):
--     a moon takes the temperature of the POSITION it orbits, using the MIDPOINT of the position band
--     (`temp_max = (lo+hi)/2; temp_min = temp_max − 40`).
--
-- TEMPERATURE DEPENDENCY CLOSURE — exhaustively re-scanned upstream (`app/**`, 299 PHP files): the ONLY
-- consumers of temperature in the whole upstream codebase are the two object formulas above, the three
-- getters, the position table, and the UI readout in `Http/Controllers/OverviewController`. There is no
-- temperature term in research, fleet, combat, fields, lifeforms, officers or character classes.
--
-- INTENTIONAL LGI DIFFERENCE (1), recorded — MIDPOINT INSTEAD OF A RANDOM DRAW.
--   Upstream draws `temp_max = rand(lo, hi)` per planet, so upstream temperature is NOT a function of the
--   position. A per-row random draw is not auditable, not reproducible and cannot support the mission's
--   "one authoritative source / verifiable backfill" requirement, so LGI uses the DETERMINISTIC MIDPOINT of
--   the same upstream band — which is exactly what upstream itself does for moons. Same band, same
--   40-degree range, same formulas; only the draw is fixed. Stated here so it is never mistaken for an
--   upstream claim. Reverting to a random draw is a product decision, not a technical one.
--
-- INTENTIONAL LGI DIFFERENCE (2), recorded — NON-NEGATIVE FLOOR on the two temperature-derived terms.
--   Upstream has no such guard because upstream always has an in-range temperature. LGI floors the
--   satellite energy and the deuterium temperature factor at 0 so a hand-edited or out-of-range
--   temperature can never produce negative energy or a negative factor.
--
-- DELIBERATE ECONOMY CHANGE (this is the point of the mission, not a side effect): deuterium output now
--   scales with the planet temperature, exactly as upstream does. Factor range with this table:
--   position 1 ⇒ 1.44 − 0.004·220 = 0.56 ·  position 15 ⇒ 1.44 + 0.004·130 = 1.96.
--   Metal, crystal, the energy balance of solar plant/fusion and the crawler terms are untouched.
--
-- ONE SOURCE OF TRUTH (no duplicated formula anywhere):
--     planets.position → planet_temperature_for_position(position)   [the band, the ONLY place it exists]
--                      → planets.temperature_min / temperature_max  [the persisted instance]
--                      → planet_temperature(planet)                  [persisted, else the model — never NULL]
--                      → calculate_planet_production                 [the only consumer]
--   Planet creation, colonization, AI worlds and moons all write the SAME helper. There is no second
--   formula in the frontend, in a fixture, or in a trigger.
--
-- SECURITY: the two helpers are read-only, SECURITY INVOKER, fixed `search_path`, EXECUTE for
--   `service_role` only (same posture as `calculate_planet_production`, which is service_role-only).
--   No new write surface, no client-supplied temperature, no `player_id` taken from the client.

begin;

-- ------------------------------------------------------------------ 1. the band (single source of truth)
create or replace function public.planet_temperature_for_position(p_position integer)
returns table (temperature_min integer, temperature_max integer, temperature_average integer)
language plpgsql
immutable
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_lo integer;
    v_hi integer;
begin
    -- OGameX `PlanetServiceFactory::planetData()` temperature bands, verbatim.
    v_lo := case p_position
        when 1 then 220 when 2 then 170 when 3 then 120 when 4 then  70 when 5 then  60
        when 6 then  50 when 7 then  40 when 8 then  30 when 9 then  20 when 10 then 10
        when 11 then  0 when 12 then -10 when 13 then -50 when 14 then -90 when 15 then -130
    end;
    -- out-of-range position: upstream fallback band [0,40]
    v_hi := case p_position
        when 1 then 260 when 2 then 210 when 3 then 160 when 4 then 110 when 5 then 100
        when 6 then  90 when 7 then  80 when 8 then  70 when 9 then  60 when 10 then 50
        when 11 then 40 when 12 then  30 when 13 then -10 when 14 then -50 when 15 then  -90
    end;
    if v_lo is null or v_hi is null then
        v_lo := 0;
        v_hi := 40;
    end if;

    -- deterministic midpoint of the band (see INTENTIONAL LGI DIFFERENCE (1)); upstream moon rule.
    temperature_max     := (v_lo + v_hi) / 2;
    -- upstream PR #514: the range is exactly 40 degrees.
    temperature_min     := temperature_max - 40;
    -- upstream getPlanetTempAvg(): round((min + max) / 2) — exact here because min = max - 40.
    temperature_average := (temperature_min + temperature_max) / 2;
    return next;
end;
$function$;

-- ------------------------------------------------------------------ 2. the planet's own temperature
-- Persisted columns win (they are the instance of the model). A NULL column falls back to the position
-- model instead of to a magic 0, so no mechanic can ever silently read a NULL temperature again.
create or replace function public.planet_temperature(p_planet_id uuid)
returns table (temperature_min integer, temperature_max integer, temperature_average integer)
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
    with src as (
        select p.temperature_min as stored_min, p.temperature_max as stored_max, p.position
        from public.planets p
        where p.id = p_planet_id
    )
    select
        case when s.stored_min is not null and s.stored_max is not null
             then s.stored_min else m.temperature_min end,
        case when s.stored_min is not null and s.stored_max is not null
             then s.stored_max else m.temperature_max end,
        case when s.stored_min is not null and s.stored_max is not null
             then (s.stored_min + s.stored_max) / 2 else m.temperature_average end
    from src s
    cross join lateral public.planet_temperature_for_position(coalesce(s.position, 0)) m;
$function$;

revoke all on function public.planet_temperature_for_position(integer) from public, anon, authenticated;
revoke all on function public.planet_temperature(uuid) from public, anon, authenticated;
grant execute on function public.planet_temperature_for_position(integer) to service_role;
grant execute on function public.planet_temperature(uuid) to service_role;

-- ------------------------------------------------------------------ 3. the single consumer
-- calculate_planet_production stays the ONLY production authority (unchanged signature, unchanged
-- volatility, unchanged SECURITY INVOKER + search_path). Two additions, both upstream formulas:
--   * deuterium base term is multiplied by the temperature factor 1.44 - 0.004 * T_avg
--     (upstream puts the factor INSIDE `deuterium_formula`, and `calculateCrawlerProduction()` runs after
--      `calculateMine()`, so the crawler term is deliberately NOT multiplied by it — reproduced here);
--   * solar satellites contribute floor((T_max + 140) / 6) each to the planetary energy production,
--     summed exactly like the solar plant and the fusion plant.
-- The three mine base terms are lifted into local variables: that REMOVES the existing duplication
-- (each base was computed twice in the same expression) and gives the temperature factor one single place.
create or replace function public.calculate_planet_production(p_planet_id uuid)
returns table(metal_per_hour numeric, crystal_per_hour numeric, deuterium_per_hour numeric, energy_per_hour numeric)
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
DECLARE
  v_universe_id uuid;
  v_player_id uuid;
  v_metal_level integer := 0;
  v_crystal_level integer := 0;
  v_deuterium_level integer := 0;
  v_solar_level integer := 0;
  v_fusion_level integer := 0;
  v_crawler_count bigint := 0;
  v_crawler_effective bigint := 0;
  v_satellite_count bigint := 0;
  v_deuterium_stock numeric := 0;
  v_fusion_energy numeric := 0;
  v_fusion_deuterium numeric := 0;
  v_satellite_energy numeric := 0;
  v_energy_technology_level integer := 0;
  v_plasma_technology_level integer := 0;
  v_economy_rate numeric;
  v_production_rate numeric;
  v_item_bonus numeric := 0;
  v_prod_bonus numeric := 0;
  v_metal_bonus numeric := 0;
  v_crystal_bonus numeric := 0;
  v_deut_bonus numeric := 0;
  v_energy_bonus numeric := 0;
  v_energy_production numeric := 0;
  v_energy_consumption numeric := 0;
  v_production_factor numeric := 1;
  v_plasma_metal_factor numeric := 1;
  v_plasma_crystal_factor numeric := 1;
  v_plasma_deuterium_factor numeric := 1;
  v_metal_base numeric := 0;
  v_crystal_base numeric := 0;
  v_deuterium_base numeric := 0;
  v_temperature_min integer := 0;
  v_temperature_max integer := 0;
  v_temperature_average integer := 0;
  v_deuterium_temperature_factor numeric := 1;
BEGIN
  SELECT p.universe_id, p.player_id INTO v_universe_id, v_player_id
  FROM public.planets p WHERE p.id = p_planet_id;
  IF v_universe_id IS NULL THEN RAISE EXCEPTION 'Planet % does not exist', p_planet_id; END IF;

  SELECT r.economy, r.production INTO v_economy_rate, v_production_rate
  FROM public.calculate_universe_rates(v_universe_id) r;

  SELECT
    COALESCE(MAX(level) FILTER (WHERE building_id = 'metal_mine'), 0),
    COALESCE(MAX(level) FILTER (WHERE building_id = 'crystal_mine'), 0),
    COALESCE(MAX(level) FILTER (WHERE building_id = 'deuterium_synthesizer'), 0),
    COALESCE(MAX(level) FILTER (WHERE building_id = 'solar_plant'), 0),
    COALESCE(MAX(level) FILTER (WHERE building_id = 'fusion_plant'), 0),
    COALESCE(SUM(public.calculate_building_energy_consumption(building_id, level)), 0)
  INTO v_metal_level, v_crystal_level, v_deuterium_level, v_solar_level, v_fusion_level, v_energy_consumption
  FROM public.planet_buildings
  WHERE planet_id = p_planet_id;

  v_item_bonus := COALESCE(public.get_active_expedition_item_effect(v_player_id, p_planet_id, 'production_percent'), 0);
  v_prod_bonus := COALESCE(public.get_active_lifeform_research_effect(v_player_id, 'production_percent'), 0);
  v_metal_bonus := COALESCE(public.get_active_lifeform_research_effect(v_player_id, 'metal_production_percent'), 0) + COALESCE(public.get_planet_lifeform_building_effect(p_planet_id, 'metal_production_percent'), 0);
  v_crystal_bonus := COALESCE(public.get_active_lifeform_research_effect(v_player_id, 'crystal_production_percent'), 0) + COALESCE(public.get_planet_lifeform_building_effect(p_planet_id, 'crystal_production_percent'), 0);
  v_deut_bonus := COALESCE(public.get_active_lifeform_research_effect(v_player_id, 'deuterium_production_percent'), 0) + COALESCE(public.get_planet_lifeform_building_effect(p_planet_id, 'deuterium_production_percent'), 0);
  v_energy_bonus := COALESCE(public.get_active_lifeform_research_effect(v_player_id, 'energy_percent'), 0) + COALESCE(public.get_planet_lifeform_building_effect(p_planet_id, 'energy_percent'), 0);
  v_energy_technology_level := COALESCE(public.get_player_research_level(v_player_id, 'energy_technology'), 0);
  v_plasma_technology_level := COALESCE(public.get_player_research_level(v_player_id, 'plasma_technology'), 0);

  v_plasma_metal_factor := 1 + 0.01 * v_plasma_technology_level;
  v_plasma_crystal_factor := 1 + 0.0066 * v_plasma_technology_level;
  v_plasma_deuterium_factor := 1 + 0.0033 * v_plasma_technology_level;

  -- OGameX building formulas, verbatim: 30 / 20 / 10 * level * 1.1 ^ level
  v_metal_base := 30 * v_metal_level * power(1.1, v_metal_level);
  v_crystal_base := 20 * v_crystal_level * power(1.1, v_crystal_level);
  v_deuterium_base := 10 * v_deuterium_level * power(1.1, v_deuterium_level);

  select coalesce(pr.deuterium, 0) into v_deuterium_stock
    from public.planet_resources pr where pr.planet_id = p_planet_id;
  select coalesce(sum(ps.quantity), 0) into v_crawler_count
    from public.planet_ships ps where ps.planet_id = p_planet_id and ps.ship_id = 'crawler';
  v_crawler_effective := least(v_crawler_count, (v_metal_level + v_crystal_level + v_deuterium_level)::bigint * 8);
  v_energy_consumption := v_energy_consumption + (v_crawler_effective * 50);

  -- ---- temperature (OGameX): the planet's own temperature — never NULL, never a magic 0
  select t.temperature_min, t.temperature_max, t.temperature_average
    into v_temperature_min, v_temperature_max, v_temperature_average
    from public.planet_temperature(p_planet_id) t;
  -- OGameX BuildingObjects.php:86  ->  10 * L * 1.1^L * (1.44 - 0.004 * T_avg)
  v_deuterium_temperature_factor := greatest(0, 1.44 - 0.004 * v_temperature_average);
  -- OGameX CivilShipObjects.php:171  ->  floor((T_max + 140) / 6) per satellite
  select coalesce(sum(ps.quantity), 0) into v_satellite_count
    from public.planet_ships ps where ps.planet_id = p_planet_id and ps.ship_id = 'solar_satellite';
  v_satellite_energy := greatest(0, floor((v_temperature_max + 140) / 6.0)) * v_satellite_count;

  v_energy_production := floor(
    20 * v_solar_level * power(1.1, v_solar_level)
    * (1 + v_energy_bonus / 100)
    * (1 + 0.05 * v_energy_technology_level)
  );
  v_fusion_energy := case when v_fusion_level > 0 and v_deuterium_stock > 0
    then floor(30 * v_fusion_level * power(1.05 + 0.01 * v_energy_technology_level, v_fusion_level)
               * (1 + v_energy_bonus / 100))
    else 0 end;
  v_energy_production := v_energy_production + v_fusion_energy + v_satellite_energy;
  v_fusion_deuterium := case when v_fusion_level > 0 and v_deuterium_stock > 0
    then 10 * v_fusion_level * power(1.1, v_fusion_level) * v_economy_rate * v_production_rate
    else 0 end;

  IF v_energy_consumption > 0 THEN
    v_production_factor := GREATEST(0, LEAST(1, v_energy_production / v_energy_consumption));
  END IF;

  RETURN QUERY SELECT
    (v_metal_base
     + floor(v_metal_base * 0.0002 * v_crawler_effective)) * v_economy_rate * v_production_rate * (1 + (v_item_bonus + v_prod_bonus + v_metal_bonus) / 100) * v_production_factor * v_plasma_metal_factor,
    (v_crystal_base
     + floor(v_crystal_base * 0.0002 * v_crawler_effective)) * v_economy_rate * v_production_rate * (1 + (v_item_bonus + v_prod_bonus + v_crystal_bonus) / 100) * v_production_factor * v_plasma_crystal_factor,
    (v_deuterium_base * v_deuterium_temperature_factor
     + floor(v_deuterium_base * 0.0002 * v_crawler_effective)) * v_economy_rate * v_production_rate * (1 + (v_item_bonus + v_prod_bonus + v_deut_bonus) / 100) * v_production_factor * v_plasma_deuterium_factor - v_fusion_deuterium,
    v_energy_production;
END;
$function$;

-- ------------------------------------------------------------------ 4. every planet-writing path
-- Patched with the repository's established no-regression pattern (`pg_get_functiondef` + an exact
-- `replace()` on a unique anchor, aborting the whole migration when the anchor is gone). Re-typing these
-- four long bodies would risk silent transcription drift; a missing anchor fails loudly instead.
-- No function is re-implemented: only the temperature pair of the INSERT changes, and every one of them
-- now asks the SAME authority. Colonization stops writing the hardcoded legacy stub (-20, 20) and the AI
-- reconciler stops writing (NULL, NULL). `resolve_colonize_arrival` and `reconcile_universe_ai_population`
-- call the immutable helper twice; both are one-shot writers and there is still only ONE formula.

do $$
declare
    v_def text;
    v_new text;
begin
    -- 4.1 homeworld (provision_player)
    select pg_get_functiondef(p.oid) into v_def from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'provision_player';
    if v_def is null then
        raise exception 'TEMPERATURE_PATCH: provision_player not found';
    end if;
    v_new := replace(v_def,
        '    universe_id, player_id, name, galaxy, system, position,',
        '    universe_id, player_id, name, galaxy, system, position,' || chr(10) ||
        '    temperature_min, temperature_max,');
    if v_new = v_def then
        raise exception 'TEMPERATURE_PATCH: provision_player column anchor not found';
    end if;
    v_def := v_new;
    v_new := replace(v_def,
        '    163, 0, true, false',
        '    (select t.temperature_min from public.planet_temperature_for_position(v_planet_position) t),' || chr(10) ||
        '    (select t.temperature_max from public.planet_temperature_for_position(v_planet_position) t),' || chr(10) ||
        '    163, 0, true, false');
    if v_new = v_def then
        raise exception 'TEMPERATURE_PATCH: provision_player value anchor not found';
    end if;
    execute v_new;
end;
$$;

do $$
declare
    v_def text;
    v_new text;
begin
    -- 4.2 colonization (resolve_colonize_arrival) — replaces the hardcoded legacy stub (-20, 20)
    select pg_get_functiondef(p.oid) into v_def from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'resolve_colonize_arrival';
    if v_def is null then
        raise exception 'TEMPERATURE_PATCH: resolve_colonize_arrival not found';
    end if;
    v_new := replace(v_def,
        E'        v_fleet.destination_galaxy,v_fleet.destination_system,v_fleet.destination_position,\n        -20,20,v_fields,0,false,false',
        E'        v_fleet.destination_galaxy,v_fleet.destination_system,v_fleet.destination_position,\n        (select t.temperature_min from public.planet_temperature_for_position(v_fleet.destination_position) t),\n        (select t.temperature_max from public.planet_temperature_for_position(v_fleet.destination_position) t),\n        v_fields,0,false,false');
    if v_new = v_def then
        raise exception 'TEMPERATURE_PATCH: resolve_colonize_arrival anchor not found';
    end if;
    execute v_new;
end;
$$;

do $$
declare
    v_def text;
    v_new text;
begin
    -- 4.3 AI worlds (reconcile_universe_ai_population) — stops writing (NULL, NULL)
    select pg_get_functiondef(p.oid) into v_def from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'reconcile_universe_ai_population';
    if v_def is null then
        raise exception 'TEMPERATURE_PATCH: reconcile_universe_ai_population not found';
    end if;
    v_new := replace(v_def,
        E'                    NULL,\n                    NULL,\n                    163,',
        E'                    (select t.temperature_min from public.planet_temperature_for_position(v_candidate.position) t),\n                    (select t.temperature_max from public.planet_temperature_for_position(v_candidate.position) t),\n                    163,');
    if v_new = v_def then
        raise exception 'TEMPERATURE_PATCH: reconcile_universe_ai_population anchor not found';
    end if;
    execute v_new;
end;
$$;

do $$
declare
    v_def text;
    v_new text;
begin
    -- 4.4 moons (settle_moon_creation_for_battle)
    -- OGameX: a moon takes the temperature of the POSITION it orbits (midpoint of the position band).
    -- LGI previously rebuilt it from the parent row with its own inline `(min+max)/2` and `-40`; that
    -- duplication is removed and the moon now reads the same authority as every other body.
    select pg_get_functiondef(p.oid) into v_def from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'settle_moon_creation_for_battle';
    if v_def is null then
        raise exception 'TEMPERATURE_PATCH: settle_moon_creation_for_battle not found';
    end if;

    v_new := replace(v_def,
        '    v_avg_temp integer;',
        '    v_moon_temp_min integer;' || chr(10) || '    v_moon_temp_max integer;');
    if v_new = v_def then
        raise exception 'TEMPERATURE_PATCH: settle_moon_creation_for_battle declare anchor not found';
    end if;

    v_def := v_new;
    v_new := replace(v_def,
        '    v_avg_temp := floor((coalesce(v_planet.temperature_min, 0) + coalesce(v_planet.temperature_max, 0)) / 2.0);',
        '    select t.temperature_min, t.temperature_max into v_moon_temp_min, v_moon_temp_max' || chr(10) ||
        '      from public.planet_temperature_for_position(v_planet.position) t;');
    if v_new = v_def then
        raise exception 'TEMPERATURE_PATCH: settle_moon_creation_for_battle assign anchor not found';
    end if;

    v_def := v_new;
    v_new := replace(v_def,
        '        v_avg_temp - 40, v_avg_temp, 1, 0, false, false,',
        '        v_moon_temp_min, v_moon_temp_max, 1, 0, false, false,');
    if v_new = v_def then
        raise exception 'TEMPERATURE_PATCH: settle_moon_creation_for_battle insert anchor not found';
    end if;
    execute v_new;
end;
$$;

-- ------------------------------------------------------------------ 5. BACKFILL (idempotent, additive)
-- Only rows that actually MISS a temperature are touched. It derives every value from `position` through
-- the one authority, so it is reproducible and re-runnable (a second run matches 0 rows). It never writes
-- buildings, resources, queues, fleets, players or any other column, and it never overwrites a temperature
-- that already exists.
update public.planets p
   set temperature_min = m.temperature_min,
       temperature_max = m.temperature_max
  from (select src.id, model.temperature_min, model.temperature_max
          from public.planets src
          cross join lateral public.planet_temperature_for_position(src.position) model) m
 where m.id = p.id
   and (p.temperature_min is null or p.temperature_max is null)
   and (p.temperature_min is distinct from m.temperature_min
     or p.temperature_max is distinct from m.temperature_max);

-- ------------------------------------------------------------------ 6. post-conditions (fail loudly)
do $$
declare
    v_bad integer;
begin
    select count(*) into v_bad from public.planets
     where temperature_min is null or temperature_max is null;
    if v_bad > 0 then
        raise exception 'TEMPERATURE_SYSTEM: % planets still without a temperature', v_bad;
    end if;
    select count(*) into v_bad
      from public.planets p
      join public.planet_temperature_for_position(p.position) m on true
     where p.temperature_min <> m.temperature_min
        or p.temperature_max <> m.temperature_max
        or p.temperature_max - p.temperature_min <> 40;
    if v_bad > 0 then
        raise exception 'TEMPERATURE_SYSTEM: % planets disagree with the position model or the 40-degree range', v_bad;
    end if;
end;
$$;

commit;



