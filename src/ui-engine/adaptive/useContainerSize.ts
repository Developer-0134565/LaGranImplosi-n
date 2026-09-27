import { useCallback, useRef, useState } from 'react'

/*
  ADAPTABILIDAD

  Mecanismo principal: CSS Container Queries (`container-type: inline-size` en
  `.lgi-region`), ver ui-engine.css. El componente decide su forma por el
  espacio que le da el template, no por el tamaño de la ventana.

  Este hook es el complemento JS para los casos en los que hay que cambiar el
  MARKUP (no sólo el estilo) según el contenedor medido: inspector DEV y
  utilidades de layout.
*/

export type ContainerSize = { width: number; height: number }

const EMPTY_SIZE: ContainerSize = { width: 0, height: 0 }

/**
 * Mide el contenedor con ResizeObserver.
 *
 * `enabled: false` desactiva la observación por completo (ni observer ni
 * re-render). El callback se devuelve como `attach` (no como `ref`) porque es
 * un *callback ref*, no un objeto ref: así queda claro que no se lee ningún
 * `.current` durante el render.
 */
export function useContainerSize<T extends HTMLElement = HTMLDivElement>(enabled = true) {
  const [size, setSize] = useState<ContainerSize>(EMPTY_SIZE)
  const observer = useRef<ResizeObserver | null>(null)

  const attach = useCallback(
    (node: T | null) => {
      observer.current?.disconnect()
      observer.current = null
      if (!node || !enabled) return

      const publish = (next: ContainerSize) => {
        setSize((current) =>
          current.width === next.width && current.height === next.height ? current : next,
        )
      }

      publish({ width: node.clientWidth, height: node.clientHeight })

      if (typeof ResizeObserver === 'undefined') return
      const created = new ResizeObserver((entries) => {
        const entry = entries[0]
        if (!entry) return
        const box = entry.contentBoxSize?.[0]
        publish(
          box
            ? { width: box.inlineSize, height: box.blockSize }
            : { width: entry.contentRect.width, height: entry.contentRect.height },
        )
      })
      created.observe(node)
      observer.current = created
    },
    [enabled],
  )

  return { attach, size, active: enabled }
}
