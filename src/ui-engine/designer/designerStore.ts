import { useSyncExternalStore } from 'react'
import { DEFAULT_UI_TEMPLATE_ID, getUITemplate, isUITemplateId } from '../templates'
import {
  isUIBreakpointId,
  isUIRegionId,
  type UIBreakpointId,
  type UIDensity,
  type UILayoutOverride,
  type UIModuleId,
  type UIResolvedLayout,
  type UIRegionId,
  type UIRegionTrack,
  type UITemplate,
  type UITemplateId,
  type UIThemeId,
} from '../types'
import { DEFAULT_UI_DEVICE_PROFILE_ID, isUIDeviceProfileId } from './deviceProfiles'
import {
  DEFAULT_UI_FONT_ID,
  UI_FONT_SCALE_MAX,
  UI_FONT_SCALE_MIN,
  UI_UI_SCALE_MAX,
  UI_UI_SCALE_MIN,
  getUIFontOption,
} from './typography'

/*
  UI DESIGNER — ESTADO Y MODELO DE LAYOUT

  Este módulo es la ÚNICA fuente de configuración del Designer:

    * config    → preferencia del diseñador (template, tipografía y escalas,
                  densidad, tema, perfil de dispositivo, capas DEV y variantes
                  de layout por breakpoint). Persistida en localStorage y
                  versionada.
    * selection → módulo seleccionado en modo edición (memoria, no persistente).

  REGLAS DE DISEÑO (deliberadas):

    * El modelo NUNCA guarda píxeles de POSICIÓN. Guarda región destino, orden,
      columnas internas de región, span del módulo y tamaño de la pista de
      columna que el CSS del template ya expone como variable.
    * Se guarda por template y por breakpoint: `layouts[template][bp]`.
    * Un breakpoint sin override usa la declaración del template tal cual.
    * Nada de esto toca gameplay, Supabase, RPC ni sesión.
*/

export const UI_DESIGNER_STORAGE_KEY = 'lagranimplosion-ui-designer'
export const UI_DESIGNER_CONFIG_VERSION = 1

/** Límites de la rejilla interna que el Designer puede ajustar. */
export const UI_MODULE_SPAN_MIN = 1
export const UI_MODULE_SPAN_MAX = 4
export const UI_REGION_COLUMNS_MIN = 1
export const UI_REGION_COLUMNS_MAX = 4
export const UI_REGION_TRACK_MIN = 120
export const UI_REGION_TRACK_MAX = 560

export type UILayoutOverrideMap = Readonly<
  Partial<Record<UITemplateId, Readonly<Partial<Record<UIBreakpointId, UILayoutOverride>>>>>
>

export type UIDesignerConfig = {
  version: number
  /** Template que el Designer está editando (sincronizado con el engine). */
  template: UITemplateId
  /** `null` = usar el tema del template. */
  theme: UIThemeId | null
  /** `null` = usar la densidad del template. */
  density: UIDensity | null
  fontId: string
  fontScale: number
  uiScale: number
  deviceProfile: string
  grid: boolean
  boundaries: boolean
  safeArea: boolean
  editMode: boolean
  /** Breakpoint cuya variante se está editando. */
  breakpoint: UIBreakpointId
  layouts: UILayoutOverrideMap
}

export type UIDesignerSelection = {
  screen: string
  moduleId: UIModuleId
}

export type UIDesignerState = {
  config: UIDesignerConfig
  saved: UIDesignerConfig
  dirty: boolean
  selection: UIDesignerSelection | null
}

export function defaultUIDesignerConfig(): UIDesignerConfig {
  return {
    version: UI_DESIGNER_CONFIG_VERSION,
    template: DEFAULT_UI_TEMPLATE_ID,
    theme: null,
    density: null,
    fontId: DEFAULT_UI_FONT_ID,
    fontScale: 1,
    uiScale: 1,
    deviceProfile: DEFAULT_UI_DEVICE_PROFILE_ID,
    grid: false,
    boundaries: false,
    safeArea: false,
    editMode: false,
    breakpoint: 'desktop',
    layouts: {},
  }
}

function clamp(value: number, min: number, max: number): number {
  if (!Number.isFinite(value)) return min
  return Math.min(max, Math.max(min, value))
}

function scale(value: unknown, min: number, max: number, fallback: number): number {
  const parsed = typeof value === 'number' ? value : Number(value)
  if (!Number.isFinite(parsed)) return fallback
  return Math.round(clamp(parsed, min, max) * 100) / 100
}

const DENSITIES: readonly UIDensity[] = ['comfortable', 'compact', 'dense']
const THEMES: readonly UIThemeId[] = ['nebula', 'aurora', 'tactical', 'industrial', 'monochrome']


function sanitizeTrack(value: unknown): UIRegionTrack | null {
  if (!value || typeof value !== 'object') return null
  const raw = value as Partial<UIRegionTrack>
  const min = clamp(Number(raw.min), UI_REGION_TRACK_MIN, UI_REGION_TRACK_MAX)
  const max = clamp(Number(raw.max), UI_REGION_TRACK_MIN, UI_REGION_TRACK_MAX)
  if (!Number.isFinite(min) || !Number.isFinite(max)) return null
  return min <= max ? { min, max } : { min: max, max: min }
}

type SanitizedOverrideDraft = {
  placement?: Record<string, UIRegionId>
  order?: UIModuleId[]
  moduleSpans?: Record<string, number>
  regionColumns?: Record<string, number>
  regionTracks?: Record<string, UIRegionTrack>
}

function sanitizeOverride(value: unknown): UILayoutOverride | null {
  if (!value || typeof value !== 'object') return null
  const raw = value as UILayoutOverride
  const override: SanitizedOverrideDraft = {}

  if (raw.placement && typeof raw.placement === 'object') {
    const placement: Record<string, UIRegionId> = {}
    for (const [moduleId, region] of Object.entries(raw.placement)) {
      if (isUIRegionId(region)) placement[moduleId] = region
    }
    if (Object.keys(placement).length > 0) override.placement = placement
  }
  if (Array.isArray(raw.order)) {
    const order = raw.order.filter((id): id is UIModuleId => typeof id === 'string')
    if (order.length > 0) override.order = order
  }
  if (raw.moduleSpans && typeof raw.moduleSpans === 'object') {
    const spans: Record<string, number> = {}
    for (const [moduleId, span] of Object.entries(raw.moduleSpans)) {
      const parsed = Math.round(Number(span))
      if (Number.isFinite(parsed)) {
        spans[moduleId] = clamp(parsed, UI_MODULE_SPAN_MIN, UI_MODULE_SPAN_MAX)
      }
    }
    if (Object.keys(spans).length > 0) override.moduleSpans = spans
  }
  if (raw.regionColumns && typeof raw.regionColumns === 'object') {
    const columns: Record<string, number> = {}
    for (const [region, value] of Object.entries(raw.regionColumns)) {
      const parsed = Math.round(Number(value))
      if (isUIRegionId(region) && Number.isFinite(parsed)) {
        columns[region] = clamp(parsed, UI_REGION_COLUMNS_MIN, UI_REGION_COLUMNS_MAX)
      }
    }
    if (Object.keys(columns).length > 0) override.regionColumns = columns
  }
  if (raw.regionTracks && typeof raw.regionTracks === 'object') {
    const tracks: Record<string, UIRegionTrack> = {}
    for (const [region, track] of Object.entries(raw.regionTracks)) {
      const sanitized = sanitizeTrack(track)
      if (isUIRegionId(region) && sanitized) tracks[region] = sanitized
    }
    if (Object.keys(tracks).length > 0) override.regionTracks = tracks
  }

  return Object.keys(override).length > 0 ? override : null
}

/** Sanea TODO lo que llega de localStorage: nunca se confía en el almacén. */
export function sanitizeUIDesignerConfig(value: unknown): UIDesignerConfig {
  const defaults = defaultUIDesignerConfig()
  if (!value || typeof value !== 'object') return defaults
  const raw = value as Partial<UIDesignerConfig>

  const layouts: Record<string, Partial<Record<UIBreakpointId, UILayoutOverride>>> = {}
  if (raw.layouts && typeof raw.layouts === 'object') {
    for (const [templateId, variants] of Object.entries(raw.layouts)) {
      if (!isUITemplateId(templateId) || !variants || typeof variants !== 'object') continue
      const bucket: Partial<Record<UIBreakpointId, UILayoutOverride>> = {}
      for (const [breakpoint, override] of Object.entries(variants)) {
        if (!isUIBreakpointId(breakpoint)) continue
        const sanitized = sanitizeOverride(override)
        if (sanitized) bucket[breakpoint] = sanitized
      }
      if (Object.keys(bucket).length > 0) layouts[templateId] = bucket
    }
  }

  const theme = typeof raw.theme === 'string' && THEMES.includes(raw.theme as UIThemeId)
    ? (raw.theme as UIThemeId)
    : null
  const density = typeof raw.density === 'string' && DENSITIES.includes(raw.density as UIDensity)
    ? (raw.density as UIDensity)
    : null

  return {
    version: UI_DESIGNER_CONFIG_VERSION,
    template: isUITemplateId(raw.template) ? raw.template : defaults.template,
    theme,
    density,
    fontId: getUIFontOption(raw.fontId) ? (raw.fontId as string) : defaults.fontId,
    fontScale: scale(raw.fontScale, UI_FONT_SCALE_MIN, UI_FONT_SCALE_MAX, 1),
    uiScale: scale(raw.uiScale, UI_UI_SCALE_MIN, UI_UI_SCALE_MAX, 1),
    deviceProfile: isUIDeviceProfileId(raw.deviceProfile) ? raw.deviceProfile : defaults.deviceProfile,
    grid: raw.grid === true,
    boundaries: raw.boundaries === true,
    safeArea: raw.safeArea === true,
    editMode: raw.editMode === true,
    breakpoint: isUIBreakpointId(raw.breakpoint) ? raw.breakpoint : 'desktop',
    layouts,
  }
}

function readStoredConfig(): UIDesignerConfig {
  try {
    const stored = localStorage.getItem(UI_DESIGNER_STORAGE_KEY)
    if (!stored) return defaultUIDesignerConfig()
    return sanitizeUIDesignerConfig(JSON.parse(stored))
  } catch {
    return defaultUIDesignerConfig()
  }
}

function persistConfig(config: UIDesignerConfig) {
  try {
    localStorage.setItem(UI_DESIGNER_STORAGE_KEY, JSON.stringify(config))
  } catch {
    /* almacenamiento no disponible: la configuración vive sólo en memoria */
  }
}

function clearStoredConfig() {
  try {
    localStorage.removeItem(UI_DESIGNER_STORAGE_KEY)
  } catch {
    /* noop */
  }
}

const initialConfig = readStoredConfig()

let state: UIDesignerState = {
  config: initialConfig,
  saved: initialConfig,
  dirty: false,
  selection: null,
}

const listeners = new Set<() => void>()

function notify() {
  for (const listener of listeners) listener()
}

/** Aplica un cambio de estado y recalcula `dirty` (config !== saved). */
function commit(patch: {
  config?: UIDesignerConfig
  saved?: UIDesignerConfig
  selection?: UIDesignerSelection | null
}) {
  const config = patch.config ?? state.config
  const saved = patch.saved ?? state.saved
  state = {
    config,
    saved,
    dirty: config !== saved,
    selection: patch.selection !== undefined ? patch.selection : state.selection,
  }
  notify()
}

export function subscribeUIDesigner(listener: () => void) {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

export function getUIDesignerState(): UIDesignerState {
  return state
}

export function useUIDesignerState(): UIDesignerState {
  return useSyncExternalStore(subscribeUIDesigner, getUIDesignerState, getUIDesignerState)
}

export function useUIDesignerConfig(): UIDesignerConfig {
  return useUIDesignerState().config
}

export function useUIDesignerSelection(): UIDesignerSelection | null {
  return useUIDesignerState().selection
}

/** Cambio de configuración (en memoria: persistir es `saveUIDesigner`). */
export function updateUIDesignerConfig(patch: Partial<UIDesignerConfig>) {
  commit({ config: { ...state.config, ...patch } })
}

export function setUIDesignerTemplate(id: UITemplateId) {
  updateUIDesignerConfig({ template: id })
}

export function setUIDesignerFont(id: string) {
  updateUIDesignerConfig({ fontId: getUIFontOption(id) ? id : DEFAULT_UI_FONT_ID })
}

export function setUIDesignerFontScale(value: number) {
  updateUIDesignerConfig({ fontScale: scale(value, UI_FONT_SCALE_MIN, UI_FONT_SCALE_MAX, 1) })
}

export function setUIDesignerUiScale(value: number) {
  updateUIDesignerConfig({ uiScale: scale(value, UI_UI_SCALE_MIN, UI_UI_SCALE_MAX, 1) })
}

export function setUIDesignerDensity(value: UIDensity | null) {
  updateUIDesignerConfig({ density: value })
}

export function setUIDesignerTheme(value: UIThemeId | null) {
  updateUIDesignerConfig({ theme: value })
}

export function setUIDesignerDeviceProfile(id: string) {
  updateUIDesignerConfig({
    deviceProfile: isUIDeviceProfileId(id) ? id : DEFAULT_UI_DEVICE_PROFILE_ID,
  })
}

export function setUIDesignerBreakpoint(id: UIBreakpointId) {
  updateUIDesignerConfig({ breakpoint: id })
}

export function selectUIDesignerModule(selection: UIDesignerSelection | null) {
  const same =
    selection === state.selection ||
    (selection !== null &&
      state.selection !== null &&
      selection.screen === state.selection.screen &&
      selection.moduleId === state.selection.moduleId)
  if (same) return
  commit({ selection })
}


/* ============================================================================
   MODELO DE LAYOUT
   ========================================================================= */

const EMPTY_OVERRIDE: UILayoutOverride = {}

/** Override declarado para template + breakpoint (vacío si no hay ninguno). */
export function getUIDesignerOverride(
  templateId: UITemplateId,
  breakpoint: UIBreakpointId,
): UILayoutOverride {
  return state.config.layouts[templateId]?.[breakpoint] ?? EMPTY_OVERRIDE
}

/** ¿Este template tiene alguna variante guardada en algún breakpoint? */
export function hasUIDesignerLayout(templateId: UITemplateId): boolean {
  const variants = state.config.layouts[templateId]
  if (!variants) return false
  return Object.keys(variants).some((key) => isUIBreakpointId(key))
}

/** Composición efectiva: template + override del breakpoint. */
export function resolveUILayout(
  template: UITemplate,
  override: UILayoutOverride | null | undefined,
): UIResolvedLayout {
  const placement = override?.placement
    ? { ...template.placement, ...override.placement }
    : template.placement
  return {
    regions: template.regions,
    placement,
    order: override?.order && override.order.length > 0 ? override.order : template.order,
    moduleSpans: override?.moduleSpans ?? {},
    regionColumns: override?.regionColumns ?? {},
    regionTracks: override?.regionTracks ?? {},
  }
}

/** Layout resuelto para un template + breakpoint (lo consume UIEngineScreen). */
export function resolveUIDesignerLayout(
  template: UITemplate,
  breakpoint: UIBreakpointId,
): UIResolvedLayout {
  return resolveUILayout(template, getUIDesignerOverride(template.id, breakpoint))
}

/** Región efectiva de un módulo (para mover, redimensionar y ordenar). */
export function getUIModuleRegion(
  template: UITemplate,
  breakpoint: UIBreakpointId,
  moduleId: UIModuleId,
): UIRegionId {
  const override = getUIDesignerOverride(template.id, breakpoint)
  const placement = { ...template.placement, ...(override.placement ?? {}) }
  const region = placement[moduleId] ?? 'main'
  return template.regions.includes(region) ? region : template.regions[0]
}

type MutableOverride = {
  placement: Record<string, UIRegionId | undefined>
  order: UIModuleId[]
  moduleSpans: Record<string, number | undefined>
  regionColumns: Record<string, number | undefined>
  regionTracks: Record<string, UIRegionTrack | undefined>
}

/** Escribe en la variante activa del template activo, podando lo que quede vacío. */
function writeOverride(mutate: (draft: MutableOverride) => void) {
  const { template, breakpoint, layouts } = state.config
  const current = layouts[template]?.[breakpoint]
  const draft: MutableOverride = {
    placement: { ...(current?.placement ?? {}) },
    order: [...(current?.order ?? [])],
    moduleSpans: { ...(current?.moduleSpans ?? {}) },
    regionColumns: { ...(current?.regionColumns ?? {}) },
    regionTracks: { ...(current?.regionTracks ?? {}) },
  }
  mutate(draft)

  const next: MutableOverride = draft
  const hasEntries =
    Object.keys(next.placement).length > 0 ||
    next.order.length > 0 ||
    Object.keys(next.moduleSpans).length > 0 ||
    Object.keys(next.regionColumns).length > 0 ||
    Object.keys(next.regionTracks).length > 0

  const variants = { ...(layouts[template] ?? {}) }
  if (hasEntries) variants[breakpoint] = next as UILayoutOverride
  else delete variants[breakpoint]

  const nextLayouts = { ...layouts }
  if (Object.keys(variants).length === 0) delete nextLayouts[template]
  else nextLayouts[template] = variants

  updateUIDesignerConfig({ layouts: nextLayouts })
}

/** Orden efectivo (base + overrides) del template activo. */
export function effectiveUIDesignerOrder(template: UITemplate, breakpoint: UIBreakpointId): UIModuleId[] {
  const override = getUIDesignerOverride(template.id, breakpoint)
  return override.order && override.order.length > 0 ? [...override.order] : [...template.order]
}

/**
 * MOVE: cambia el módulo de región y lo recoloca justo detrás del último
 * módulo que ya vive en esa región (orden de lectura estable).
 */
export function moveUIDesignerModule(moduleId: UIModuleId, region: UIRegionId) {
  const template = activeDesignerTemplate()
  if (!template.regions.includes(region)) return
  writeOverride((draft) => {
    draft.placement[moduleId] = region
    const base = draft.order.length > 0 ? draft.order : [...template.order]
    const placement: Record<string, UIRegionId | undefined> = {
      ...template.placement,
      ...draft.placement,
    }
    const without = base.filter((id) => id !== moduleId)
    let insertAt = without.length
    for (let index = without.length - 1; index >= 0; index -= 1) {
      if ((placement[without[index]] ?? 'main') === region) {
        insertAt = index + 1
        break
      }
    }
    without.splice(insertAt, 0, moduleId)
    draft.order = without

    const columns = draft.regionColumns[region] ?? UI_REGION_COLUMNS_MIN
    const span = draft.moduleSpans[moduleId]
    if (span !== undefined && span > columns) draft.moduleSpans[moduleId] = columns
  })
}

/** RESIZE (módulo): span dentro de la rejilla interna de su región. */
export function setUIDesignerModuleSpan(moduleId: UIModuleId, span: number) {
  const template = activeDesignerTemplate()
  const breakpoint = state.config.breakpoint
  writeOverride((draft) => {
    const next = clamp(Math.round(span), UI_MODULE_SPAN_MIN, UI_MODULE_SPAN_MAX)
    const region = getUIModuleRegion(template, breakpoint, moduleId)
    draft.moduleSpans[moduleId] = next
    const columns = draft.regionColumns[region] ?? UI_REGION_COLUMNS_MIN
    /** Subir el span por encima de las columnas habilita la rejilla interna:
     *  sin esto el span no tendría efecto y parecería que el control no hace nada. */
    if (next > columns) draft.regionColumns[region] = next
  })
}

/** RESIZE (región): columnas internas. 1 = vuelve al apilado flex del contrato. */
export function setUIDesignerRegionColumns(region: UIRegionId, columns: number) {
  writeOverride((draft) => {
    const next = clamp(Math.round(columns), UI_REGION_COLUMNS_MIN, UI_REGION_COLUMNS_MAX)
    if (next === UI_REGION_COLUMNS_MIN) delete draft.regionColumns[region]
    else draft.regionColumns[region] = next
    const limit = next === UI_REGION_COLUMNS_MIN ? UI_MODULE_SPAN_MIN : next
    for (const moduleId of Object.keys(draft.moduleSpans) as UIModuleId[]) {
      if (getUIModuleRegion(activeDesignerTemplate(), state.config.breakpoint, moduleId) !== region) continue
      const span = draft.moduleSpans[moduleId]
      if (span !== undefined && span > limit) draft.moduleSpans[moduleId] = limit
    }
  })
}

/** RESIZE (región): pista de columna. Sólo para regiones `resizableTracks`. */
export function setUIDesignerRegionTrack(region: UIRegionId, track: UIRegionTrack) {
  writeOverride((draft) => {
    const min = Math.round(clamp(track.min, UI_REGION_TRACK_MIN, UI_REGION_TRACK_MAX))
    const max = Math.round(clamp(track.max, UI_REGION_TRACK_MIN, UI_REGION_TRACK_MAX))
    draft.regionTracks[region] = min <= max ? { min, max } : { min: max, max: min }
  })
}

/** Reordena un módulo dentro de su región (paso -1 / +1 en el orden global). */
export function moveUIDesignerModuleOrder(moduleId: UIModuleId, direction: -1 | 1) {
  const template = activeDesignerTemplate()
  writeOverride((draft) => {
    const order = draft.order.length > 0 ? draft.order : [...template.order]
    if (!order.includes(moduleId)) order.push(moduleId)
    const from = order.indexOf(moduleId)
    const to = from + direction
    if (to < 0 || to >= order.length) return
    const [moved] = order.splice(from, 1)
    order.splice(to, 0, moved)
    draft.order = order
  })
}

/** Copia la variante de escritorio al breakpoint activo (punto de partida). */
export function copyUIDesignerLayoutFromDesktop() {
  const { template, breakpoint, layouts } = state.config
  const desktop = layouts[template]?.desktop
  if (!desktop) return
  const variants = { ...(layouts[template] ?? {}) }
  variants[breakpoint] = desktop
  updateUIDesignerConfig({ layouts: { ...layouts, [template]: variants } })
}

/** Borra la variante del breakpoint activo. */
export function clearUIDesignerVariant() {
  const { template, breakpoint, layouts } = state.config
  if (!layouts[template]?.[breakpoint]) return
  const variants = { ...layouts[template] }
  delete variants[breakpoint]
  const nextLayouts = { ...layouts }
  if (Object.keys(variants).length === 0) delete nextLayouts[template]
  else nextLayouts[template] = variants
  updateUIDesignerConfig({ layouts: nextLayouts })
}

/** Borra TODAS las variantes del template activo (vuelve a su declaración). */
export function resetUIDesignerTemplateLayout() {
  const { template, layouts } = state.config
  const nextLayouts = { ...layouts }
  delete nextLayouts[template]
  updateUIDesignerConfig({ layouts: nextLayouts })
}

/** Persiste la configuración (localStorage). Sin efectos fuera del engine. */
export function saveUIDesigner() {
  const config = state.config
  persistConfig(config)
  commit({ config, saved: config })
}

/** Descarta los cambios no guardados (vuelve al último guardado). */
export function discardUIDesignerChanges() {
  commit({ config: state.saved })
}

/** Restaurar defaults del Designer. NO borra otras claves de localStorage. */
export function resetUIDesigner(): UIDesignerConfig {
  clearStoredConfig()
  const config = defaultUIDesignerConfig()
  commit({ config, saved: config, selection: null })
  return config
}

/** Template activo del Designer (el que se está editando). */
export function activeDesignerTemplate(): UITemplate {
  return getUITemplate(state.config.template)
}


/** Interruptores DEV del Designer (capas visuales y modo edición). */
export type UIDesignerFlagKey = 'grid' | 'boundaries' | 'safeArea' | 'editMode'

export function setUIDesignerFlag(key: UIDesignerFlagKey, value: boolean) {
  if (key === 'grid') updateUIDesignerConfig({ grid: value })
  else if (key === 'boundaries') updateUIDesignerConfig({ boundaries: value })
  else if (key === 'safeArea') updateUIDesignerConfig({ safeArea: value })
  else updateUIDesignerConfig({ editMode: value })
}

