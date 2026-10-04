import { useCallback, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import {
  DEFAULT_LANG,
  fetchVisitorCountry,
  langFromCountry,
  readStoredLang,
  translate,
  writeStoredLang,
} from '../lib/i18n'
import type { Lang } from '../lib/i18n'
import { I18nContext } from './I18nContext'
import type { I18nValue } from './I18nContext'

/**
 * Resuelve el idioma al montar:
 *   1. preferencia guardada en localStorage (prioritaria)
 *   2. país IP vía /api/visitor  → regla de país → idioma
 *   3. inglés
 *
 * El país se pide una sola vez y en segundo plano: la UI arranca ya en un idioma
 * (el guardado o inglés) y se corrige en cuanto llega la respuesta. Nunca
 * bloquea el render.
 */
export function I18nProvider({ children }: { children: ReactNode }) {
  const [lang, setLangState] = useState<Lang>(() => readStoredLang() ?? DEFAULT_LANG)
  /* `ready` arranca en false sólo si HAY que preguntar al worker. Si ya existe
     preferencia guardada el idioma ya está resuelto desde el primer render, así que
     no hace falta un efecto para "terminar" de resolverlo. */
  const [ready, setReady] = useState<boolean>(() => readStoredLang() !== null)

  useEffect(() => {
    // Preferencia guardada: el idioma es definitivo, no se pregunta al worker.
    if (readStoredLang()) return

    const controller = new AbortController()
    fetchVisitorCountry(controller.signal)
      .then((country: string | null) => {
        if (controller.signal.aborted) return
        setLangState(langFromCountry(country))
      })
      .catch(() => {
        /* fallback ya aplicado: inglés */
      })
      .finally(() => {
        if (!controller.signal.aborted) setReady(true)
      })
    return () => controller.abort()
  }, [])

  const setLang = useCallback((next: Lang) => {
    setLangState(next)
    writeStoredLang(next)
  }, [])

  const value = useMemo<I18nValue>(
    () => ({ lang, t: (key) => translate(lang, key), setLang, ready }),
    [lang, setLang, ready],
  )

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>
}