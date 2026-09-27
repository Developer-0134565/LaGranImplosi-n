import type { UITemplate } from '../types'

/*
  TEMPLATE: INDUSTRIAL
  Consola de producción: cabecera de imperio a todo el ancho, rail de planta
  estrecho y redimensionable, columna de trabajo central, columna de colas a la
  derecha y registro a todo el ancho al pie.
  Densidad compacta, tema industrial (óxido/tungsteno), esquinas suaves.

  Decide REGIÓN y ORDEN. La geometría vive en ui-engine.css.
*/
export const industrialTemplate = {
  id: 'industrial',
  label: 'Industrial',
  description: 'Consola de producción: cabecera de imperio, rail de planta y registro al pie.',
  theme: 'industrial',
  density: 'compact',
  regions: ['header', 'rail', 'main', 'aside', 'log', 'actions'],
  placement: {
    'navigation.rail': 'rail',
    'navigation.main': 'main',
    'planet.bodies': 'aside',
    'fleet.command': 'header',
    'fleet.slots': 'header',
    'fleet.launch': 'header',
    'fleet.setup': 'rail',
    'fleet.capacity': 'rail',
    'fleet.slot-summary': 'rail',
    'fleet.support-authorizations': 'rail',
    'fleet.destination': 'main',
    'fleet.cargo': 'main',
    'fleet.ships-civil': 'main',
    'fleet.ships-support': 'main',
    'fleet.ships-combat': 'main',
    'fleet.ships-other': 'main',
    'fleet.composition-note': 'log',
    'fleet.active': 'aside',
    'resources.summary': 'header',
    'buildings.grid': 'main',
    'research.grid': 'main',
    'shipyard.grid': 'main',
    'defense.grid': 'aside',
    'galaxy.grid': 'main',
    'messages.feed': 'aside',
  },
  order: [
    'navigation.rail',
    'navigation.main',
    'planet.bodies',
    'fleet.command',
    'fleet.slots',
    'resources.summary',
    'fleet.launch',
    'fleet.setup',
    'fleet.capacity',
    'fleet.slot-summary',
    'fleet.support-authorizations',
    'fleet.destination',
    'fleet.cargo',
    'buildings.grid',
    'research.grid',
    'shipyard.grid',
    'galaxy.grid',
    'fleet.ships-civil',
    'fleet.ships-support',
    'fleet.ships-combat',
    'fleet.ships-other',
    'fleet.active',
    'defense.grid',
    'messages.feed',
    'fleet.composition-note',
  ],
  resizableTracks: ['rail', 'aside'],
} satisfies UITemplate
