import type { UITemplate } from '../types'

/*
  TEMPLATE: MINIMAL
  Composición de dos bloques: contenido principal a la izquierda, panel único a
  la derecha. Sin rail, sin tiras, sin barras: el módulo manda y el template no
  compite con él. Densidad cómoda y tema monocromo (sin acento cromático).
  Es además el template de referencia para comprobar el apilado móvil: al
  colapsar sólo hay dos regiones y el orden DOM es el orden de lectura.

  Decide REGIÓN y ORDEN. La geometría vive en ui-engine.css.
*/
export const minimalTemplate = {
  id: 'minimal',
  label: 'Minimal',
  description: 'Dos bloques: contenido principal y panel único. Sin rail ni barras.',
  theme: 'monochrome',
  density: 'comfortable',
  regions: ['header', 'main', 'aside'],
  placement: {
    'fleet.command': 'header',
    'fleet.setup': 'main',
    'fleet.destination': 'main',
    'fleet.cargo': 'main',
    'fleet.ships-civil': 'main',
    'fleet.ships-support': 'main',
    'fleet.ships-combat': 'main',
    'fleet.ships-other': 'main',
    'fleet.composition-note': 'main',
    'fleet.launch': 'aside',
    'fleet.slots': 'aside',
    'fleet.slot-summary': 'aside',
    'fleet.capacity': 'aside',
    'fleet.support-authorizations': 'aside',
    'fleet.active': 'aside',
    'resources.summary': 'header',
    'buildings.grid': 'main',
    'research.grid': 'main',
    'shipyard.grid': 'main',
    'defense.grid': 'main',
    'galaxy.grid': 'main',
    'messages.feed': 'aside',
  },
  order: [
    'fleet.command',
    'resources.summary',
    'fleet.setup',
    'fleet.destination',
    'fleet.cargo',
    'buildings.grid',
    'research.grid',
    'shipyard.grid',
    'defense.grid',
    'galaxy.grid',
    'fleet.ships-civil',
    'fleet.ships-support',
    'fleet.ships-combat',
    'fleet.ships-other',
    'fleet.composition-note',
    'fleet.launch',
    'fleet.slots',
    'fleet.slot-summary',
    'fleet.capacity',
    'fleet.support-authorizations',
    'fleet.active',
    'messages.feed',
  ],
  resizableTracks: ['aside'],
} satisfies UITemplate
