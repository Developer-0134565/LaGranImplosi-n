import { createUIRegistry, defineUIModule } from '../registry'
import type { UIDomainId, UIModuleId } from '../types'
import { UI_REFERENCE_DECKS, type UIReferenceDeck } from './referenceData'

/*
  UI ENGINE — REGISTRY DE REFERENCIA (DEV)

  Cada deck declara su módulo (`dominio.nombre`) con el mismo mecanismo que
  cualquier pantalla real, así que añadir un dominio visual nuevo es añadir un
  deck y su carpeta de assets: no hay que tocar el engine.
*/

function definitionOf(deck: UIReferenceDeck) {
  const [domain, name] = deck.moduleId.split('.') as [UIDomainId, string]
  return defineUIModule(domain, name, deck.title, `${deck.metric} · datos de demostración (DEV).`)
}

export const referenceModuleIds: Record<string, UIModuleId> = Object.fromEntries(
  UI_REFERENCE_DECKS.map((deck) => [deck.id, deck.moduleId]),
)

export const referenceRegistry = createUIRegistry([
  ...UI_REFERENCE_DECKS.map(definitionOf),
  defineUIModule('navigation', 'hierarchy', 'Jerarquía', 'Sistema → posiciones (DEV).'),
  defineUIModule('queues', 'summary', 'Colas', 'Resumen de colas de producción (DEV).'),
])
