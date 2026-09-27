import { useSyncExternalStore } from 'react'

/*
  LGI UI ENGINE — ENTRADA AL BANCO DE PRUEBAS (DEV)

  Lógica de entrada separada del componente para que `UIWorkbench.tsx` sólo
  exporte componentes (regla de Fast Refresh): aquí viven el hash de activación
  y el hook que lo observa.
*/

export const UI_WORKBENCH_HASH = '#ui-designer'

export function isUIWorkbenchRequested(): boolean {
  return typeof window !== 'undefined' && window.location.hash.startsWith(UI_WORKBENCH_HASH)
}

function subscribeWorkbench(listener: () => void) {
  window.addEventListener('hashchange', listener)
  return () => window.removeEventListener('hashchange', listener)
}

/** El hash decide si se muestra el banco de pruebas (sin recargar la página). */
export function useUIWorkbenchRequested(): boolean {
  return useSyncExternalStore(subscribeWorkbench, isUIWorkbenchRequested, () => false)
}
