import { createContext, useContext } from 'react'
import type { Lang, StringKey } from '../lib/i18n'

export interface I18nValue {
  lang: Lang
  t: (key: StringKey) => string
  setLang: (lang: Lang) => void
  /** true mientras no se ha resuelto aún el país (evita parpadeo de idioma). */
  ready: boolean
}

export const I18nContext = createContext<I18nValue | null>(null)

/**
 * Acceso al idioma. Lanza si se usa fuera del provider: es un fallo de cableado,
 * no un caso de runtime que merezca un valor por defecto silencioso.
 */
export function useI18n(): I18nValue {
  const ctx = useContext(I18nContext)
  if (!ctx) throw new Error('useI18n debe usarse dentro de <I18nProvider>')
  return ctx
}