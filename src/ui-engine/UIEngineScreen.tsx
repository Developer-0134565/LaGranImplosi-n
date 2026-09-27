import { useEffect, useMemo } from 'react'
import type { CSSProperties, ReactNode } from 'react'
import {
  UIRegionContext,
  useOptionalUIEngineContext,
  useUIResolution,
} from './context'
import { useContainerSize } from './adaptive/useContainerSize'
import { publishUIScreenSnapshot } from './devInspector'
import { breakpointForWidth, type UIModuleId, type UIModuleMap, type UIRegionId } from './types'
import {
  activeDesignerTemplate,
  resolveUILayout,
  selectUIDesignerModule,
  useUIDesignerState,
} from './designer/designerStore'
import {
  beginUIDesignerModuleDrag,
  beginUIDesignerSpanDrag,
  beginUIDesignerTrackDrag,
} from './designer/designerInteractions'

export type UIEngineScreenProps = {
  /** Identificador de la pantalla (`fleet`), sólo informativo/DEV. */
  id: string
  /** Módulos ya renderizados, indexados por id del registry. */
  modules: UIModuleMap
  className?: string
}

/**
 * Composición de una pantalla.
 *
 * Recibe los módulos como DATOS (`id → nodo`) y los reparte por las regiones
 * que declara el template activo, respetando su orden. Un módulo nunca sabe
 * dónde está: lo decide el template. Las regiones sin módulos no se dibujan,
 * así que un template nunca deja huecos muertos.
 *
 * RESPONSIVE: el ancho medido del contenedor decide el breakpoint lógico
 * (`data-lgi-bp`), que selecciona la variante de composición guardada por el UI
 * Designer. La geometría sigue siendo responsabilidad exclusiva de las
 * container queries de ui-engine.css: aquí nunca se escribe una posición.
 */
export function UIEngineScreen({ id, modules, className }: UIEngineScreenProps) {
  const resolution = useUIResolution()
  const template = resolution?.template
  const engineContext = useOptionalUIEngineContext()
  const designer = useUIDesignerState()
  const designerConfig = designer.config

  /** El contenedor se mide siempre: de ahí salen el breakpoint y las variantes.
   *  También es lo que hace fiel el device preview (el ancho real del marco). */
  const { attach, size } = useContainerSize<HTMLDivElement>(true)
  const breakpoint = breakpointForWidth(size.width)
  const devVisible = engineContext?.switcherVisible ?? false

  const layout = useMemo(() => {
    if (!template) return null
    /** El override sale del estado suscrito del Designer (por eso `layouts` es
     *  dependencia real de este memo, no un extra). */
    return resolveUILayout(template, designerConfig.layouts[template.id]?.[breakpoint])
  }, [template, breakpoint, designerConfig.layouts])

  const groups = useMemo(() => {
    if (!template || !layout) return []
    const indexed = layout.order.map((moduleId, index) => ({ moduleId, index }))
    const rank = new Map<UIModuleId, number>(indexed.map((entry) => [entry.moduleId, entry.index]))
    const buckets = new Map<UIRegionId, Array<{ key: UIModuleId; node: ReactNode }>>()
    const declared = new Set<UIRegionId>(layout.regions)
    /** Red de seguridad: un módulo colocado en una región no declarada cae a
     *  'main' (o a la primera del template) en lugar de desaparecer. */
    const fallback: UIRegionId = declared.has('main') ? 'main' : layout.regions[0]

    for (const [moduleId, node] of Object.entries(modules)) {
      if (node === null || node === undefined || node === false) continue
      const requested = layout.placement[moduleId as UIModuleId] ?? 'main'
      const region = declared.has(requested) ? requested : fallback
      const bucket = buckets.get(region) ?? []
      bucket.push({ key: moduleId as UIModuleId, node })
      buckets.set(region, bucket)
    }

    for (const bucket of buckets.values()) {
      bucket.sort(
        (a, b) =>
          (rank.get(a.key) ?? Number.MAX_SAFE_INTEGER) - (rank.get(b.key) ?? Number.MAX_SAFE_INTEGER),
      )
    }

    return layout.regions
      .map((region) => ({ region, entries: buckets.get(region) ?? [] }))
      .filter((group) => group.entries.length > 0)
  }, [template, layout, modules])

  /** Inspector DEV: publica la composición real (sólo si el switcher está visible). */
  const snapshot = useMemo(
    () => ({
      screen: id,
      template: template?.id ?? ('-' as const),
      width: Math.round(size.width),
      regions: groups.map((group) => ({
        region: group.region,
        modules: group.entries.map((entry) => entry.key as string),
      })),
    }),
    [id, template?.id, size.width, groups],
  )

  useEffect(() => {
    if (!devVisible) return
    publishUIScreenSnapshot(snapshot)
  }, [devVisible, snapshot])

  /** Pistas declaradas como redimensionables por el template activo. */
  const resizableTracks = template?.resizableTracks ?? []
  const editMode = designerConfig.editMode
  const editingTemplate = editMode ? activeDesignerTemplate() : null
  const editingThisTemplate = editingTemplate?.id === template?.id
  const selection = designer.selection

  /**
   * Geometría redimensionable: el Designer sólo publica las variables que el
   * CSS del template ya usa (`--lgi-track-<región>-min/-max`). Sin overrides el
   * objeto queda vacío y el CSS del template manda sin cambios.
   */
  const trackStyle = useMemo(() => {
    const properties: Record<string, string> = {}
    for (const [region, track] of Object.entries(layout?.regionTracks ?? {})) {
      if (!track) continue
      properties[`--lgi-track-${region}-min`] = `${track.min}px`
      properties[`--lgi-track-${region}-max`] = `${track.max}px`
    }
    return properties as CSSProperties
  }, [layout?.regionTracks])

  if (!resolution || !template || !layout) {
    return (
      <div className={className ? `lgi-screen ${className}` : 'lgi-screen'} data-lgi-screen={id}>
        <p className="lgi-note">
          UI Engine sin resolver: monta esta pantalla dentro de <code>&lt;UIEngine&gt;</code>.
        </p>
      </div>
    )
  }

  return (
    <div
      className={className ? `lgi-screen ${className}` : 'lgi-screen'}
      data-lgi-screen={id}
      data-lgi-bp={breakpoint}
      ref={attach}
      data-lgi-width={devVisible ? Math.round(size.width) : undefined}
      data-lgi-selected={editMode && selection ? selection.moduleId : undefined}
    >
      <div className="lgi-layout" style={trackStyle}>
        {groups.map(({ region, entries }) => {
          const columns = layout.regionColumns[region] ?? 1
          const regionStyle =
            columns > 1
              ? ({ '--lgi-region-columns': String(columns) } as CSSProperties)
              : undefined
          const draggable = editMode && editingThisTemplate && resizableTracks.includes(region)

          return (
            <UIRegionContext.Provider
              key={region}
              value={{
                region,
                templateId: template.id,
                density: resolution.density,
                theme: resolution.theme,
              }}
            >
              <section
                className="lgi-region"
                data-region={region}
                data-module-count={entries.length}
                data-region-columns={columns > 1 ? columns : undefined}
                style={regionStyle}
              >
                {entries.map((entry) => {
                  const span = layout.moduleSpans[entry.key] ?? 1
                  const selected =
                    editMode && selection?.screen === id && selection.moduleId === entry.key
                  const moduleStyle =
                    span > 1 ? ({ '--lgi-module-span': String(span) } as CSSProperties) : undefined

                  return (
                    <div
                      className={`lgi-module${selected ? ' is-selected' : ''}`}
                      data-module={entry.key}
                      data-module-span={span > 1 ? span : undefined}
                      key={entry.key}
                      style={moduleStyle}
                      onPointerDown={
                        editMode
                          ? () => selectUIDesignerModule({ screen: id, moduleId: entry.key })
                          : undefined
                      }
                      onClick={
                        editMode
                          ? () => selectUIDesignerModule({ screen: id, moduleId: entry.key })
                          : undefined
                      }
                    >
                      {editMode && (
                        <span
                          className="lgi-designer-grip"
                          role="presentation"
                          title="Arrastra para mover el módulo a otra región"
                          onPointerDown={(event) =>
                            beginUIDesignerModuleDrag(event, { screen: id, moduleId: entry.key })
                          }
                        >
                          ⋮⋮
                        </span>
                      )}
                      {entry.node}
                      {editMode && columns > 1 && (
                        <span
                          className="lgi-designer-handle lgi-designer-handle--span"
                          role="presentation"
                          title="Arrastra para cambiar el span del módulo"
                          onPointerDown={(event) =>
                            beginUIDesignerSpanDrag(event, {
                              screen: id,
                              moduleId: entry.key,
                              span,
                              columns,
                            })
                          }
                        >
                          ⇹
                        </span>
                      )}
                    </div>
                  )
                })}
                {draggable && (
                  <span
                    className="lgi-designer-handle lgi-designer-handle--track"
                    role="presentation"
                    title="Arrastra para ajustar la columna de esta región"
                    onPointerDown={(event) =>
                      beginUIDesignerTrackDrag(event, { screen: id, region })
                    }
                  >
                    ·
                  </span>
                )}
              </section>
            </UIRegionContext.Provider>
          )
        })}
      </div>
    </div>
  )
}
