import type { UITemplate } from '../types'

/*
  TEMPLATE: TACTICAL
  Alta densidad operacional: tira de estado, tres columnas de consola
  (operaciones / activos / registro) y barra de acciones al pie. Densidad
  apretada, esquinas rectas y tema ámbar de alto contraste.

  Decide REGIÓN y ORDEN. La geometría vive en ui-engine.css.
*/
export const tacticalTemplate = {
  id: 'tactical',
  label: 'Tactical',
  description: 'Consola compacta: estado, tres columnas operativas y barra de acciones.',
  theme: 'tactical',
  density: 'dense',
  regions: ['status', 'ops', 'assets', 'log', 'actions'],
  placement: {
    'fleet.command': 'status',
    'fleet.slots': 'status',
    'fleet.setup': 'ops',
    'fleet.destination': 'ops',
    'fleet.ships-civil': 'assets',
    'fleet.ships-support': 'assets',
    'fleet.ships-combat': 'assets',
    'fleet.ships-other': 'assets',
    'fleet.composition-note': 'assets',
    'fleet.cargo': 'assets',
    'fleet.capacity': 'log',
    'fleet.slot-summary': 'log',
    'fleet.support-authorizations': 'log',
    'fleet.active': 'log',
    'fleet.launch': 'actions',
    'resources.summary': 'status',
    'messages.feed': 'log',
    'buildings.grid': 'assets',
    'research.grid': 'assets',
    'shipyard.grid': 'assets',
    'defense.grid': 'assets',
    'galaxy.grid': 'ops',
  },
  order: [
    'fleet.command',
    'fleet.slots',
    'fleet.setup',
    'fleet.destination',
    'fleet.ships-civil',
    'fleet.ships-support',
    'fleet.ships-combat',
    'fleet.ships-other',
    'fleet.composition-note',
    'fleet.cargo',
    'fleet.capacity',
    'fleet.slot-summary',
    'fleet.support-authorizations',
    'fleet.active',
    'fleet.launch',
    'resources.summary',
    'messages.feed',
    'buildings.grid',
    'research.grid',
    'shipyard.grid',
    'defense.grid',
    'galaxy.grid',
  ],
  resizableTracks: ['ops', 'assets', 'log'],
} satisfies UITemplate
