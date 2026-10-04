import { supabase } from './supabase'
import type { Database } from './database.types'

/** Jugador resuelto para la sesión actual (players.user_id = auth.uid()). */
export type PlayerIdentity = Pick<
  Database['public']['Tables']['players']['Row'],
  'id' | 'username' | 'universe_id' | 'user_id'
>

/**
 * Identidad canónica: Supabase Auth (email/password) → auth.uid() → players.user_id.
 * El modo invitado (sesión anónima + register_guest_player) fue retirado:
 * no existe ninguna ruta de creación automática de jugadores aquí.
 */

/** auth.uid() efectivo, validado contra el servidor. */
export async function currentAuthUserId(): Promise<string> {
  const { data, error } = await supabase.auth.getUser()
  if (error || !data.user) throw new Error('Sesión no válida')
  return data.user.id
}

/**
 * Jugador ligado inequívocamente a la sesión: players.user_id = auth.uid().
 * Devuelve null si la sesión todavía no tiene jugador asociado.
 */
export async function resolvePlayer(): Promise<PlayerIdentity | null> {
  const userId = await currentAuthUserId()
  const { data, error } = await supabase
    .from('players')
    .select('id,username,universe_id,user_id')
    .eq('user_id', userId)
    .maybeSingle()
  if (error) throw new Error(error.message)
  return data ?? null
}

/** Imperio provisionado por el onboarding explícito. */
export type ProvisionedEmpire = {
  playerId: string
  planetId: string | null
  username: string
  galaxy: number | null
  system: number | null
  position: number | null
}

/**
 * Estado de identidad de la sesión autenticada:
 *   auth.uid() → players.user_id → players.id
 * No crea jugadores: cuando no existe, lo señala para que la UI ejecute el
 * onboarding explícito (`provisionPlayer`).
 */
export async function resolveIdentity(): Promise<{ player: PlayerIdentity | null; needsOnboarding: boolean }> {
  const player = await resolvePlayer()
  return { player, needsOnboarding: player === null }
}

/**
 * Onboarding canónico (email/password): crea el imperio del usuario autenticado
 * —player + Homeworld + resources + research— en una única transacción.
 * Es idempotente (reuse-first): si la sesión ya tiene jugador, devuelve el suyo
 * y nunca reclama un jugador existente.
 */
export async function provisionPlayer(
  p_username: string,
  p_country_code = 'XX',
  p_planet_name: string | null = null,
  p_avatar_id: string | null = null,
): Promise<ProvisionedEmpire> {
  // `provision_player` está tipada en database.types.ts desde la reconciliación LIVE:
  // la llamada va directa, sin casts que oculten incompatibilidades.
  const { data, error } = await supabase.rpc('provision_player', {
    p_username,
    p_country_code,
    p_planet_name,
    p_avatar_id,
  })
  if (error) throw new Error(error.message)
  const row = (Array.isArray(data) ? data[0] : data) as Record<string, unknown> | undefined
  if (!row) throw new Error('PROVISION_FAILED')
  return {
    playerId: String(row.player_id),
    planetId: (row.planet_id as string | null) ?? null,
    username: String(row.username),
    galaxy: (row.galaxy as number | null) ?? null,
    system: (row.system as number | null) ?? null,
    position: (row.planet_position as number | null) ?? null,
  }
}
