import type { UITemplate } from '../types'

/*
  TEMPLATE: COMMAND
  Dashboard moderno: cabecera operativa a todo el ancho (estado + acción
  principal), módulos de trabajo en la columna principal y panel contextual
  a la derecha. Densidad cómoda y radios amplios (tema aurora).

  Decide REGIÓN y ORDEN. La geometría vive en ui-engine.css.
*/
export const commandTemplate = {
  id: 'command',
  label: 'Command',
  description: 'Cabecera de mando a todo el ancho, módulos de trabajo y panel contextual.',
  theme: 'aurora',
  density: 'comfortable',
  regions: ['header', 'main', 'aside'],
  placement: {
    'resources.summary': 'header',
    'fleet.launch': 'main',
    'navigation.main': 'main',
    'planet.bodies': 'aside',
    'fleet.command': 'header',
    'fleet.slots': 'header',
    'fleet.launch': 'main',
    'fleet.setup': 'main',
    'fleet.destination': 'main',
    'fleet.ships-civil': 'main',
    'fleet.ships-support': 'main',
    'fleet.ships-combat': 'main',
    'fleet.ships-other': 'main',
    'fleet.composition-note': 'main',
    'fleet.cargo': 'main',
    'fleet.active': 'main',
    'fleet.slot-summary': 'aside',
    'fleet.capacity': 'aside',
    'fleet.support-authorizations': 'aside',
    'resources.summary': 'header',
    'messages.feed': 'aside',
    'buildings.grid': 'main',
    'research.grid': 'main',
    'shipyard.grid': 'main',
    'defense.grid': 'main',
    'galaxy.grid': 'main',
  },
  order: [
    'navigation.main',
    'planet.bodies',
    'fleet.command',
    'fleet.slots',
    'fleet.launch',
    'fleet.setup',
    'fleet.destination',
    'fleet.ships-civil',
    'fleet.ships-support',
    'fleet.ships-combat',
    'fleet.ships-other',
    'fleet.composition-note',
    'fleet.cargo',
    'fleet.active',
    'fleet.slot-summary',
    'fleet.capacity',
    'fleet.support-authorizations',
    'resources.summary',
    'messages.feed',
    'buildings.grid',
    'research.grid',
    'shipyard.grid',
    'defense.grid',
    'galaxy.grid',
  ],
  resizableTracks: ['aside'],
} satisfies UITemplate
