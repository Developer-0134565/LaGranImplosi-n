import type { ReactNode } from 'react'

/*
  LGI UI ENGINE — CONTRACT TYPES

  Separación de capas:

      GAMEPLAY      (Supabase / RPC / hooks de dominio)   ← no conoce la UI
      GAME COMPONENTS  (módulos de presentación, id-neutral en posición)
      UI COMPOSITION   (UIEngineScreen coloca módulos en regiones)
      TEMPLATE         (decide REGIÓN + ORDEN + DENSIDAD + TEMA)
      THEME / TOKENS   (valores visuales centralizados)
      BROWSER

  Un módulo NUNCA conoce la posición que ocupa: sólo declara su id y su
  contenido. El template decide dónde vive y en qué orden.
*/

/** Templates del engine. */
export type UITemplateId = 'classic' | 'command' | 'tactical' | 'orbital' | 'industrial' | 'minimal'

/** Temas disponibles (overrides de color/radio/sombra, nunca de estructura). */
export type UIThemeId = 'nebula' | 'aurora' | 'tactical' | 'industrial' | 'monochrome'

/** Densidad: espaciado + escala tipográfica. */
export type UIDensity = 'comfortable' | 'compact' | 'dense'

/**
 * Regiones declarables por un template. Cada template decide cuáles usa y
 * cómo las dibuja (CSS grid areas). Un template puede ignorar las que no use.
 */
export const UI_REGION_IDS = [
  'header',
  'status',
  'rail',
  'main',
  'ops',
  'assets',
  'aside',
  'log',
  'actions',
] as const

export type UIRegionId = (typeof UI_REGION_IDS)[number]

export function isUIRegionId(value: unknown): value is UIRegionId {
  return typeof value === 'string' && (UI_REGION_IDS as readonly string[]).includes(value)
}

/** Dominios funcionales del juego (registry conceptual). */
export type UIDomainId =
  | 'resources'
  | 'planet'
  | 'navigation'
  | 'queues'
  | 'fleet'
  | 'buildings'
  | 'research'
  | 'shipyard'
  | 'defense'
  | 'galaxy'
  | 'messages'

/** Id de módulo: siempre `dominio.nombre` (`fleet.composition`). */
export type UIModuleId = `${UIDomainId}.${string}`

/** Declaración de un módulo reutilizable dentro del registry. */
export type UIModuleDefinition = {
  id: UIModuleId
  domain: UIDomainId
  label: string
  /** Descripción corta para el inspector DEV. */
  summary?: string
}

/** Mapa de módulos ya renderizados que una pantalla entrega al engine. */
export type UIModuleMap = Readonly<Partial<Record<UIModuleId, ReactNode>>>

/* ============================================================================
   BREAKPOINTS Y VARIANTES DE LAYOUT

   El breakpoint NO se decide por viewport: se deriva del ancho real medido del
   contenedor de pantalla (el mismo que gobierna las container queries). Así el
   preview de dispositivo del Designer es fiel: un marco estrecho activa el
   breakpoint pequeño, sin abrir un segundo sistema de layout.
   ========================================================================= */

export type UIBreakpointId = 'desktop' | 'tablet' | 'mobile'

/** Cortes de ancho de contenedor, alineados con ui-engine.css. */
export const UI_BREAKPOINTS: Readonly<Record<UIBreakpointId, { min: number; max: number }>> = {
  mobile: { min: 0, max: 760 },
  tablet: { min: 761, max: 1080 },
  desktop: { min: 1081, max: Number.POSITIVE_INFINITY },
}

export function isUIBreakpointId(value: unknown): value is UIBreakpointId {
  return value === 'desktop' || value === 'tablet' || value === 'mobile'
}

/** Breakpoint a partir del ancho medido del contenedor (0 = aún sin medir). */
export function breakpointForWidth(width: number): UIBreakpointId {
  if (width <= 0) return 'desktop'
  if (width <= UI_BREAKPOINTS.mobile.max) return 'mobile'
  if (width <= UI_BREAKPOINTS.tablet.max) return 'tablet'
  return 'desktop'
}

/** Pista de columna redimensionable de una región (px; nunca posición absoluta). */
export type UIRegionTrack = { min: number; max: number }

/**
 * Override declarativo de composición. NUNCA contiene píxeles de posición:
 * sólo región destino, orden, número de columnas internas de la región, span
 * del módulo y tamaño de la pista de columna que el CSS de la plantilla ya
 * declara como variable.
 */
export type UILayoutOverride = {
  placement?: Readonly<Partial<Record<UIModuleId, UIRegionId>>>
  order?: readonly UIModuleId[]
  moduleSpans?: Readonly<Partial<Record<UIModuleId, number>>>
  regionColumns?: Readonly<Partial<Record<UIRegionId, number>>>
  regionTracks?: Readonly<Partial<Record<UIRegionId, UIRegionTrack>>>
}

export type UITemplateLayoutVariants = Readonly<Partial<Record<UIBreakpointId, UILayoutOverride>>>

/**
 * Un template es DATO, no markup: declara región destino, orden, tema y
 * densidad. La geometría vive en `ui-engine.css` bajo
 * `.lgi-engine[data-lgi-template='<id>']`.
 */
export type UITemplate = {
  id: UITemplateId
  label: string
  description: string
  theme: UIThemeId
  density: UIDensity
  /** Regiones que el template dibuja, en orden de prioridad (y de apilado). */
  regions: readonly UIRegionId[]
  /** Colocación: módulo → región. Ausente ⇒ 'main'. */
  placement: Readonly<Partial<Record<UIModuleId, UIRegionId>>>
  /** Orden global dentro de cada región (los no listados van al final). */
  order: readonly UIModuleId[]
  /**
   * Regiones cuya pista de columna admite ajuste (`--lgi-track-<región>-min`
   * / `-max` en ui-engine.css). Sólo se declaran las que el CSS soporta.
   */
  resizableTracks?: readonly UIRegionId[]
}

/** Resolución efectiva del engine para un subárbol. */
export type UIEngineResolution = {
  template: UITemplate
  theme: UIThemeId
  density: UIDensity
}

/** Composición ya resuelta (template + variante de breakpoint + overrides). */
export type UIResolvedLayout = {
  regions: readonly UIRegionId[]
  placement: Readonly<Partial<Record<UIModuleId, UIRegionId>>>
  order: readonly UIModuleId[]
  moduleSpans: Readonly<Partial<Record<UIModuleId, number>>>
  regionColumns: Readonly<Partial<Record<UIRegionId, number>>>
  regionTracks: Readonly<Partial<Record<UIRegionId, UIRegionTrack>>>
}
