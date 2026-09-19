BEGIN;

WITH live AS (
    SELECT id
    FROM public.universes
    WHERE name = 'Universe 1'
      AND description = 'Live universe: 100 initial galaxies, dynamic system expansion and special galaxies.'
    ORDER BY created_at DESC
    LIMIT 1
)
INSERT INTO public.universe_galaxies (
    universe_id,
    galaxy,
    system_count,
    next_system_expansion_at,
    system_interval_seconds,
    system_interval_growth_factor,
    is_special
)
SELECT
    live.id,
    g.galaxy,
    1,
    now() + make_interval(secs => (28800::numeric * power(1.05::numeric, g.galaxy - 1)))::interval,
    28800::numeric * power(1.05::numeric, g.galaxy - 1),
    1,
    false
FROM live
CROSS JOIN generate_series(1, 100) AS g(galaxy)
ON CONFLICT (universe_id, galaxy) DO NOTHING;

WITH live AS (
    SELECT id
    FROM public.universes
    WHERE name = 'Universe 1'
      AND description = 'Live universe: 100 initial galaxies, dynamic system expansion and special galaxies.'
    ORDER BY created_at DESC
    LIMIT 1
)
INSERT INTO public.universe_expansion_state (
    universe_id,
    next_galaxy_roll_at,
    galaxy_roll_interval_seconds,
    galaxy_roll_probability,
    initial_special_galaxy_systems,
    special_galaxy_base_interval_seconds,
    special_galaxy_interval_growth_factor
)
SELECT live.id, now() + interval '12 hours', 43200, 0.01, 10, 3600, 1.05
FROM live
ON CONFLICT (universe_id) DO NOTHING;

WITH live AS (
    SELECT id
    FROM public.universes
    WHERE name = 'Universe 1'
      AND description = 'Live universe: 100 initial galaxies, dynamic system expansion and special galaxies.'
    ORDER BY created_at DESC
    LIMIT 1
), new_player AS (
    INSERT INTO public.players (
        universe_id,
        username,
        points,
        is_guest
    )
    SELECT live.id, 'DevPlayer', 0, true
    FROM live
    RETURNING id, universe_id
)
INSERT INTO public.planets (
    universe_id,
    player_id,
    name,
    galaxy,
    system,
    position,
    fields_total,
    fields_used,
    is_homeworld,
    is_destroyed
)
SELECT
    new_player.universe_id,
    new_player.id,
    'Homeworld',
    1,
    1,
    1,
    163,
    0,
    true,
    false
FROM new_player;

-- The resource row is initialized at zero deliberately; the user requested
-- that the live homeworld be created without resources for now.
INSERT INTO public.planet_resources (planet_id, metal, crystal, deuterium, energy)
SELECT p.id, 0, 0, 0, 0
FROM public.planets p
JOIN public.universes u ON u.id = p.universe_id
WHERE u.name = 'Universe 1'
  AND u.description = 'Live universe: 100 initial galaxies, dynamic system expansion and special galaxies.'
  AND p.galaxy = 1 AND p.system = 1 AND p.position = 1
ON CONFLICT (planet_id) DO NOTHING;

-- Give the live universe its own clock. It is not wired to the cron worker yet;
-- that is the next implementation step after the expansion function exists.
WITH live AS (
    SELECT id
    FROM public.universes
    WHERE name = 'Universe 1'
      AND description = 'Live universe: 100 initial galaxies, dynamic system expansion and special galaxies.'
    ORDER BY created_at DESC
    LIMIT 1
)
INSERT INTO public.universe_clock (
    universe_id,
    last_tick_at,
    next_tick_at,
    tick_interval_seconds,
    is_processing
)
SELECT live.id, now(), now(), 1, false
FROM live
ON CONFLICT (universe_id) DO NOTHING;

COMMIT;