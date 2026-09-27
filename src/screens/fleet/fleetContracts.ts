import type { Database } from '../../lib/database.types'

/*
  SUPERFICIE DE FLOTAS — CONTRATOS COMPARTIDOS (bloque A dispatch + bloque B movimientos).

  Regla de autoridad: esta capa no decide nada. Cada número, cada transición y cada rechazo vienen de un
  contrato ya certificado en Supabase; la UI sólo muestra la respuesta del servidor tal cual y nunca
  reproduce fórmulas (velocidad, combustible, distancia, slots, cap de colonias ni capacidad de carga).

  Contratos utilizados (todos LIVE, ninguno nuevo):
    start_fleet_mixed(p_player_id, p_origin_planet_id, p_destination_planet_id, p_ships, p_mission_type)
    start_colonize_fleet(p_player_id, p_origin_planet_id, p_galaxy, p_system, p_position)
    start_support_fleet(p_player_id, p_origin_planet_id, p_destination_planet_id, p_ships,
                        p_support_mission, p_holding_until, p_idempotency_key)
    load_fleet_cargo(p_fleet_id, p_metal, p_crystal, p_deuterium)
    recall_fleet(p_player_id, p_fleet_id)
    get_player_fleet_slots()
    get_player_expedition_slot_status()
    check_colony_cap(p_player_id)

  Lecturas directas permitidas por RLS (propietario): `fleet_movements`, `fleet_movement_ships`,
  `planet_ships`, `planets`, `ship_definitions`. Las tablas con `deny_direct_api_access`
  (`player_messages`, `espionage_reports`, `planet_support_authorizations`, ...) no se tocan aquí.

  Despacho por clase de misión (derivado de los cuerpos desplegados, no inventado):
    PEACEFUL  TRANSPORT · DEPLOY · COLONIZE · EXPEDITION
    WAR       ATTACK · ESPIONAGE · RECYCLE
    HOLDING   ACS_HOLD  (DEFEND → COMBAT_SUPPORT_NOT_READY · HOLDING → HOLDING_IS_INTERNAL_STATE)

  Ubicación: extraído de `FleetCommandPanel.tsx` durante la migración al LGI UI Engine. Los contratos y los
  cálculos son EXACTAMENTE los mismos; sólo cambió el archivo que los contiene.
*/

export type MissionClass = 'PEACEFUL' | 'WAR' | 'HOLDING'
export type DispatchContract = 'start_fleet_mixed' | 'start_colonize_fleet' | 'start_support_fleet' | 'start_moon_destruction'
export type DestinationKind = 'PLANET' | 'FOREIGN_PLANET' | 'FOREIGN_MOON' | 'EMPTY_COORDINATES' | 'OWN_SYSTEM_16' | 'NEAREST_DEBRIS'

export type MissionDefinition = {
  id: string
  label: string
  klass: MissionClass
  contract: DispatchContract
  destination: DestinationKind
  cargo: boolean
  dispatchable: boolean
  note: string
}

export type OwnedPlanet = {
  id: string
  name: string
  galaxy: number
  system: number
  position: number
  kind: string
  is_homeworld: boolean
}

export type ShipDefinition = {
  id: string
  name: string
  ship_type: string
  speed: number
  cargo_capacity: number
}

export type OwnedShip = { ship_id: string; quantity: number; definition: ShipDefinition | null }

export type FleetSlotRow = {
  out_player_id: string
  out_computer_technology_level: number
  out_max_slots: number
  out_slots_in_use: number
  out_slots_available: number
}

export type ExpeditionSlotRow = {
  base_slots: number
  settings_bonus: number
  item_bonus: number
  total_slots: number
  used_slots: number
  available_slots: number
}

export type ColonyCapRow = {
  allowed: boolean
  reason: string
  max_slots: number
  current_planets: number
  astrophysics_level: number
}

export type MovementRow = {
  id: string
  player_id: string
  mission_type: string
  status: string
  origin_planet_id: string
  destination_planet_id: string | null
  destination_galaxy: number | null
  destination_system: number | null
  destination_position: number | null
  started_at: string
  arrives_at: string
  returns_at: string | null
  holding_until: string | null
  fuel_consumed: number
  metal: number
  crystal: number
  deuterium: number
}

export type MovementShip = { fleet_id: string; ship_id: string; quantity: number }

export const numberFormat = (value: number | null | undefined) =>
  value == null ? '—' : Math.floor(Number(value)).toLocaleString('es-ES')

export const stamp = (value: string | null | undefined) =>
  !value ? '—' : new Date(value).toLocaleString('es-ES')

/** Segundos restantes hasta `target`; negativo cuando ya venció. */
export function secondsUntil(target: string | null | undefined, now: number): number | null {
  if (!target) return null
  const millis = new Date(target).getTime()
  if (Number.isNaN(millis)) return null
  return Math.floor((millis - now) / 1000)
}

export function humanSeconds(seconds: number): string {
  const total = Math.abs(Math.floor(seconds))
  const days = Math.floor(total / 86400)
  const hours = Math.floor((total % 86400) / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const secs = total % 60
  if (days > 0) return `${days}d ${hours}h`
  if (hours > 0) return `${hours}h ${minutes}m`
  if (minutes > 0) return `${minutes}m ${secs}s`
  return `${secs}s`
}

export function planetLabel(planet: PlanetLabel | undefined, fallbackId: string | null | undefined): string {
  if (!planet) return fallbackId ? `[${fallbackId.slice(0, 8)}…]` : '—'
  return `${planet.name} [${planet.galaxy}:${planet.system}:${planet.position}]${planet.kind === 'MOON' ? ' · LUNA' : ''}`
}

export function coordinates(g: number | null, s: number | null, p: number | null): string {
  if (g == null || s == null || p == null) return '—'
  return `[${g}:${s}:${p}]`
}

/** Entero positivo a partir de un campo de coordenadas escrito por el jugador. */
export function parseCoordinate(value: string): number | null {
  const parsed = Number.parseInt(value, 10)
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null
}

/** Entero no negativo a partir de un campo de carga. */
export function parseAmount(value: string): number {
  const parsed = Number.parseInt(value, 10)
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0
}

/** Normaliza cualquier rechazo del servidor (Error o PostgrestError) sin silenciar el mensaje original. */
export function errorMessage(value: unknown, fallback: string): string {
  if (value instanceof Error) return value.message
  if (typeof value === 'object' && value !== null && 'message' in value) {
    const message = (value as { message?: unknown }).message
    if (typeof message === 'string' && message.length > 0) return message
  }
  return fallback
}


export type PlanetLabel = { id: string; name: string; galaxy: number; system: number; position: number; kind: string }

/** Fila del contrato owner-scoped `get_player_support_authorizations`. */
export type SupportAuthorizationRow =
  Database['public']['Functions']['get_player_support_authorizations']['Returns'][number]


/** Catálogo de misiones del motor de flotas. `dispatchable:false` documenta una puerta del backend;
 *  nunca una decisión de producto inventada aquí. */
export const MISSIONS: MissionDefinition[] = [
  {
    id: 'TRANSPORT',
    label: 'TRANSPORTE',
    klass: 'PEACEFUL',
    contract: 'start_fleet_mixed',
    destination: 'PLANET',
    cargo: true,
    dispatchable: true,
    note: 'Entrega la carga en el planeta destino (resolve_transport_arrival).',
  },
  {
    id: 'DEPLOY',
    label: 'DESPLIEGUE',
    klass: 'PEACEFUL',
    contract: 'start_fleet_mixed',
    destination: 'PLANET',
    cargo: true,
    dispatchable: true,
    note: 'Entrega la carga y la flota se completa descargada en el destino (resolve_deploy_arrival).',
  },
  {
    id: 'COLONIZE',
    label: 'COLONIZACIÓN',
    klass: 'PEACEFUL',
    contract: 'start_colonize_fleet',
    destination: 'EMPTY_COORDINATES',
    cargo: true,
    dispatchable: true,
    note: 'Contrato propio: exige 1 colony_ship, valida el cap de colonias (Astrofísica) y que la posición [1..15] esté libre.',
  },
  {
    id: 'EXPEDITION',
    label: 'EXPEDICIÓN',
    klass: 'PEACEFUL',
    contract: 'start_fleet_mixed',
    destination: 'OWN_SYSTEM_16',
    cargo: true,
    dispatchable: true,
    note: 'El servidor fija el destino en la posición 16 del propio sistema y consume slot de expedición y slot de flota.',
  },
  {
    id: 'ATTACK',
    label: 'ATAQUE',
    klass: 'WAR',
    contract: 'start_fleet_mixed',
    destination: 'PLANET',
    cargo: false,
    dispatchable: true,
    note: 'El saqueo lo liquida el motor de combate; el cargador rechaza ATTACK (CARGO_MISSION_NOT_SUPPORTED).',
  },
  {
    id: 'ESPIONAGE',
    label: 'ESPIONAJE',
    klass: 'WAR',
    contract: 'start_fleet_mixed',
    destination: 'PLANET',
    cargo: true,
    dispatchable: true,
    note: 'El informe lo genera el motor de espionaje; la carga vuelve al origen en el regreso.',
  },
  {
    id: 'RECYCLE',
    label: 'RECICLAJE',
    klass: 'WAR',
    contract: 'start_fleet_mixed',
    destination: 'NEAREST_DEBRIS',
    cargo: false,
    dispatchable: true,
    note: 'El destino lo elige el servidor: el campo de escombros más cercano. Sólo admite recicladores.',
  },
  {
    id: 'MOON_DESTRUCTION',
    label: 'DESTRUCCIÓN LUNAR',
    klass: 'WAR',
    contract: 'start_moon_destruction',
    destination: 'FOREIGN_MOON',
    cargo: false,
    dispatchable: true,
    note: 'Contrato dedicado: exige al menos 1 deathstar y una luna ajena no destruida. Reutiliza el motor de flotas con la misión MOON_DESTRUCTION y el desenlace lo aplica el hook de combate.',
  },
  {
    id: 'ACS_HOLD',
    label: 'APOYO ACS',
    klass: 'HOLDING',
    contract: 'start_support_fleet',
    destination: 'FOREIGN_PLANET',
    cargo: true,
    dispatchable: true,
    note: 'Requiere autorización vigente del propietario del planeta destino (SUPPORT_AUTHORIZATION_REQUIRED) y clave de idempotencia.',
  },
  {
    id: 'DEFEND',
    label: 'DEFENSA',
    klass: 'HOLDING',
    contract: 'start_support_fleet',
    destination: 'FOREIGN_PLANET',
    cargo: true,
    dispatchable: false,
    note: 'COMBAT_SUPPORT_NOT_READY: DEFEND exige el motor de combate ACS. El backend lo rechaza explícitamente.',
  },
  {
    id: 'HOLDING',
    label: 'EN ESPERA',
    klass: 'HOLDING',
    contract: 'start_support_fleet',
    destination: 'FOREIGN_PLANET',
    cargo: true,
    dispatchable: false,
    note: 'HOLDING_IS_INTERNAL_STATE: es un estado del ciclo de vida del movimiento, no una misión despachable.',
  },
]

export const MISSION_BY_ID = new Map(MISSIONS.map((mission) => [mission.id, mission]))

/** Whitelist LIVE del cuerpo desplegado de `load_fleet_cargo`. */
export const CARGO_LOADABLE_MISSIONS = ['TRANSPORT', 'ESPIONAGE', 'ACS_HOLD', 'DEPLOY', 'COLONIZE', 'EXPEDITION']
/** Estados desde los que `recall_fleet` acepta la retirada (el servidor decide el timing). */
export const RECALLABLE_STATUSES = ['OUTBOUND', 'HOLDING']
/** `crawler` y `solar_satellite` declaran speed 0: cualquier despacho los rechaza. */
export const IMMOBILE_SPEED = 0
