BEGIN;

-- The current universe becomes the isolated test universe. Its planets,
-- fleets, combats and all related data remain untouched.
UPDATE public.universes
SET name = 'TEST - Universe 1',
    description = 'Sandbox/test universe. Existing planets, fleets and combat data are retained for testing.'
WHERE id = '86900cbc-467d-4e23-85fa-7ba6302a57eb';

-- Expansion configuration belongs to the live universe and is intentionally
-- separate from the economic evolution-rate calculation.
ALTER TABLE public.universes
    ADD COLUMN IF NOT EXISTS ai_planet_density_target numeric NOT NULL DEFAULT 0.075,
    ADD COLUMN IF NOT EXISTS ai_planet_density_tolerance numeric NOT NULL DEFAULT 0.0025;

ALTER TABLE public.universes
    ADD CONSTRAINT universes_ai_density_target_check
        CHECK (ai_planet_density_target >= 0 AND ai_planet_density_target <= 1),
    ADD CONSTRAINT universes_ai_density_tolerance_check
        CHECK (ai_planet_density_tolerance >= 0 AND ai_planet_density_tolerance < 1);

-- One row per real/unlocked galaxy. Empty systems remain virtual; only the
-- number of unlocked systems and the next expansion timestamp are persisted.
CREATE TABLE IF NOT EXISTS public.universe_galaxies (
    universe_id uuid NOT NULL REFERENCES public.universes(id) ON DELETE CASCADE,
    galaxy integer NOT NULL,
    system_count integer NOT NULL DEFAULT 1,
    next_system_expansion_at timestamptz NOT NULL,
    system_interval_seconds numeric NOT NULL,
    system_interval_growth_factor numeric NOT NULL DEFAULT 1,
    is_special boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (universe_id, galaxy),
    CONSTRAINT universe_galaxies_galaxy_check CHECK (galaxy >= 1),
    CONSTRAINT universe_galaxies_system_count_check CHECK (system_count >= 1),
    CONSTRAINT universe_galaxies_interval_check CHECK (system_interval_seconds > 0),
    CONSTRAINT universe_galaxies_growth_check CHECK (system_interval_growth_factor >= 1)
);

CREATE INDEX IF NOT EXISTS idx_universe_galaxies_next_expansion
    ON public.universe_galaxies (universe_id, next_system_expansion_at);

-- Global 12-hour galaxy-discovery roll. The 1% roll is global, not per galaxy.
CREATE TABLE IF NOT EXISTS public.universe_expansion_state (
    universe_id uuid PRIMARY KEY REFERENCES public.universes(id) ON DELETE CASCADE,
    next_galaxy_roll_at timestamptz NOT NULL,
    galaxy_roll_interval_seconds integer NOT NULL DEFAULT 43200,
    galaxy_roll_probability numeric NOT NULL DEFAULT 0.01,
    initial_special_galaxy_systems integer NOT NULL DEFAULT 10,
    special_galaxy_base_interval_seconds numeric NOT NULL DEFAULT 3600,
    special_galaxy_interval_growth_factor numeric NOT NULL DEFAULT 1.05,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT universe_expansion_state_interval_check CHECK (galaxy_roll_interval_seconds > 0),
    CONSTRAINT universe_expansion_state_probability_check CHECK (galaxy_roll_probability >= 0 AND galaxy_roll_probability <= 1),
    CONSTRAINT universe_expansion_state_initial_systems_check CHECK (initial_special_galaxy_systems >= 1),
    CONSTRAINT universe_expansion_state_base_interval_check CHECK (special_galaxy_base_interval_seconds > 0),
    CONSTRAINT universe_expansion_state_growth_check CHECK (special_galaxy_interval_growth_factor >= 1)
);

-- Create the real/live universe. The previous universe is deliberately left
-- intact as the test environment.
INSERT INTO public.universes (
    name,
    description,
    economy_speed,
    fleet_speed,
    research_speed,
    is_active,
    building_speed,
    lifeform_speed,
    production_speed,
    expedition_speed,
    resource_multiplier,
    storage_multiplier,
    fleet_debris_percentage,
    defense_debris_percentage,
    ai_planet_density_target,
    ai_planet_density_tolerance
)
VALUES (
    'Universe 1',
    'Live universe: 100 initial galaxies, dynamic system expansion and special galaxies.',
    1, 1, 1, true, 1, 1, 1, 1, 1, 1, 30, 0,
    0.075, 0.0025
)
RETURNING id;

COMMIT;