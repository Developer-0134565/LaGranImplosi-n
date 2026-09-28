import type { UITemplate } from '../types'

/*
  TEMPLATE: CLASSIC
  Referencia conceptual: navegación lateral persistente + cabecera de recursos +
  contenido central denso (jerarquía de un strategy game espacial clásico).

  Decide REGIÓN y ORDEN. No dibuja nada: la geometría vive en ui-engine.css
  bajo `.lgi-engine[data-lgi-template='classic']`.
*/
export const classicTemplate = {
  id: 'classic',
  label: 'Classic',
  description: 'Rail lateral operativo, contenido central denso y columna de imperio a la derecha.',
  theme: 'nebula',
  density: 'compact',
  regions: ['rail', 'main', 'aside'],
  placement: {
    'resources.summary': 'main',
    'navigation.rail': 'rail',
    'navigation.main': 'main',
    'planet.bodies': 'aside',
    'fleet.command': 'main',
    'fleet.slots': 'rail',
    'fleet.setup': 'rail',
    'fleet.capacity': 'rail',
    'fleet.support-authorizations': 'rail',
    'fleet.destination': 'main',
    'fleet.cargo': 'main',
    'fleet.ships-civil': 'main',
    'fleet.ships-support': 'main',
    'fleet.ships-combat': 'main',
    'fleet.ships-other': 'main',
    'fleet.composition-note': 'main',
    'fleet.launch': 'main',
    'fleet.slot-summary': 'aside',
    'fleet.active': 'aside',
    'messages.feed': 'aside',
    'buildings.grid': 'main',
    'research.grid': 'main',
    'shipyard.grid': 'main',
    'defense.grid': 'main',
    'galaxy.grid': 'main',
  },
  order: [
    'navigation.rail',
    'navigation.main',
    'planet.bodies',
    'fleet.command',
    'fleet.slots',
    'fleet.setup',
    'fleet.capacity',
    'fleet.support-authorizations',
    'fleet.destination',
    'fleet.cargo',
    'fleet.ships-civil',
    'fleet.ships-support',
    'fleet.ships-combat',
    'fleet.ships-other',
    'fleet.composition-note',
    'fleet.launch',
    'fleet.slot-summary',
    'fleet.active',
    'resources.summary',
    'messages.feed',
    'buildings.grid',
    'research.grid',
    'shipyard.grid',
    'defense.grid',
    'galaxy.grid',
  ],
  resizableTracks: ['rail', 'aside'],
} satisfies UITemplate
