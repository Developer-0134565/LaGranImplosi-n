create or replace function public.get_universe_evolution_monitor_public(p_universe_id uuid)
returns table(
  universe_id uuid,
  universe_name text,
  is_active boolean,
  status text,
  clock_last_tick_at timestamptz,
  clock_next_tick_at timestamptz,
  clock_interval_seconds integer,
  clock_is_processing boolean,
  clock_lag_seconds bigint,
  clock_ticks_due bigint,
  galaxy_count bigint,
  normal_galaxy_count bigint,
  special_galaxy_count bigint,
  system_count bigint,
  unlocked_positions bigint,
  expansion_pending_galaxies bigint,
  expansion_oldest_lag_seconds bigint,
  next_galaxy_roll_at timestamptz,
  galaxy_rolls_due bigint,
  ai_planets_count bigint,
  ai_density numeric,
  ai_density_target numeric,
  ai_density_tolerance numeric,
  ai_density_lower_bound numeric,
  ai_density_upper_bound numeric,
  ai_deficit bigint,
  ai_generation_batch integer,
  ai_estimated_batches bigint,
  next_ai_reconciliation_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $function$
  select
    m.universe_id,
    m.universe_name,
    m.is_active,
    m.status,
    m.clock_last_tick_at,
    m.clock_next_tick_at,
    m.clock_interval_seconds,
    m.clock_is_processing,
    m.clock_lag_seconds,
    m.clock_ticks_due,
    m.galaxy_count,
    m.normal_galaxy_count,
    m.special_galaxy_count,
    m.system_count,
    m.unlocked_positions,
    m.expansion_pending_galaxies,
    m.expansion_oldest_lag_seconds,
    m.next_galaxy_roll_at,
    m.galaxy_rolls_due,
    m.ai_planets_count,
    m.ai_density,
    m.ai_density_target,
    m.ai_density_tolerance,
    m.ai_density_lower_bound,
    m.ai_density_upper_bound,
    m.ai_deficit,
    m.ai_generation_batch,
    m.ai_estimated_batches,
    m.next_ai_reconciliation_at
  from public.get_universe_evolution_monitor(p_universe_id) as m
  where m.is_active = true;
$function$;

revoke execute on function public.get_universe_evolution_monitor_public(uuid) from public;
revoke execute on function public.get_universe_evolution_monitor_public(uuid) from anon;
revoke execute on function public.get_universe_evolution_monitor_public(uuid) from authenticated;
grant execute on function public.get_universe_evolution_monitor_public(uuid) to anon, authenticated;

comment on function public.get_universe_evolution_monitor_public(uuid)
is 'Sanitized read-only universe evolution monitor for guest/frontend clients. Excludes internal process health and error details.';