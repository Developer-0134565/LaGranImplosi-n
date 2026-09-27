import { createUIRegistry, defineUIModule } from '../../ui-engine'
import { FLEET_SHIP_GROUPS } from './fleetShipGroups'

/*
  REGISTRY DE FLOTA

  Cada módulo declara su id `dominio.nombre`. El template decide después en qué
  región vive y en qué orden; este archivo no contiene ninguna decisión de
  layout.
*/

export const fleetModuleIds = {
  command: 'fleet.command',
  slots: 'fleet.slots',
  slotSummary: 'fleet.slot-summary',
  supportAuthorizations: 'fleet.support-authorizations',
  setup: 'fleet.setup',
  destination: 'fleet.destination',
  capacity: 'fleet.capacity',
  cargo: 'fleet.cargo',
  compositionNote: 'fleet.composition-note',
  launch: 'fleet.launch',
  active: 'fleet.active',
} as const

export const fleetRegistry = createUIRegistry([
  defineUIModule('fleet', 'command', 'Barra de mando', 'Título, contexto y slots libres de la pantalla.'),
  defineUIModule('fleet', 'slots', 'Slots de despacho', 'Slots autoritativos del cuerpo de origen (get_player_fleet_slots).'),
  defineUIModule('fleet', 'slot-summary', 'Resumen de slots', 'Panel comparativo de slots del imperio.'),
  defineUIModule('fleet', 'support-authorizations', 'Autorizaciones de apoyo', 'Descubrimiento owner-scoped de destinos autorizados.'),
  defineUIModule('fleet', 'setup', 'Origen y misión', 'Cuerpo de origen, misión y resumen de la selección.'),
  defineUIModule('fleet', 'destination', 'Destino', 'Coordenadas, autorizaciones y holding_until según la misión.'),
  defineUIModule('fleet', 'capacity', 'Capacidad', 'Slots de expedición y cap de colonias.'),
  defineUIModule('fleet', 'cargo', 'Bodega', 'Carga a embarcar con load_fleet_cargo tras el despacho.'),
  defineUIModule('fleet', 'composition-note', 'Nota de colonización', 'COLONIZE no recibe composición.'),
  defineUIModule('fleet', 'launch', 'Lanzamiento', 'Acción principal y motivos de bloqueo del servidor.'),
  defineUIModule('fleet', 'active', 'Flotas activas', 'Movimientos, fase del ciclo de vida, retirada y bodega.'),
  ...FLEET_SHIP_GROUPS.map((group) => defineUIModule('fleet', `ships-${group.id}`, group.title, 'Selección de naves por grupo.')),
])
