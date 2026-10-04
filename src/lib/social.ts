import { supabase } from './supabase'

/*
  SERVICIO SOCIAL (Buddies + Alianzas)

  Contrato fuente de verdad: las tres migraciones locales
    20261003000000_social_foundations_buddies.sql
    20261003010000_social_foundations_alliances.sql
    20261003020000_defend_social_authorization.sql
  Cada firma de este archivo está copiada de la definición SQL, no inventada.

  REGLAS RESPETADAS
   - El backend resuelve SIEMPRE la identidad del llamante con auth.uid()
     (`current_player_id()`). Por eso NINGÚN método acepta un `playerId` de
     llamante: sólo el id de la CONTRAPARTE.
   - Las tablas sociales no tienen GRANT para `authenticated`/`anon`: este
     servicio no hace `from(...)` sobre ellas, sólo `rpc(...)`.
   - Un solo cliente Supabase (el de `lib/supabase`), nunca un segundo.
   - Los errores conservan su código original (`SocialRpcError.code`) para que
     la UI pueda distinguirlos; el mensaje no se reescribe ni se oculta.
   - No hay `any` ni casts ciegos: cada retorno se valida y se estrecha.

  TIPADO DEL RPC — por qué NO se edita `database.types.ts`
    Ese fichero es GENERADO desde la base de datos desplegada. Los contratos
    sociales aún NO están desplegados (verificar con `migrate`), así que
    escribir ahí afirmaría una forma que LIVE no tiene. Se declara el tipo del
    RPC localmente y se ENSANCHA el cliente, igual que ya hace
    `lib/universeEvolutionMonitor.ts` con `get_universe_evolution_monitor_public`.
    En cuanto las migraciones se apliquen, `generate types` sustituirá esto.
*/

type SocialRpcFunctions = {
  list_buddies: { Args: Record<string, never>; Returns: BuddyRelationRow[] }
  send_buddy_request: {
    Args: { p_addressee_player_id: string; p_message?: string | null }
    Returns: { out_id: string; out_addressee_player_id: string; out_status: string }[]
  }
  respond_buddy_request: { Args: { p_request_id: string; p_accept: boolean }; Returns: unknown }
  cancel_buddy_request: { Args: { p_request_id: string }; Returns: boolean }
  remove_buddy: { Args: { p_buddy_player_id: string }; Returns: boolean }
  players_are_buddies: { Args: { p_player_a: string; p_player_b: string }; Returns: boolean }

  create_alliance: {
    Args: { p_tag: string; p_name: string }
    Returns: { out_alliance_id: string; out_alliance_tag: string; out_alliance_name: string }[]
  }
  apply_to_alliance: { Args: { p_alliance_id: string; p_message?: string | null }; Returns: unknown }
  respond_alliance_application: { Args: { p_application_id: string; p_accept: boolean }; Returns: unknown }
  leave_alliance: { Args: Record<string, never>; Returns: boolean }
  dissolve_alliance: { Args: Record<string, never>; Returns: boolean }
  create_alliance_rank: {
    Args: { p_rank_name: string; p_permissions: string[]; p_sort_order?: number }
    Returns: { out_rank_id: string; out_rank_name: string; out_permissions: string[] }[]
  }
  set_alliance_member_rank: { Args: { p_player_id: string; p_rank_id: string | null }; Returns: boolean }
  list_alliance_members: {
    Args: { p_alliance_id: string }
    Returns: {
      out_player_id: string
      out_username: string
      out_rank_id: string | null
      out_rank_name: string | null
      out_is_founder: boolean
      out_permissions: string[]
    }[]
  }
  alliance_member_permission: {
    Args: { p_player_id: string; p_alliance_id: string; p_permission: string }
    Returns: boolean
  }
  players_in_same_alliance: { Args: { p_player_a: string; p_player_b: string }; Returns: boolean }

  can_defend_player: {
    Args: { p_supporting_player_id: string; p_target_planet_id: string }
    Returns: {
      out_allowed: boolean
      out_reason: string
      out_owner_player_id: string | null
      out_via_buddy: boolean
      out_via_alliance: boolean
    }[]
  }
  defend_dispatch_readiness: {
    Args: Record<string, never>
    Returns: {
      out_schema_ready: boolean
      out_dispatch_open: boolean
      out_combat_ready: boolean
      out_authorization_ready: boolean
      out_blocking_reason: string
    }[]
  }
}

/** Fila cruda de `list_buddies`, tal y como la devuelve el SQL. */
type BuddyRelationRow = {
  out_relation_id: string
  out_buddy_player_id: string
  out_buddy_username: string
  out_status: string
  out_direction: string
}

/**
 * Cliente ya existente, sólo con el tipo ampliado: NO se crea un segundo
 * cliente Supabase. `SocialRpcFunctions` es lo que documenta las firmas; el
 * narrowing happens en `socialSupabase`.
 */
const socialSupabase = supabase as unknown as {
  rpc: <K extends keyof SocialRpcFunctions>(
    fn: K,
    args?: SocialRpcFunctions[K]['Args'],
  ) => Promise<{ data: unknown; error: { code?: string; message: string } | null }>
}

/* ------------------------------------------------------------------ tipos */

/** Estado de una relación de amistad (texto en el SQL, no smallint). */
export type BuddyRelationStatus = 'PENDING' | 'ACCEPTED' | 'REJECTED'

/**
 * Dirección vista desde el llamante. La amistad es SIMÉTRICA una vez
 * aceptada, pero las pendientes no lo son: hay que saber quién espera.
 */
export type BuddyRelationDirection = 'ESTABLISHED' | 'INCOMING_PENDING' | 'OUTGOING_PENDING'

export type BuddyRelation = {
  relationId: string
  buddyPlayerId: string
  buddyUsername: string
  status: BuddyRelationStatus
  direction: BuddyRelationDirection
}

/**
 * Permisos de rango. El vocabulario es EXACTAMENTE el CHECK de
 * `player_alliance_ranks_known_permissions_check` (constantes
 * `AllianceRank::PERMISSION_*` de OGameX). No se admiten otros.
 */
export const ALLIANCE_PERMISSIONS = [
  'see_applications',
  'edit_applications',
  'see_members',
  'kick_user',
  'see_member_online_status',
  'send_circular_msg',
  'delete_ally',
  'manage_ally',
  'right_hand',
  'manage_classes',
] as const

export type AlliancePermission = (typeof ALLIANCE_PERMISSIONS)[number]

/** Etiquetas legibles para los permisos, sólo para presentación. */
export const ALLIANCE_PERMISSION_LABELS: Readonly<Record<AlliancePermission, string>> = {
  see_applications: 'Ver solicitudes',
  edit_applications: 'Gestionar solicitudes',
  see_members: 'Ver miembros',
  kick_user: 'Expulsar miembros',
  see_member_online_status: 'Ver estado online',
  send_circular_msg: 'Mensaje circular',
  delete_ally: 'Disolver alianza',
  manage_ally: 'Gestionar alianza',
  right_hand: 'Mano derecha',
  manage_classes: 'Gestionar rangos',
}

export type AllianceMemberRow = {
  playerId: string
  username: string
  rankId: string | null
  rankName: string | null
  isFounder: boolean
  permissions: readonly AlliancePermission[]
}

/* ------------------------------------------------------------------ errores */

/**
 * Error de un RPC social. Conserva `code` (SQLSTATE de Postgres o el código de
 * aplicación que emite el SQL, p.ej. `BUDDY_SELF_NOT_ALLOWED`) para que la UI
 * pueda reaccionar al caso concreto sin parsear el mensaje.
 */
export class SocialRpcError extends Error {
  readonly code: string
  readonly operation: string

  constructor(operation: string, code: string, message: string) {
    super(message)
    this.name = 'SocialRpcError'
    this.operation = operation
    this.code = code
  }
}

/* ------------------------------------------------------------------ helpers */

function readField(row: unknown, key: string): unknown {
  if (row === null || typeof row !== 'object') return undefined
  return Reflect.get(row, key)
}

function readString(row: unknown, key: string): string | null {
  const value = readField(row, key)
  return typeof value === 'string' && value.length > 0 ? value : null
}

function readBoolean(row: unknown, key: string): boolean {
  return readField(row, key) === true
}

function readStringArray(row: unknown, key: string): string[] {
  const value = readField(row, key)
  return Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === 'string') : []
}

/**
 * Normaliza el error de PostgREST conservando su código. El mensaje del servidor
 * se mantiene íntegro (`BUDDY_SELF_NOT_ALLOWED: a buddy request requires a
 * different player`), porque es información técnica útil que el log necesita.
 */
function toSocialError(operation: string, error: { code?: string; message: string }): SocialRpcError {
  const code = typeof error.code === 'string' && error.code.length > 0 ? error.code : 'RPC_ERROR'
  return new SocialRpcError(operation, code, error.message)
}

/**
 * Los RPC que devuelven tabla llegan como array y los escalares como valor.
 * Centralizarlo evita repetir el `Array.isArray` en cada lector.
 */
function firstRow(data: unknown): unknown {
  if (Array.isArray(data)) return data[0] ?? null
  return data ?? null
}

function rows(data: unknown): unknown[] {
  return Array.isArray(data) ? data : []
}

function isAlliancePermission(value: string): value is AlliancePermission {
  return (ALLIANCE_PERMISSIONS as readonly string[]).includes(value)
}

/* ------------------------------------------------------------------ buddies */

/** Friendship del llamante con dirección. Nunca acepta un jugador ajeno. */
export async function listBuddyRelations(): Promise<BuddyRelation[]> {
  const { data, error } = await socialSupabase.rpc('list_buddies')
  if (error) throw toSocialError('list_buddies', error)

  const relations: BuddyRelation[] = []
  for (const row of rows(data)) {
    const relationId = readString(row, 'out_relation_id')
    const buddyPlayerId = readString(row, 'out_buddy_player_id')
    // Una fila sin identidad no es una relación: se descarta en lugar de
    // inventar un objeto con campos vacíos que la UI presentaría como real.
    if (!relationId || !buddyPlayerId) continue
    const status = readString(row, 'out_status')
    const direction = readString(row, 'out_direction')
    relations.push({
      relationId,
      buddyPlayerId,
      buddyUsername: readString(row, 'out_buddy_username') ?? 'Jugador desconocido',
      status: status === 'ACCEPTED' || status === 'REJECTED' ? status : 'PENDING',
      direction:
        direction === 'INCOMING_PENDING' || direction === 'OUTGOING_PENDING' ? direction : 'ESTABLISHED',
    })
  }
  return relations
}

/** Envía (o reemite) una solicitud. La identidad la resuelve el backend. */
export async function sendBuddyRequest(addresseePlayerId: string, message?: string): Promise<void> {
  const { error } = await socialSupabase.rpc('send_buddy_request', {
    p_addressee_player_id: addresseePlayerId,
    p_message: message ?? null,
  })
  if (error) throw toSocialError('send_buddy_request', error)
}

/** Sólo el destinatario puede responder: el backend lo exige. */
export async function respondBuddyRequest(requestId: string, accept: boolean): Promise<void> {
  const { error } = await socialSupabase.rpc('respond_buddy_request', {
    p_request_id: requestId,
    p_accept: accept,
  })
  if (error) throw toSocialError('respond_buddy_request', error)
}

/** Sólo el emisor puede cancelar, y sólo mientras siga PENDING. */
export async function cancelBuddyRequest(requestId: string): Promise<void> {
  const { error } = await socialSupabase.rpc('cancel_buddy_request', { p_request_id: requestId })
  if (error) throw toSocialError('cancel_buddy_request', error)
}

/** Cualquiera de las dos partes puede terminar la amistad (simétrico). */
export async function removeBuddy(buddyPlayerId: string): Promise<void> {
  const { error } = await socialSupabase.rpc('remove_buddy', { p_buddy_player_id: buddyPlayerId })
  if (error) throw toSocialError('remove_buddy', error)
}

/* --------------------------------------------------------------- alliances */

export type CreatedAlliance = { allianceId: string; allianceTag: string; allianceName: string }

export async function createAlliance(tag: string, name: string): Promise<CreatedAlliance> {
  const { data, error } = await socialSupabase.rpc('create_alliance', { p_tag: tag, p_name: name })
  if (error) throw toSocialError('create_alliance', error)

  const row = firstRow(data)
  const allianceId = readString(row, 'out_alliance_id')
  if (!allianceId) {
    throw new SocialRpcError('create_alliance', 'MALFORMED_RESPONSE', 'El servidor no devolvió la alianza creada.')
  }
  return {
    allianceId,
    allianceTag: readString(row, 'out_alliance_tag') ?? tag,
    allianceName: readString(row, 'out_alliance_name') ?? name,
  }
}

export async function applyToAlliance(allianceId: string, message?: string): Promise<void> {
  const { error } = await socialSupabase.rpc('apply_to_alliance', {
    p_alliance_id: allianceId,
    p_message: message ?? null,
  })
  if (error) throw toSocialError('apply_to_alliance', error)
}

/** Requiere `edit_applications`; el fundador lo tiene por definición. */
export async function respondAllianceApplication(applicationId: string, accept: boolean): Promise<void> {
  const { error } = await socialSupabase.rpc('respond_alliance_application', {
    p_application_id: applicationId,
    p_accept: accept,
  })
  if (error) throw toSocialError('respond_alliance_application', error)
}

/** El fundador NO puede irse: debe disolver. El backend lo rechaza. */
export async function leaveAlliance(): Promise<void> {
  const { error } = await socialSupabase.rpc('leave_alliance')
  if (error) throw toSocialError('leave_alliance', error)
}

/** Sólo el fundador. Disuelve en cascada miembros, rangos y solicitudes. */
export async function dissolveAlliance(): Promise<void> {
  const { error } = await socialSupabase.rpc('dissolve_alliance')
  if (error) throw toSocialError('dissolve_alliance', error)
}

export async function createAllianceRank(
  rankName: string,
  permissions: readonly AlliancePermission[],
  sortOrder = 0,
): Promise<{ rankId: string; rankName: string; permissions: readonly AlliancePermission[] }> {
  const { data, error } = await socialSupabase.rpc('create_alliance_rank', {
    p_rank_name: rankName,
    p_permissions: [...permissions],
    p_sort_order: sortOrder,
  })
  if (error) throw toSocialError('create_alliance_rank', error)

  const row = firstRow(data)
  const rankId = readString(row, 'out_rank_id')
  if (!rankId) {
    throw new SocialRpcError('create_alliance_rank', 'MALFORMED_RESPONSE', 'El servidor no devolvió el rango creado.')
  }
  return {
    rankId,
    rankName: readString(row, 'out_rank_name') ?? rankName,
    permissions: readStringArray(row, 'out_permissions').filter(isAlliancePermission),
  }
}

/** Requiere `manage_classes`. El rango del fundador es fijo y el backend lo rechaza. */
export async function setAllianceMemberRank(playerId: string, rankId: string | null): Promise<void> {
  const { error } = await socialSupabase.rpc('set_alliance_member_rank', {
    p_player_id: playerId,
    p_rank_id: rankId,
  })
  if (error) throw toSocialError('set_alliance_member_rank', error)
}

/** El backend la filtra por `see_members`: un no-miembro recibe 0 filas. */
export async function listAllianceMembers(allianceId: string): Promise<AllianceMemberRow[]> {
  const { data, error } = await socialSupabase.rpc('list_alliance_members', {
    p_alliance_id: allianceId,
  })
  if (error) throw toSocialError('list_alliance_members', error)

  const members: AllianceMemberRow[] = []
  for (const row of rows(data)) {
    const playerId = readString(row, 'out_player_id')
    if (!playerId) continue
    members.push({
      playerId,
      username: readString(row, 'out_username') ?? 'Jugador desconocido',
      rankId: readString(row, 'out_rank_id'),
      rankName: readString(row, 'out_rank_name'),
      isFounder: readBoolean(row, 'out_is_founder'),
      permissions: readStringArray(row, 'out_permissions').filter(isAlliancePermission),
    })
  }
  return members
}

export async function allianceMemberPermission(
  playerId: string,
  allianceId: string,
  permission: AlliancePermission,
): Promise<boolean> {
  const { data, error } = await socialSupabase.rpc('alliance_member_permission', {
    p_player_id: playerId,
    p_alliance_id: allianceId,
    p_permission: permission,
  })
  if (error) throw toSocialError('alliance_member_permission', error)
  return firstRow(data) === true
}

export async function playersAreBuddies(playerA: string, playerB: string): Promise<boolean> {
  const { data, error } = await socialSupabase.rpc('players_are_buddies', {
    p_player_a: playerA,
    p_player_b: playerB,
  })
  if (error) throw toSocialError('players_are_buddies', error)
  return firstRow(data) === true
}

export async function playersInSameAlliance(playerA: string, playerB: string): Promise<boolean> {
  const { data, error } = await socialSupabase.rpc('players_in_same_alliance', {
    p_player_a: playerA,
    p_player_b: playerB,
  })
  if (error) throw toSocialError('players_in_same_alliance', error)
  return firstRow(data) === true
}

/* ------------------------------------------------------------------- DEFEND */

export type DefendAuthorization = {
  allowed: boolean
  reason: string
  ownerPlayerId: string | null
  viaBuddy: boolean
  viaAlliance: boolean
}

/**
 * Autorización SOCIAL de DEFEND (regla OGameX: buddy OR same alliance).
 * Sólo lectura: NO autoriza un movimiento y NO sustituye a la comprobación
 * `planet_support_authorizations` de `start_support_fleet`, que sigue intacta.
 * El dispatch de DEFEND permanece bloqueado por el rediseño multi-flota.
 */
export async function canDefendPlayer(
  supportingPlayerId: string,
  targetPlanetId: string,
): Promise<DefendAuthorization> {
  const { data, error } = await socialSupabase.rpc('can_defend_player', {
    p_supporting_player_id: supportingPlayerId,
    p_target_planet_id: targetPlanetId,
  })
  if (error) throw toSocialError('can_defend_player', error)

  const row = firstRow(data)
  return {
    allowed: readBoolean(row, 'out_allowed'),
    reason: readString(row, 'out_reason') ?? 'DEFEND_UNKNOWN',
    ownerPlayerId: readString(row, 'out_owner_player_id'),
    viaBuddy: readBoolean(row, 'out_via_buddy'),
    viaAlliance: readBoolean(row, 'out_via_alliance'),
  }
}

export type DefendReadiness = {
  schemaReady: boolean
  dispatchOpen: boolean
  combatReady: boolean
  authorizationReady: boolean
  blockingReason: string
}

/** Informe honesto de readiness: lo deriva el servidor de sus propios cuerpos. */
export async function defendDispatchReadiness(): Promise<DefendReadiness> {
  const { data, error } = await socialSupabase.rpc('defend_dispatch_readiness')
  if (error) throw toSocialError('defend_dispatch_readiness', error)

  const row = firstRow(data)
  return {
    schemaReady: readBoolean(row, 'out_schema_ready'),
    dispatchOpen: readBoolean(row, 'out_dispatch_open'),
    combatReady: readBoolean(row, 'out_combat_ready'),
    authorizationReady: readBoolean(row, 'out_authorization_ready'),
    blockingReason: readString(row, 'out_blocking_reason') ?? 'DEFEND_UNKNOWN',
  }
}