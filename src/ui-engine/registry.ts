import type { UIDomainId, UIModuleDefinition, UIModuleId } from './types'

/*
  COMPONENT REGISTRY (conceptual)

  Un módulo es una unidad de presentación con un id estable `dominio.nombre`.
  El template decide en qué región vive cada id; el módulo nunca conoce su
  posición. Añadir un dominio nuevo (buildings, research, shipyard, galaxy,
  messages…) consiste en registrar sus módulos y declararlos en el template:
  no requiere tocar los módulos ya existentes.
*/

/** Dominios del juego; cada uno prefija sus ids de módulo. */
export const UI_DOMAINS = {
  resources: 'Recursos del imperio',
  planet: 'Cuerpo activo (planeta o luna)',
  navigation: 'Navegación y jerarquía',
  queues: 'Colas de producción e investigación',
  fleet: 'Flotas: despacho, carga, movimientos',
  buildings: 'Edificios e instalaciones',
  research: 'Investigación',
  shipyard: 'Hangar y defensa',
  defense: 'Defensa planetaria',
  galaxy: 'Galaxia y exploración',
  messages: 'Mensajes e informes',
} as const satisfies Record<UIDomainId, string>

/** Id canónico de un módulo. */
export function moduleId(domain: UIDomainId, name: string): UIModuleId {
  return `${domain}.${name}`
}

/** Declaración de un módulo reutilizable. */
export function defineUIModule(
  domain: UIDomainId,
  name: string,
  label: string,
  summary?: string,
): UIModuleDefinition {
  return { id: moduleId(domain, name), domain, label, summary }
}

export type UIRegistry = {
  /** Módulos declarados, en orden de registro. */
  definitions: readonly UIModuleDefinition[]
  ids: readonly UIModuleId[]
  has: (id: UIModuleId) => boolean
  get: (id: UIModuleId) => UIModuleDefinition | null
}

/**
 * Registry de componentes. Es deliberadamente un mapa plano de metadatos: la
 * composición real (qué módulo va a qué región) la decide el template, no el
 * registry, para que no exista un segundo lugar donde se decida el layout.
 */
export function createUIRegistry(definitions: readonly UIModuleDefinition[]): UIRegistry {
  const byId = new Map<UIModuleId, UIModuleDefinition>()
  for (const definition of definitions) {
    if (byId.has(definition.id)) {
      throw new Error(`LGI UI Engine: módulo duplicado en el registry: ${definition.id}`)
    }
    byId.set(definition.id, definition)
  }
  return {
    definitions,
    ids: definitions.map((definition) => definition.id),
    has: (id: UIModuleId) => byId.has(id),
    get: (id: UIModuleId) => byId.get(id) ?? null,
  }
}

/**
 * Compone registries de varias pantallas/dominios en uno solo.
 *
 * Cada pantalla mantiene su propio registry (flota, referencia visual, futuros
 * dominios) y el engine puede inspeccionarlos juntos sin que ninguno conozca a
 * los demás. Los ids duplicados siguen siendo un error: dos pantallas no pueden
 * declarar el mismo módulo con contenidos distintos.
 */
export function mergeUIRegistries(...registries: readonly UIRegistry[]): UIRegistry {
  return createUIRegistry(registries.flatMap((registry) => registry.definitions))
}
