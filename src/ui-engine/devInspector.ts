import type { UITemplateId, UIRegionId } from './types'

/*
  Inspector DEV del UI Engine.

  La pantalla publica aquí su composición REAL (regiones y módulos) después de
  renderizar; el switcher DEV la consume con useSyncExternalStore. Es un canal
  de sólo lectura para desarrollo: no participa en ninguna decisión de layout
  ni de gameplay, y sólo se alimenta cuando el switcher está visible.
*/

export type UIScreenRegionSnapshot = {
  region: UIRegionId
  modules: readonly string[]
}

export type UIScreenSnapshot = {
  screen: string
  template: UITemplateId | '-'
  /** Ancho medido del contenedor de pantalla (container queries). */
  width: number
  regions: readonly UIScreenRegionSnapshot[]
}

let snapshot: UIScreenSnapshot | null = null
const listeners = new Set<() => void>()

export function publishUIScreenSnapshot(next: UIScreenSnapshot | null) {
  const changed =
    next === snapshot ||
    (next !== null &&
      snapshot !== null &&
      next.screen === snapshot.screen &&
      next.template === snapshot.template &&
      next.width === snapshot.width &&
      next.regions.length === snapshot.regions.length &&
      next.regions.every(
        (region, index) =>
          region.region === snapshot?.regions[index]?.region &&
          region.modules.join(',') === snapshot?.regions[index]?.modules.join(','),
      ))

  if (changed) return
  snapshot = next
  for (const listener of listeners) listener()
}

export function subscribeUIScreenSnapshot(listener: () => void) {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

export function getUIScreenSnapshot(): UIScreenSnapshot | null {
  return snapshot
}
