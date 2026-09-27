import { useCallback, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import {
  UIEngineContext,
  persistSwitcher,
  persistTemplate,
  readStoredSwitcher,
  readStoredTemplate,
} from './context'
import { DEFAULT_UI_TEMPLATE_ID, getUITemplate, isUITemplateId } from './templates'
import type { UITemplateId } from './types'

type UIEngineProviderProps = {
  /** Fuerza el template inicial (por encima de localStorage). */
  initialTemplate?: UITemplateId
  children: ReactNode
}

/**
 * Estado del template seleccionado. Vive en React + localStorage: la misión
 * no persiste esta preferencia en Supabase.
 */
export function UIEngineProvider({ initialTemplate, children }: UIEngineProviderProps) {
  const [templateId, setTemplateIdState] = useState<UITemplateId>(() => {
    const candidate = initialTemplate ?? readStoredTemplate()
    return isUITemplateId(candidate) ? candidate : DEFAULT_UI_TEMPLATE_ID
  })
  const [switcherVisible, setSwitcherVisibleState] = useState<boolean>(() => readStoredSwitcher())

  const setTemplateId = useCallback((id: UITemplateId) => {
    setTemplateIdState(id)
    persistTemplate(id)
  }, [])

  const setSwitcherVisible = useCallback((visible: boolean) => {
    setSwitcherVisibleState(visible)
    persistSwitcher(visible)
  }, [])

  const value = useMemo(
    () => ({
      templateId,
      template: getUITemplate(templateId),
      setTemplateId,
      switcherVisible,
      setSwitcherVisible,
    }),
    [templateId, setTemplateId, switcherVisible, setSwitcherVisible],
  )

  return <UIEngineContext.Provider value={value}>{children}</UIEngineContext.Provider>
}
