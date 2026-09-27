import { useCallback, useEffect, useMemo, useState, useSyncExternalStore } from 'react'
import { useOptionalUIEngineContext } from '../context'
import { UI_TEMPLATES, getUITemplate } from '../templates'
import {
  UI_BREAKPOINTS,
  breakpointForWidth,
  type UIBreakpointId,
  type UIDensity,
  type UILayoutOverride,
  type UIModuleId,
  type UITemplateId,
  type UIThemeId,
} from '../types'
import { getUIScreenSnapshot, subscribeUIScreenSnapshot } from '../devInspector'
import { UI_DEVICE_PROFILES, getUIDeviceProfile } from './deviceProfiles'
import {
  UI_FONT_OPTIONS,
  UI_FONT_SCALE_MAX,
  UI_FONT_SCALE_MIN,
  UI_FONT_SCALE_STEP,
  UI_FONT_SCALE_STEPS,
  UI_UI_SCALE_MAX,
  UI_UI_SCALE_MIN,
  UI_UI_SCALE_STEP,
  getUIFontOption,
} from './typography'
import {
  copyUIDesignerLayoutFromDesktop,
  clearUIDesignerVariant,
  discardUIDesignerChanges,
  getUIModuleRegion,
  hasUIDesignerLayout,
  moveUIDesignerModule,
  moveUIDesignerModuleOrder,
  resetUIDesigner,
  resetUIDesignerTemplateLayout,
  saveUIDesigner,
  selectUIDesignerModule,
  setUIDesignerBreakpoint,
  setUIDesignerDensity,
  setUIDesignerDeviceProfile,
  setUIDesignerFlag,
  setUIDesignerFont,
  setUIDesignerFontScale,
  setUIDesignerModuleSpan,
  setUIDesignerRegionColumns,
  setUIDesignerRegionTrack,
  setUIDesignerTemplate,
  setUIDesignerTheme,
  setUIDesignerUiScale,
  useUIDesignerState,
} from './designerStore'
import type { UIDesignerFlagKey } from './designerStore'
import './designer.css'

/*
  UI DESIGNER — HERRAMIENTA DEV

  Panel flotante que edita el MODELO del engine, nunca el DOM del juego:

      template → tipografía → escala tipográfica → escala de UI → densidad →
      device preview → rejilla → límites de componente → selección → mover →
      redimensionar → variante responsive → guardar → recargar → reset

  Vive fuera de `.lgi-engine`, así que no participa en el layout: sólo escribe
  configuración (React + localStorage) que el engine consume como tokens,
  atributos y composición declarativa.
*/

const DENSITY_OPTIONS: readonly { value: UIDensity | ''; label: string }[] = [
  { value: '', label: 'Auto (template)' },
  { value: 'dense', label: 'Dense' },
  { value: 'compact', label: 'Compact' },
  { value: 'comfortable', label: 'Comfortable' },
]

const THEME_OPTIONS: readonly { value: UIThemeId | ''; label: string }[] = [
  { value: '', label: 'Auto (template)' },
  { value: 'nebula', label: 'Nebula' },
  { value: 'aurora', label: 'Aurora' },
  { value: 'tactical', label: 'Tactical' },
  { value: 'industrial', label: 'Industrial' },
  { value: 'monochrome', label: 'Monochrome' },
]

const BREAKPOINTS: readonly UIBreakpointId[] = ['desktop', 'tablet', 'mobile']

export type UIDesignerProps = {
  /** Oculta la herramienta sin desmontarla (por ejemplo en capturas). */
  hidden?: boolean
}

export function UIDesigner({ hidden = false }: UIDesignerProps) {
  const engine = useOptionalUIEngineContext()
  const { config, dirty, selection } = useUIDesignerState()
  const snapshot = useSyncExternalStore(subscribeUIScreenSnapshot, getUIScreenSnapshot)
  const [open, setOpen] = useState(true)
  const [showInspector, setShowInspector] = useState(false)

  const template = useMemo(() => getUITemplate(config.template), [config.template])
  const override = useMemo<UILayoutOverride>(
    () => config.layouts[config.template]?.[config.breakpoint] ?? {},
    [config.template, config.breakpoint, config.layouts],
  )
  const device = getUIDeviceProfile(config.deviceProfile)
  const fontOption = getUIFontOption(config.fontId)
  const measuredWidth = snapshot?.width ?? 0
  const measuredBreakpoint = breakpointForWidth(measuredWidth)

  const applyTemplate = useCallback(
    (id: UITemplateId) => {
      setUIDesignerTemplate(id)
      engine?.setTemplateId(id)
    },
    [engine],
  )


  /** El template del Designer sigue al del engine (una sola verdad). */
  useEffect(() => {
    if (!engine) return
    if (engine.templateId !== config.template) setUIDesignerTemplate(engine.templateId)
  }, [engine, config.template])

  /**
   * Device preview: el perfil limita el ancho del contenedor del engine en
   * `<html>` (nunca la ventana del navegador). Con `native` no se aplica nada.
   */
  useEffect(() => {
    const root = document.documentElement
    const profile = getUIDeviceProfile(config.deviceProfile)
    if (profile.width > 0) {
      root.dataset.lgiPreviewWidth = profile.id
      root.style.setProperty('--lgi-preview-width', `${profile.width}px`)
      if (profile.family === 'mobile') root.dataset.lgiPreviewMobile = 'on'
      else delete root.dataset.lgiPreviewMobile
    } else {
      delete root.dataset.lgiPreviewWidth
      delete root.dataset.lgiPreviewMobile
      root.style.removeProperty('--lgi-preview-width')
    }
    return () => {
      delete root.dataset.lgiPreviewWidth
      delete root.dataset.lgiPreviewMobile
      root.style.removeProperty('--lgi-preview-width')
    }
  }, [config.deviceProfile])

  /** Atajos DEV: no interfieren con el juego salvo con Alt pulsado. */
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (!event.altKey) return
      const key = event.key.toLowerCase()
      if (key === 't') {
        event.preventDefault()
        const index = UI_TEMPLATES.findIndex((entry) => entry.id === config.template)
        const next = UI_TEMPLATES[(index + 1) % UI_TEMPLATES.length]
        applyTemplate(next.id)
      } else if (key === 'd') {
        event.preventDefault()
        engine?.setSwitcherVisible(!(engine?.switcherVisible ?? true))
      } else if (key === 'g') {
        event.preventDefault()
        setUIDesignerFlag('grid', !config.grid)
      } else if (key === 'b') {
        event.preventDefault()
        setUIDesignerFlag('boundaries', !config.boundaries)
      } else if (key === 'e') {
        event.preventDefault()
        setUIDesignerFlag('editMode', !config.editMode)
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [applyTemplate, config.boundaries, config.editMode, config.grid, config.template, engine])

  const selectedModule: UIModuleId | null = selection?.moduleId ?? null
  const selectedRegion = selectedModule
    ? getUIModuleRegion(template, config.breakpoint, selectedModule)
    : null
  const selectedSpan = selectedModule ? (override.moduleSpans?.[selectedModule] ?? 1) : 1
  const selectedColumns = selectedRegion ? (override.regionColumns?.[selectedRegion] ?? 1) : 1
  const selectedTrack = selectedRegion ? override.regionTracks?.[selectedRegion] : undefined
  const trackResizable = selectedRegion ? (template.resizableTracks ?? []).includes(selectedRegion) : false

  const variantChips = useMemo(
    () =>
      BREAKPOINTS.map((breakpoint) => ({
        breakpoint,
        range: UI_BREAKPOINTS[breakpoint],
        defined: Boolean(config.layouts[config.template]?.[breakpoint]),
      })),
    [config.template, config.layouts],
  )

  const summary = useMemo(() => {
    if (!snapshot) return 'sin pantalla del engine montada'
    const modules = snapshot.regions.reduce((total, region) => total + region.modules.length, 0)
    const width = snapshot.width ? ` · ${snapshot.width}px` : ''
    return `${snapshot.regions.length} regiones · ${modules} módulos${width}`
  }, [snapshot])

  if (hidden || !engine || !engine.switcherVisible) return null

  if (!open) {
    return (
      <button
        type="button"
        className="lgi-designer-launcher"
        onClick={() => setOpen(true)}
        aria-label="Abrir el UI Designer"
      >
        UI DESIGNER
      </button>
    )
  }


  const flagControl = (key: UIDesignerFlagKey, label: string) => (
    <label className="lgi-designer__check" key={key}>
      <input
        type="checkbox"
        checked={config[key]}
        onChange={(event) => setUIDesignerFlag(key, event.target.checked)}
      />
      <span>{label}</span>
    </label>
  )

  return (
    <aside className="lgi-designer" aria-label="UI Designer — herramienta DEV">
      <header className="lgi-designer__head">
        <strong>UI DESIGNER · DEV</strong>
        <div className="lgi-designer__head-actions">
          {dirty && <span className="lgi-designer__badge">SIN GUARDAR</span>}
          <button type="button" onClick={() => setOpen(false)}>
            OCULTAR
          </button>
          <button
            type="button"
            onClick={() => engine.setSwitcherVisible(false)}
            aria-label="Cerrar las herramientas DEV"
          >
            ×
          </button>
        </div>
      </header>

      <div className="lgi-designer__body">
        <section className="lgi-designer__group">
          <div className="lgi-designer__group-title">
            <span>Template</span>
            <span>{config.template}</span>
          </div>
          <div className="lgi-designer__templates">
            {UI_TEMPLATES.map((entry) => (
              <button
                key={entry.id}
                type="button"
                className={`lgi-designer__template${entry.id === config.template ? ' active' : ''}`}
                aria-pressed={entry.id === config.template}
                onClick={() => applyTemplate(entry.id)}
              >
                <b>{entry.label}</b>
                <small>
                  {entry.theme} · {entry.density}
                </small>
              </button>
            ))}
          </div>
          <p className="lgi-designer__meta">
            <span>{template.description}</span>
            <em>{summary}</em>
          </p>
        </section>

        <section className="lgi-designer__group">
          <div className="lgi-designer__group-title">
            <span>Tipografía y escalas</span>
            <span>{config.fontId}</span>
          </div>
          <label className="lgi-designer__row">
            <span>Font</span>
            <select
              value={config.fontId}
              aria-label="Familia tipográfica"
              onChange={(event) => setUIDesignerFont(event.target.value)}
            >
              {UI_FONT_OPTIONS.map((option) => (
                <option key={option.id} value={option.id}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>

          <div className="lgi-designer__slider">
            <span>Font scale</span>
            <input
              type="range"
              min={UI_FONT_SCALE_MIN}
              max={UI_FONT_SCALE_MAX}
              step={UI_FONT_SCALE_STEP}
              value={config.fontScale}
              aria-label="Font scale"
              onChange={(event) => setUIDesignerFontScale(Number(event.target.value))}
            />
            <output title="Volver a 100%" onClick={() => setUIDesignerFontScale(1)}>
              {Math.round(config.fontScale * 100)}%
            </output>
          </div>

          <div className="lgi-designer__slider">
            <span>UI scale</span>
            <input
              type="range"
              min={UI_UI_SCALE_MIN}
              max={UI_UI_SCALE_MAX}
              step={UI_UI_SCALE_STEP}
              value={config.uiScale}
              aria-label="UI scale"
              onChange={(event) => setUIDesignerUiScale(Number(event.target.value))}
            />
            <output title="Volver a 100%" onClick={() => setUIDesignerUiScale(1)}>
              {Math.round(config.uiScale * 100)}%
            </output>
          </div>

          <div className="lgi-designer__chips">
            {UI_FONT_SCALE_STEPS.map((step) => (
              <button
                type="button"
                key={step}
                className={`lgi-designer__chip${Math.abs(config.fontScale - step) < 0.001 ? ' active' : ''}`}
                onClick={() => setUIDesignerFontScale(step)}
              >
                {Math.round(step * 100)}%
              </button>
            ))}
          </div>
          {fontOption && (
            <p className="lgi-designer__hint">
              {fontOption.source} · licencia {fontOption.license}
              {fontOption.note ? ` · ${fontOption.note}` : ''}
            </p>
          )}
        </section>

        <section className="lgi-designer__group">
          <div className="lgi-designer__group-title">
            <span>Aspecto</span>
            <span>tema / densidad</span>
          </div>
          <label className="lgi-designer__row">
            <span>Density</span>
            <select
              value={config.density ?? ''}
              aria-label="Densidad"
              onChange={(event) =>
                setUIDesignerDensity((event.target.value || null) as UIDensity | null)
              }
            >
              {DENSITY_OPTIONS.map((option) => (
                <option key={option.value || 'auto'} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <label className="lgi-designer__row">
            <span>Theme</span>
            <select
              value={config.theme ?? ''}
              aria-label="Tema"
              onChange={(event) =>
                setUIDesignerTheme((event.target.value || null) as UIThemeId | null)
              }
            >
              {THEME_OPTIONS.map((option) => (
                <option key={option.value || 'auto'} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
        </section>

        <section className="lgi-designer__group">
          <div className="lgi-designer__group-title">
            <span>Device preview</span>
            <span>
              {device.family}
              {device.dpr ? ` · dpr ${device.dpr}` : ''}
            </span>
          </div>
          <label className="lgi-designer__row">
            <span>Device</span>
            <select
              value={config.deviceProfile}
              aria-label="Perfil de dispositivo"
              onChange={(event) => setUIDesignerDeviceProfile(event.target.value)}
            >
              {UI_DEVICE_PROFILES.map((profile) => (
                <option key={profile.id} value={profile.id}>
                  {profile.label}
                </option>
              ))}
            </select>
          </label>
          <p className="lgi-designer__meta">
            <span>
              {device.width > 0
                ? `${device.width} × ${device.height || 'auto'} px · el perfil limita el contenedor`
                : 'El engine usa el ancho real de la aplicación.'}
            </span>
            <em>
              medido {measuredWidth || '—'}px · bp real {measuredBreakpoint}
            </em>
          </p>
        </section>

        <section className="lgi-designer__group">
          <div className="lgi-designer__group-title">
            <span>Capas DEV</span>
            <span>Alt+G · Alt+B · Alt+E</span>
          </div>
          {flagControl('grid', 'Grid (12 columnas + zonas)')}
          {flagControl('boundaries', 'Show component boundaries')}
          {flagControl('safeArea', 'Preview safe area (notch / gestos)')}
          {flagControl('editMode', 'Designer mode (select · move · resize)')}
          <p className="lgi-designer__hint">
            Arrastra el grip ⋮⋮ de un módulo para moverlo de región y el handle ⇹ para
            redimensionarlo. Los handles sólo existen en DEV: el juego no cambia.
          </p>
        </section>

        <section className="lgi-designer__group">
          <div className="lgi-designer__group-title">
            <span>Variantes responsive</span>
            <span>
              {hasUIDesignerLayout(config.template) ? 'layout propio' : 'declaración del template'}
            </span>
          </div>
          <div className="lgi-designer__chips">
            {variantChips.map((chip) => (
              <button
                type="button"
                key={chip.breakpoint}
                className={`lgi-designer__chip${chip.breakpoint === config.breakpoint ? ' active' : ''}${chip.defined ? '' : ' empty'}`}
                title={`${chip.range.min}–${chip.range.max === Number.POSITIVE_INFINITY ? '∞' : chip.range.max}px`}
                onClick={() => setUIDesignerBreakpoint(chip.breakpoint)}
              >
                {chip.breakpoint}
                {chip.defined ? ' ●' : ''}
              </button>
            ))}
          </div>
          <p className="lgi-designer__hint">
            Editando la variante <b>{config.breakpoint}</b>. La geometría la siguen gobernando
            las container queries; aquí sólo se cambia la composición.
          </p>
          <div className="lgi-designer__actions">
            <button
              type="button"
              disabled={config.breakpoint === 'desktop' || !variantChips[0].defined}
              onClick={() => copyUIDesignerLayoutFromDesktop()}
            >
              COPIAR DE DESKTOP
            </button>
            <button
              type="button"
              disabled={!variantChips.some((chip) => chip.breakpoint === config.breakpoint && chip.defined)}
              onClick={() => clearUIDesignerVariant()}
            >
              BORRAR VARIANTE
            </button>
          </div>
        </section>

        <section className="lgi-designer__group">
          <div className="lgi-designer__group-title">
            <span>Selección</span>
            <span>{selectedModule ?? 'nada seleccionado'}</span>
          </div>
          {selectedModule && selectedRegion ? (
            <>
              <p className="lgi-designer__meta">
                <span>
                  pantalla <em>{selection?.screen}</em> · región <em>{selectedRegion}</em>
                </span>
                <span>
                  span <em>{selectedSpan}</em> · columnas de región <em>{selectedColumns}</em>
                </span>
              </p>
              <label className="lgi-designer__row">
                <span>Move</span>
                <select
                  value={selectedRegion}
                  aria-label="Mover módulo a otra región"
                  onChange={(event) =>
                    moveUIDesignerModule(selectedModule, event.target.value as typeof selectedRegion)
                  }
                >
                  {template.regions.map((region) => (
                    <option key={region} value={region}>
                      {region}
                    </option>
                  ))}
                </select>
              </label>
              <div className="lgi-designer__actions">
                <button type="button" onClick={() => moveUIDesignerModuleOrder(selectedModule, -1)}>
                  ↑ SUBIR
                </button>
                <button type="button" onClick={() => moveUIDesignerModuleOrder(selectedModule, 1)}>
                  ↓ BAJAR
                </button>
                <button
                  type="button"
                  disabled={selectedSpan <= 1}
                  onClick={() => setUIDesignerModuleSpan(selectedModule, selectedSpan - 1)}
                >
                  SPAN −
                </button>
                <button
                  type="button"
                  onClick={() => setUIDesignerModuleSpan(selectedModule, selectedSpan + 1)}
                >
                  SPAN +
                </button>
              </div>
              <div className="lgi-designer__actions">
                <button
                  type="button"
                  disabled={selectedColumns <= 1}
                  onClick={() => setUIDesignerRegionColumns(selectedRegion, selectedColumns - 1)}
                >
                  COLUMNAS −
                </button>
                <button
                  type="button"
                  onClick={() => setUIDesignerRegionColumns(selectedRegion, selectedColumns + 1)}
                >
                  COLUMNAS +
                </button>
                <button type="button" onClick={() => selectUIDesignerModule(null)}>
                  DESELECCIONAR
                </button>
              </div>
              {trackResizable ? (
                <div className="lgi-designer__actions">
                  <button
                    type="button"
                    onClick={() => {
                      const base = selectedTrack ?? { min: 150, max: 210 }
                      setUIDesignerRegionTrack(selectedRegion, {
                        min: base.min - 20,
                        max: base.max - 20,
                      })
                    }}
                  >
                    TRACK − 20
                  </button>
                  <button
                    type="button"
                    onClick={() => {
                      const base = selectedTrack ?? { min: 150, max: 210 }
                      setUIDesignerRegionTrack(selectedRegion, {
                        min: base.min + 20,
                        max: base.max + 20,
                      })
                    }}
                  >
                    TRACK + 20
                  </button>
                </div>
              ) : (
                <p className="lgi-designer__hint">
                  La pista de <b>{selectedRegion}</b> no es redimensionable en {template.label}:
                  su template la declara proporcional.
                </p>
              )}

            </>
          ) : (
            <p className="lgi-designer__hint">
              Activa el modo edición y selecciona un módulo para moverlo, reordenarlo o
              redimensionarlo. También puedes pinchar directamente sobre él.
            </p>
          )}
        </section>

        <section className="lgi-designer__group">
          <div className="lgi-designer__group-title">
            <span>Pantalla</span>
            <span>{snapshot?.screen ?? '—'}</span>
          </div>
          <div className="lgi-designer__actions">
            <button type="button" onClick={() => setShowInspector((value) => !value)}>
              {showInspector ? 'OCULTAR REGIONES' : 'VER REGIONES'}
            </button>
            <button
              type="button"
              onClick={() => window.open(`${location.pathname}#ui-designer`, '_blank', 'noopener')}
            >
              BANCO DE PRUEBAS
            </button>
          </div>
          {showInspector && snapshot && (
            <ul className="lgi-designer__list">
              {snapshot.regions.map((region) => (
                <li key={region.region}>
                  <b>{region.region}</b>
                  <span>{region.modules.join(' · ')}</span>
                </li>
              ))}
            </ul>
          )}
        </section>

        <section className="lgi-designer__group">
          <div className="lgi-designer__group-title">
            <span>Guardar</span>
            <span>localStorage · v1</span>
          </div>
          <div className="lgi-designer__actions">
            <button type="button" className="primary" onClick={() => saveUIDesigner()}>
              GUARDAR LAYOUT
            </button>
            <button type="button" disabled={!dirty} onClick={() => discardUIDesignerChanges()}>
              DESCARTAR
            </button>
          </div>
          <div className="lgi-designer__actions">
            <button
              type="button"
              className="danger"
              onClick={() => {
                resetUIDesignerTemplateLayout()
                selectUIDesignerModule(null)
              }}
            >
              RESET LAYOUT
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => {
                const defaults = resetUIDesigner()
                selectUIDesignerModule(null)
                engine.setSwitcherVisible(true)
                if (engine.templateId !== defaults.template) engine.setTemplateId(defaults.template)
              }}
            >
              RESET
            </button>
          </div>
          <p className="lgi-designer__hint">
            RESET restaura los valores del Designer y borra únicamente su propia clave de
            localStorage: no toca otras preferencias del proyecto.
          </p>
        </section>
      </div>
    </aside>
  )
}