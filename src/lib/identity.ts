import { supabase } from './supabase'
import type { Database } from './database.types'

/** Jugador resuelto para la sesión actual (players.user_id = auth.uid()). */
export type PlayerIdentity = Pick<
  Database['public']['Tables']['players']['Row'],
  'id' | 'username' | 'is_guest' | 'universe_id' | 'user_id'
>

const VISITOR_STORAGE_KEY = 'lagranimplosion-visitor-id'
const FALLBACK_VISITOR_ID = '00000000000000000000000000000000'

/** Identificador estable del visitante (>=32 chars, exigido por register_guest_player). */
function visitorId(): string {
  try {
    const saved = localStorage.getItem(VISITOR_STORAGE_KEY)
    if (saved && saved.length >= 32) return saved
    const raw =
      typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function'
        ? crypto.randomUUID().replace(/-/g, '')
        : `${Math.random().toString(16).slice(2)}${Date.now().toString(16)}`.replace(/[^0-9a-f]/g, '')
    const value = raw.padEnd(32, '0').slice(0, 32)
    localStorage.setItem(VISITOR_STORAGE_KEY, value)
    return value
  } catch {
    return FALLBACK_VISITOR_ID
  }
}

/** Nombre de invitado válido para register_guest_player (3-24 chars, [alnum _ . -]). */
function guestUsername(): string {
  return `Invitado-${visitorId().slice(0, 8)}`
}

let sessionBootstrap: Promise<void> | null = null

/**
 * Garantiza que existe sesión: reutiliza la persistida o crea una ANÓNIMA
 * (modo invitado). Nunca crea una segunda sesión si ya hay una.
 */
export function ensureSession(): Promise<void> {
  if (!sessionBootstrap) {
    sessionBootstrap = (async () => {
      const { data } = await supabase.auth.getSession()
      if (data.session) return
      const { error } = await supabase.auth.signInAnonymously()
      if (error) throw new Error(error.message)
    })().catch((error: unknown) => {
      sessionBootstrap = null
      throw error
    })
  }
  return sessionBootstrap
}

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
    .select('id,username,is_guest,universe_id,user_id')
    .eq('user_id', userId)
    .maybeSingle()
  if (error) throw new Error(error.message)
  return data ?? null
}

/**
 * Cadena de identidad completa:
 *   sesión (anónima si hace falta) → auth.uid() → players.user_id → players.id
 * Si el usuario autenticado aún no tiene jugador, se registra como invitado.
 */
export async function resolveIdentity(): Promise<{ player: PlayerIdentity; registered: boolean }> {
  await ensureSession()
  const existing = await resolvePlayer()
  if (existing) return { player: existing, registered: false }

  const { error } = await supabase.rpc('register_guest_player', {
    p_username: guestUsername(),
    p_country_code: 'XX',
    p_ip_hash: visitorId(),
  })
  if (error) throw new Error(error.message)

  const player = await resolvePlayer()
  if (!player) throw new Error('El jugador invitado no se pudo resolver tras el registro')
  return { player, registered: true }
}
