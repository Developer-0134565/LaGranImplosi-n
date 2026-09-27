import { createContext, useContext } from 'react'
import type {
  UIDensity,
  UIEngineResolution,
  UIThemeId,
  UITemplate,
  UITemplateId,
  UIRegionId,
} from './types'

/*
  Contexto del UI Engine.

  El engine NO conoce Supabase, ni el gameplay, ni la sesión: sólo resuelve
  template + tema + densidad y expone la región actual a los componentes.
*/

export const UI_TEMPLATE_STORAGE_KEY = 'lagranimplosion-ui-template'
export const UI_TEMPLATE_SWITCHER_STORAGE_KEY = 'lagranimplosion-ui-template-switcher'

export type UIEngineContextValue = {
  templateId: UITemplateId
  template: UITemplate
  setTemplateId: (id: UITemplateId) => void
  /** El switcher DEV es visible salvo que se desactive explícitamente. */
  switcherVisible: boolean
  setSwitcherVisible: (visible: boolean) => void
}

/** Región en la que se está renderizando un módulo (adaptabilidad contextual). */
export type UIRegionContextValue = {
  region: UIRegionId
  templateId: UITemplateId
  density: UIDensity
  theme: UIThemeId
}

export const UIEngineContext = createContext<UIEngineContextValue | null>(null)
export const UIRegionContext = createContext<UIRegionContextValue | null>(null)
/** Resolución efectiva (template + tema + densidad) que publica cada <UIEngine>. */
export const UIResolutionContext = createContext<UIEngineResolution | null>(null)

/** Lectura tolerante: devuelve null si no hay provider (render fuera del engine). */
export function readStoredTemplate(): string | null {
  try {
    return localStorage.getItem(UI_TEMPLATE_STORAGE_KEY)
  } catch {
    return null
  }
}

export function persistTemplate(id: UITemplateId) {
  try {
    localStorage.setItem(UI_TEMPLATE_STORAGE_KEY, id)
  } catch {
    /* almacenamiento no disponible: la preferencia vive sólo en memoria */
  }
}

export function readStoredSwitcher(): boolean {
  try {
    return localStorage.getItem(UI_TEMPLATE_SWITCHER_STORAGE_KEY) !== 'off'
  } catch {
    return true
  }
}

export function persistSwitcher(visible: boolean) {
  try {
    localStorage.setItem(UI_TEMPLATE_SWITCHER_STORAGE_KEY, visible ? 'on' : 'off')
  } catch {
    /* noop */
  }
}

export function useUIEngineContext(): UIEngineContextValue {
  const value = useContext(UIEngineContext)
  if (!value) {
    throw new Error('useUIEngineContext debe usarse dentro de <UIEngineProvider>.')
  }
  return value
}

export function useOptionalUIEngineContext(): UIEngineContextValue | null {
  return useContext(UIEngineContext)
}

/** Template activo. */
export function useUITemplate(): UITemplate {
  return useUIEngineContext().template
}

/** Densidad activa (tokens `--lgi-space-*` / `--lgi-text-*`). */
export function useUIDensity(): UIDensity {
  return useUIEngineContext().template.density
}

/** Tema activo (tokens de color/radio/sombra). */
export function useUITheme(): UIThemeId {
  return useUIEngineContext().template.theme
}

/** Región actual, para componentes que quieran adaptarse a su contenedor. */
export function useUIRegion(): UIRegionContextValue | null {
  return useContext(UIRegionContext)
}

/** Resolución efectiva del engine más cercano. */
export function useUIResolution(): UIEngineResolution | null {
  return useContext(UIResolutionContext)
}
