alter table public.universes
  add column if not exists system_expansion_base_seconds numeric(20,6) not null default 28800,
  add column if not exists system_expansion_curve_exponent numeric(12,8) not null default 0.75,
  add column if not exists special_galaxy_base_seconds numeric(20,6) not null default 3600,
  add column if not exists special_galaxy_growth_factor numeric(12,8) not null default 1.05,
  add column if not exists galaxy_roll_interval_seconds numeric(20,6) not null default 43200,
  add column if not exists galaxy_roll_probability numeric(12,8) not null default 0.01,
  add column if not exists initial_galaxies integer not null default 100,
  add column if not exists initial_systems_per_galaxy integer not null default 1,
  add column if not exists special_galaxy_initial_systems integer not null default 10;

update public.universes
set system_expansion_base_seconds = 28800,
    system_expansion_curve_exponent = 0.75,
    special_galaxy_base_seconds = 3600,
    special_galaxy_growth_factor = 1.05,
    galaxy_roll_interval_seconds = 43200,
    galaxy_roll_probability = 0.01,
    initial_galaxies = 100,
    initial_systems_per_galaxy = 1,
    special_galaxy_initial_systems = 10
where id = 'cf021ece-f931-4b9d-ad97-8d0054f371e3';

update public.universe_expansion_state
set next_galaxy_roll_at = now() + interval '12 hours',
    galaxy_roll_interval_seconds = 43200,
    galaxy_roll_probability = 0.01,
    initial_special_galaxy_systems = 10,
    special_galaxy_base_interval_seconds = 3600,
    special_galaxy_interval_growth_factor = 1.05,
    updated_at = now()
where universe_id = 'cf021ece-f931-4b9d-ad97-8d0054f371e3';

update public.universe_galaxies g
set system_interval_seconds = round((28800 * power(g.galaxy::numeric, 0.75))::numeric, 6),
    system_interval_growth_factor = 1,
    next_system_expansion_at = now() + make_interval(secs => round(28800 * power(g.galaxy::numeric, 0.75))::integer),
    updated_at = now()
where g.universe_id = 'cf021ece-f931-4b9d-ad97-8d0054f371e3'
  and g.galaxy between 1 and 100
  and g.is_special = false;