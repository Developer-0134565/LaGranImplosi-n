import { isUIRegionId, type UIModuleId, type UIRegionId } from '../types'
import {
  UI_MODULE_SPAN_MAX,
  UI_MODULE_SPAN_MIN,
  UI_REGION_TRACK_MAX,
  UI_REGION_TRACK_MIN,
  moveUIDesignerModule,
  selectUIDesignerModule,
  setUIDesignerModuleSpan,
  setUIDesignerRegionTrack,
} from './designerStore'

/*
  UI DESIGNER — INTERACCIONES DE EDICIÓN (pointer events)

  Reglas:

    * Sólo se activan en modo edición; sin modo edición no se registra ningún
      listener y la superficie de juego es idéntica a la de producción.
    * El arrastre empieza en un handle propio (`lgi-designer-grip`), nunca en el
      cuerpo del módulo: así los controles del juego siguen funcionando.
    * MOVE   → cambia la región destino en el MODELO (nunca `position`).
    * RESIZE → cambia el span del módulo o la pista de columna de la región.
    * `touch-action: none` en los handles (designer.css) mantiene el gesto en
      Android en lugar de perdérselo al hacer scroll.
*/

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value))
}

function regionElementAt(clientX: number, clientY: number): HTMLElement | null {
  const element = document.elementFromPoint(clientX, clientY)
  if (!(element instanceof Element)) return null
  const region = element.closest('.lgi-region')
  return region instanceof HTMLElement ? region : null
}

function releasePointer(target: HTMLElement, pointerId: number) {
  try {
    target.releasePointerCapture(pointerId)
  } catch {
    /* el puntero ya se soltó */
  }
}

function trackPointer(move: (event: PointerEvent) => void, end: (event: PointerEvent) => void) {
  const onMove = (event: PointerEvent) => move(event)
  const onEnd = (event: PointerEvent) => {
    window.removeEventListener('pointermove', onMove)
    window.removeEventListener('pointerup', onEnd)
    window.removeEventListener('pointercancel', onEnd)
    end(event)
  }
  window.addEventListener('pointermove', onMove)
  window.addEventListener('pointerup', onEnd)
  window.addEventListener('pointercancel', onEnd)
}

/** MOVE: arrastra un módulo a otra región del template. */
export function beginUIDesignerModuleDrag(
  event: React.PointerEvent<HTMLElement>,
  options: { screen: string; moduleId: UIModuleId },
) {
  if (event.pointerType === 'mouse' && event.button !== 0) return
  event.preventDefault()
  const grip = event.currentTarget
  const moduleElement = grip.closest<HTMLElement>('.lgi-module')
  const pointerId = event.pointerId
  grip.setPointerCapture(pointerId)
  selectUIDesignerModule({ screen: options.screen, moduleId: options.moduleId })

  let highlight: HTMLElement | null = null
  const clearHighlight = () => {
    highlight?.classList.remove('lgi-drop-target')
    highlight = null
  }
  moduleElement?.classList.add('lgi-dragging')

  trackPointer(
    (moveEvent) => {
      const region = regionElementAt(moveEvent.clientX, moveEvent.clientY)
      if (region === highlight) return
      clearHighlight()
      highlight = region
      highlight?.classList.add('lgi-drop-target')
    },
    (endEvent) => {
      moduleElement?.classList.remove('lgi-dragging')
      const region = regionElementAt(endEvent.clientX, endEvent.clientY)
      const regionId = region?.dataset.region
      clearHighlight()
      releasePointer(grip, pointerId)
      if (isUIRegionId(regionId)) moveUIDesignerModule(options.moduleId, regionId)
    },
  )
}

/** RESIZE: cambia el span del módulo dentro de la rejilla interna de su región. */
export function beginUIDesignerSpanDrag(
  event: React.PointerEvent<HTMLElement>,
  options: { screen: string; moduleId: UIModuleId; span: number; columns: number },
) {
  event.preventDefault()
  const handle = event.currentTarget
  const regionElement = handle.closest<HTMLElement>('.lgi-region')
  const pointerId = event.pointerId
  const startX = event.clientX
  const startSpan = options.span
  const columns = Math.max(1, options.columns)
  const columnWidth = Math.max(24, (regionElement?.clientWidth ?? 240) / columns)
  handle.setPointerCapture(pointerId)
  selectUIDesignerModule({ screen: options.screen, moduleId: options.moduleId })

  trackPointer(
    (moveEvent) => {
      const delta = Math.round((moveEvent.clientX - startX) / columnWidth)
      const next = clamp(startSpan + delta, UI_MODULE_SPAN_MIN, UI_MODULE_SPAN_MAX)
      setUIDesignerModuleSpan(options.moduleId, next)
    },
    () => releasePointer(handle, pointerId),
  )
}

/** RESIZE: ajusta la pista de columna de una región redimensionable. */
export function beginUIDesignerTrackDrag(
  event: React.PointerEvent<HTMLElement>,
  options: { screen: string; region: UIRegionId },
) {
  event.preventDefault()
  const handle = event.currentTarget
  const regionElement = handle.closest<HTMLElement>('.lgi-region')
  const layoutElement = handle.closest<HTMLElement>('.lgi-layout')
  if (!regionElement || !layoutElement) return

  const pointerId = event.pointerId
  const startX = event.clientX
  const computed = getComputedStyle(layoutElement)
  const declaredMin = Number.parseFloat(computed.getPropertyValue(`--lgi-track-${options.region}-min`))
  const declaredMax = Number.parseFloat(computed.getPropertyValue(`--lgi-track-${options.region}-max`))
  const measured = regionElement.getBoundingClientRect().width
  const startMin = Number.isFinite(declaredMin) ? declaredMin : Math.max(0, measured - 20)
  const startMax = Number.isFinite(declaredMax) ? declaredMax : measured + 20
  handle.setPointerCapture(pointerId)

  trackPointer(
    (moveEvent) => {
      const delta = moveEvent.clientX - startX
      setUIDesignerRegionTrack(options.region, {
        min: clamp(Math.round(startMin + delta), UI_REGION_TRACK_MIN, UI_REGION_TRACK_MAX),
        max: clamp(Math.round(startMax + delta), UI_REGION_TRACK_MIN, UI_REGION_TRACK_MAX),
      })
    },
    () => releasePointer(handle, pointerId),
  )
}

/** Selección por clic en el módulo (no bloquea el evento: el juego sigue vivo). */
export function selectUIDesignerFromPointer(screen: string, moduleId: UIModuleId) {
  selectUIDesignerModule({ screen, moduleId })
}

