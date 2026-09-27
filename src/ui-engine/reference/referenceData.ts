import type { UIDomainId, UIModuleId } from '../types'
import { UI_REFERENCE_ASSETS, type UIAssetDefinition } from './referenceAssets'

/*
  UI ENGINE — DATOS DE DEMOSTRACIÓN DE LOS GRIDS DE REFERENCIA

  IMPORTANTE: esto NO es gameplay. Son datos inventados y deterministas cuyo
  único propósito es comprobar cómo se ve un grid con imagen + nombre + nivel +
  estado dentro de cada template y en cada perfil de dispositivo.

  Ninguna pantalla real importa este archivo: vive en la superficie DEV
  (`UIWorkbench`).
*/

export type UIReferenceItem = {
  /** Id del asset de referencia (`buildings.metal-mine`). */
  assetId: string
  label: string
  /** Nivel (edificios/investigación). */
  level?: number
  /** Unidades (hangar/defensa). */
  quantity?: number
  /** Estado corto, sólo informativo. */
  status: string
  tone: 'default' | 'accent' | 'ok' | 'warn' | 'danger'
  /** Línea de detalle bajo el nombre. */
  detail: string
}

export type UIReferenceDeck = {
  id: string
  label: string
  /** Módulo del registry que dibuja este deck (el template decide su región). */
  moduleId: UIModuleId
  domain: UIDomainId
  title: string
  /** Etiqueta de la métrica de la tarjeta (NIVEL / UNIDADES / …). */
  metric: string
  items: readonly UIReferenceItem[]
  note: string
}

/** Valores deterministas: el deck se ve igual en cada carga. */
function demoValue(index: number, base: number): number {
  return base + ((index * 7) % 19)
}

const TONES: readonly UIReferenceItem['tone'][] = ['ok', 'accent', 'default', 'warn', 'danger']

function itemsOf(domain: string, metric: 'level' | 'quantity'): UIReferenceItem[] {
  return UI_REFERENCE_ASSETS.filter((asset) => asset.domain === domain).map((asset, index) => {
    const value = demoValue(index, metric === 'level' ? 6 : 24)
    return {
      assetId: asset.id,
      label: asset.label,
      level: metric === 'level' ? value : undefined,
      quantity: metric === 'quantity' ? value : undefined,
      status: index % 4 === 3 ? 'EN COLA' : 'LISTO',
      tone: TONES[index % TONES.length],
      detail: `REFERENCE · ${asset.id}`,
    } satisfies UIReferenceItem
  })
}

function staticItems(
  domain: string,
  build: (asset: UIAssetDefinition, index: number) => Omit<UIReferenceItem, 'assetId' | 'label'>,
): UIReferenceItem[] {
  return UI_REFERENCE_ASSETS.filter((asset) => asset.domain === domain).map((asset, index) => ({
    assetId: asset.id,
    label: asset.label,
    ...build(asset, index),
  }))
}

const BASE_DECKS: readonly UIReferenceDeck[] = [
  {
    id: 'buildings',
    label: 'BUILDINGS',
    moduleId: 'buildings.grid',
    domain: 'buildings',
    title: 'Edificios e instalaciones',
    metric: 'NIVEL',
    items: itemsOf('buildings', 'level'),
    note: 'Grid de edificios: imagen, nombre, nivel y estado. Sin colas ni costes reales.',
  },
  {
    id: 'research',
    label: 'RESEARCH',
    moduleId: 'research.grid',
    domain: 'research',
    title: 'Investigación',
    metric: 'NIVEL',
    items: itemsOf('research', 'level'),
    note: 'Grid de investigación: mismo contrato visual que edificios, otro dominio.',
  },
  {
    id: 'shipyard',
    label: 'SHIPYARD',
    moduleId: 'shipyard.grid',
    domain: 'shipyard',
    title: 'Hangar',
    metric: 'UNIDADES',
    items: itemsOf('shipyard', 'quantity'),
    note: 'Grid de naves: la métrica pasa a unidades y la tarjeta no cambia de forma.',
  },
  {
    id: 'defense',
    label: 'DEFENSE',
    moduleId: 'defense.grid',
    domain: 'defense',
    title: 'Defensa planetaria',
    metric: 'UNIDADES',
    items: itemsOf('defense', 'quantity'),
    note: 'Grid de defensa: misma tarjeta, otro dominio declarado en el registry.',
  },
]

const EXTRA_DECKS: readonly UIReferenceDeck[] = [
  {
    id: 'resources',
    label: 'RESOURCES',
    moduleId: 'resources.summary',
    domain: 'resources',
    title: 'Recursos',
    metric: 'DISPONIBLE',
    items: staticItems('resources', (asset, index) => ({
      quantity: demoValue(index, 120_000),
      status: index === 3 ? 'DÉFICIT' : 'ESTABLE',
      tone: index === 3 ? 'warn' : 'accent',
      detail: `Almacén · ${asset.id}`,
    })),
    note: 'Resumen de recursos con tarjeta de asset: comprueba la densidad en un rail estrecho.',
  },
  {
    id: 'fleet',
    label: 'FLEET',
    moduleId: 'fleet.composition',
    domain: 'fleet',
    title: 'Composición de flota',
    metric: 'NAVES',
    items: staticItems('fleet', (asset, index) => ({
      quantity: demoValue(index, 12),
      status: index % 3 === 0 ? 'EN VUELO' : 'EN TIERRA',
      tone: index % 3 === 0 ? 'accent' : 'ok',
      detail: `Misión · ${asset.id}`,
    })),
    note: 'Composición de flota como grid: el mismo patrón que la pantalla real de flotas.',
  },
  {
    id: 'planets',
    label: 'PLANETS',
    moduleId: 'planet.summary',
    domain: 'planet',
    title: 'Cuerpos en posesión',
    metric: 'CAMPOS',
    items: staticItems('planets', (asset, index) => ({
      level: demoValue(index, 118),
      status: index === 1 ? 'EN CONSTRUCCIÓN' : 'ESTABLE',
      tone: index === 1 ? 'warn' : 'default',
      detail: `Cuerpo · ${asset.id}`,
    })),
    note: 'Planetas y lunas con asset de referencia: grid en columnas estrechas.',
  },
  {
    id: 'galaxy',
    label: 'GALAXY',
    moduleId: 'galaxy.grid',
    domain: 'galaxy',
    title: 'Galaxia',
    metric: 'POSICIÓN',
    items: staticItems('galaxy', (asset, index) => ({
      quantity: index + 1,
      status: asset.name.includes('occupied') ? 'OCUPADA' : 'LIBRE',
      tone: asset.name.includes('occupied') ? 'danger' : 'ok',
      detail: `Slot [1:${200 + index}:${index + 1}] · ${asset.id}`,
    })),
    note: 'Sistema y posiciones: primer paso hacia una galaxia con assets, sin datos reales.',
  },
  {
    id: 'messages',
    label: 'MESSAGES',
    moduleId: 'messages.feed',
    domain: 'messages',
    title: 'Informes',
    metric: 'HACE',
    items: staticItems('messages', (asset, index) => ({
      quantity: index + 1,
      status: index === 0 ? 'SIN LEER' : 'LEÍDO',
      tone: index === 0 ? 'accent' : 'default',
      detail: `Informe · ${asset.id}`,
    })),
    note: 'Informes como grid de assets: comprueba que el patrón aguanta un dominio más.',
  },
]

export const UI_REFERENCE_DECKS: readonly UIReferenceDeck[] = [...BASE_DECKS, ...EXTRA_DECKS]

export function getUIReferenceDeck(id: string): UIReferenceDeck {
  return UI_REFERENCE_DECKS.find((deck) => deck.id === id) ?? UI_REFERENCE_DECKS[0]
}

/** Todos los módulos de referencia, para el deck "ALL" del banco de pruebas. */
export const UI_REFERENCE_MODULE_IDS: readonly UIModuleId[] = UI_REFERENCE_DECKS.map(
  (deck) => deck.moduleId,
)

