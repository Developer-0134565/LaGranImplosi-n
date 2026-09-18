import { createClient } from '@supabase/supabase-js'
import type { Database } from './database.types'

export type UniverseEvolutionMonitorPublicRow = {
  universe_id: string | null
  universe_name: string | null
  is_active: boolean | null
  status: string | null
  clock_last_tick_at: string | null
  clock_next_tick_at: string | null
  clock_interval_seconds: number | null
  clock_is_processing: boolean | null
  clock_lag_seconds: number | null
  clock_ticks_due: number | null
  galaxy_count: number | null
  normal_galaxy_count: number | null
  special_galaxy_count: number | null
  system_count: number | null
  unlocked_positions: number | null
  expansion_pending_galaxies: number | null
  expansion_oldest_lag_seconds: number | null
  next_galaxy_roll_at: string | null
  galaxy_rolls_due: number | null
  ai_planets_count: number | null
  ai_density: number | null
  ai_density_target: number | null
  ai_density_tolerance: number | null
  ai_density_lower_bound: number | null
  ai_density_upper_bound: number | null
  ai_deficit: number | null
  ai_generation_batch: number | null
  ai_estimated_batches: number | null
  next_ai_reconciliation_at: string | null
}

type MonitorRpcFunction = {
  get_universe_evolution_monitor_public: {
    Args: { p_universe_id: string }
    Returns: UniverseEvolutionMonitorPublicRow[]
  }
}

type MonitorDatabase = Database & {
  public: Database['public'] & {
    Functions: Database['public']['Functions'] & MonitorRpcFunction
  }
}

const monitorClient = createClient<MonitorDatabase>(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
)

function readUnknownValue(target: unknown, key: string): unknown {
  if (target === null || typeof target !== 'object') {
    return undefined
  }

  return Reflect.get(target, key)
}

function readStringValue(target: unknown, key: string): string | null {
  const value = readUnknownValue(target, key)
  return typeof value === 'string' ? value : null
}

function readNumberValue(target: unknown, key: string): number | null {
  const value = readUnknownValue(target, key)

  if (typeof value === 'number' && Number.isFinite(value)) {
    return value
  }

  if (typeof value === 'string') {
    const parsed = Number(value)
    return Number.isFinite(parsed) ? parsed : null
  }

  return null
}

function readBooleanValue(target: unknown, key: string): boolean | null {
  const value = readUnknownValue(target, key)
  return typeof value === 'boolean' ? value : null
}

export async function fetchUniverseEvolutionMonitorPublic(
  universeId: string | undefined,
): Promise<UniverseEvolutionMonitorPublicRow | null> {
  if (!universeId) {
    return null
  }

  const { data, error } = await monitorClient.rpc('get_universe_evolution_monitor_public', {
    p_universe_id: universeId,
  })

  if (error) {
    throw new Error(error.message)
  }

  const row = Array.isArray(data) ? data[0] ?? null : data ?? null

  if (row === null || typeof row !== 'object') {
    return null
  }

  return {
    universe_id: readStringValue(row, 'universe_id'),
    universe_name: readStringValue(row, 'universe_name'),
    is_active: readBooleanValue(row, 'is_active'),
    status: readStringValue(row, 'status'),
    clock_last_tick_at: readStringValue(row, 'clock_last_tick_at'),
    clock_next_tick_at: readStringValue(row, 'clock_next_tick_at'),
    clock_interval_seconds: readNumberValue(row, 'clock_interval_seconds'),
    clock_is_processing: readBooleanValue(row, 'clock_is_processing'),
    clock_lag_seconds: readNumberValue(row, 'clock_lag_seconds'),
    clock_ticks_due: readNumberValue(row, 'clock_ticks_due'),
    galaxy_count: readNumberValue(row, 'galaxy_count'),
    normal_galaxy_count: readNumberValue(row, 'normal_galaxy_count'),
    special_galaxy_count: readNumberValue(row, 'special_galaxy_count'),
    system_count: readNumberValue(row, 'system_count'),
    unlocked_positions: readNumberValue(row, 'unlocked_positions'),
    expansion_pending_galaxies: readNumberValue(row, 'expansion_pending_galaxies'),
    expansion_oldest_lag_seconds: readNumberValue(row, 'expansion_oldest_lag_seconds'),
    next_galaxy_roll_at: readStringValue(row, 'next_galaxy_roll_at'),
    galaxy_rolls_due: readNumberValue(row, 'galaxy_rolls_due'),
    ai_planets_count: readNumberValue(row, 'ai_planets_count'),
    ai_density: readNumberValue(row, 'ai_density'),
    ai_density_target: readNumberValue(row, 'ai_density_target'),
    ai_density_tolerance: readNumberValue(row, 'ai_density_tolerance'),
    ai_density_lower_bound: readNumberValue(row, 'ai_density_lower_bound'),
    ai_density_upper_bound: readNumberValue(row, 'ai_density_upper_bound'),
    ai_deficit: readNumberValue(row, 'ai_deficit'),
    ai_generation_batch: readNumberValue(row, 'ai_generation_batch'),
    ai_estimated_batches: readNumberValue(row, 'ai_estimated_batches'),
    next_ai_reconciliation_at: readStringValue(row, 'next_ai_reconciliation_at'),
  }
}
