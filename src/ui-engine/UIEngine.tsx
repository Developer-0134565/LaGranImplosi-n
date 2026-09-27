import { useMemo } from 'react'
import type { CSSProperties, ReactNode } from 'react'
import { UIResolutionContext, useOptionalUIEngineContext, readStoredTemplate } from './context'
import { getUITemplate, isUITemplateId } from './templates'
import { useUIDesignerConfig } from './designer/designerStore'
import { getUIFontOption } from './designer/typography'
import { getUIDeviceProfile } from './designer/deviceProfiles'
import type { UIDensity, UIEngineResolution, UIThemeId, UITemplateId } from './types'
import './tokens.css'
import './ui-engine.css'

export type UIEngineProps = {
  /**
   * Override explícito del template:
   *   <UIEngine template="classic"><FleetScreen /></UIEngine>
   * Sin prop, el engine usa el template seleccionado (UI Designer, localStorage).
   */
  template?: UITemplateId
  /** Override de tema; por defecto el declarado por el template. */
  theme?: UIThemeId
  /** Override de densidad; por defecto la declarada por el template. */
  density?: UIDensity
  className?: string
  children: ReactNode
}

/**
 * Raíz del UI Engine.
 *
 * Responsabilidades:
 *   1. resolver template + tema + densidad;
 *   2. aplicar las escalas del Designer como tokens (`--lgi-font-scale`,
 *      `--lgi-ui-scale`, `--lgi-font-family`);
 *   3. publicar la resolución a los módulos (región, densidad, tema);
 *   4. exponer las capas DEV del Designer como atributos (`grid`, `boundaries`,
 *      `edit`), que sólo añaden CSS de inspección.
 *
 * NO renderiza gameplay, NO toca Supabase y NO conoce las pantallas. La
 * geometría vive en ui-engine.css: aquí no se escribe ninguna posición.
 */
export function UIEngine({ template, theme, density, className, children }: UIEngineProps) {
  const context = useOptionalUIEngineContext()
  const designer = useUIDesignerConfig()

  const resolution = useMemo<UIEngineResolution>(() => {
    const explicit = isUITemplateId(template) ? template : null
    // The Designer config is the source of truth for the user-selected template.
    // The provider remains a compatibility/persistence bridge, not a competing
    // authority. An explicit <UIEngine template="..."> still wins.
    const fromDesigner = isUITemplateId(designer.template) ? designer.template : null
    const fromContext = context?.template.id ?? null
    const stored = readStoredTemplate()
    const selected =
      explicit ??
      fromDesigner ??
      fromContext ??
      (isUITemplateId(stored) ? stored : null)
    const resolved = getUITemplate(selected)
    return {
      template: resolved,
      theme: theme ?? designer.theme ?? resolved.theme,
      density: density ?? designer.density ?? resolved.density,
    }
  }, [
    template,
    theme,
    density,
    designer.template,
    designer.theme,
    designer.density,
    context?.template.id,
  ])

  /**
   * Escalas del Designer. `fontScale` sólo afecta a la tipografía y `uiScale`
   * sólo a espaciado/cajas: son tokens distintos y no se mezclan.
   */
  const scaleStyle = useMemo<CSSProperties>(() => {
    const font = getUIFontOption(designer.fontId)
    const properties: Record<string, string> = {
      '--lgi-font-scale': String(designer.fontScale),
      '--lgi-ui-scale': String(designer.uiScale),
    }
    /** Sin familia elegida no se define `--lgi-font-family`: cada rol del
     *  engine cae al pipeline de fuentes propio del proyecto. */
    if (font && font.stack) properties['--lgi-font-family'] = font.stack
    return properties as CSSProperties
  }, [designer.fontId, designer.fontScale, designer.uiScale])

  const rootClassName = className ? `lgi-engine ${className}` : 'lgi-engine'
  const device = getUIDeviceProfile(designer.deviceProfile)

  return (
    <UIResolutionContext.Provider value={resolution}>
      <div
        className={rootClassName}
        style={scaleStyle}
        data-lgi-template={resolution.template.id}
        data-lgi-theme={resolution.theme}
        data-lgi-density={resolution.density}
        data-lgi-grid={designer.grid ? 'on' : 'off'}
        data-lgi-boundaries={designer.boundaries ? 'on' : 'off'}
        data-lgi-safe-area={designer.safeArea ? 'on' : 'off'}
        data-lgi-edit={designer.editMode ? 'on' : 'off'}
        data-lgi-device={device.id}
        data-lgi-edit-bp={designer.breakpoint}
      >
        {children}
      </div>
    </UIResolutionContext.Provider>
  )
}
