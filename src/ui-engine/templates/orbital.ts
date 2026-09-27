import type { UITemplate } from '../types'

/*
  TEMPLATE: ORBITAL
  Vista de sistema: tira de estado a todo el ancho, rail de mando a la
  izquierda, ventana principal en el centro (destino + bodega + flota activa) y
  columna de activos a la derecha. Barra de acciones al pie.
  Densidad cómoda, tema nebula, rail redimensionable.

  Decide REGIÓN y ORDEN. La geometría vive en ui-engine.css.
*/
export const orbitalTemplate = {
  id: 'orbital',
  label: 'Orbital',
  description: 'Vista de sistema: rail de mando, ventana central y columna de activos.',
  theme: 'nebula',
  density: 'comfortable',
  regions: ['status', 'rail', 'main', 'ops', 'assets', 'actions'],
  placement: {
    'fleet.command': 'status',
    'fleet.slots': 'status',
    'fleet.setup': 'rail',
    'fleet.capacity': 'rail',
    'fleet.slot-summary': 'rail',
    'fleet.support-authorizations': 'rail',
    'fleet.destination': 'main',
    'fleet.cargo': 'main',
    'fleet.ships-civil': 'assets',
    'fleet.ships-support': 'assets',
    'fleet.ships-combat': 'assets',
    'fleet.ships-other': 'assets',
    'fleet.composition-note': 'assets',
    'fleet.active': 'ops',
    'fleet.launch': 'actions',
    'resources.summary': 'status',
    'buildings.grid': 'main',
    'research.grid': 'main',
    'shipyard.grid': 'assets',
    'defense.grid': 'assets',
    'galaxy.grid': 'main',
    'messages.feed': 'ops',
  },
  order: [
    'fleet.command',
    'fleet.slots',
    'resources.summary',
    'fleet.setup',
    'fleet.capacity',
    'fleet.slot-summary',
    'fleet.support-authorizations',
    'fleet.destination',
    'fleet.cargo',
    'buildings.grid',
    'research.grid',
    'galaxy.grid',
    'fleet.active',
    'messages.feed',
    'fleet.ships-civil',
    'fleet.ships-support',
    'fleet.ships-combat',
    'fleet.ships-other',
    'fleet.composition-note',
    'shipyard.grid',
    'defense.grid',
    'fleet.launch',
  ],
  resizableTracks: ['rail', 'ops'],
} satisfies UITemplate
