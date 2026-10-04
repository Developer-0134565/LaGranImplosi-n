/* =============================================================================
   GALAGA — PUNTO DE ENTRADA DEL LIENZO (ESTRUCTURA BASE, SIN JUEGO)
   -----------------------------------------------------------------------------
   Este componente existe SOLO para dejar un <canvas> real montado dentro de la PDA,
   con su ref disponible y sus dimensiones fijadas.

   LO QUE ESTA HECHO:
     · monta el elemento <canvas>
     · guarda el nodo en un ref (useRef) para poder alcanzar el contexto 2D
     · fija width/height desde las constantes

   LO QUE NO ESTA HECHO Y NO SE IMPLEMENTARA AQUI:
     · ningun ctx.* (ni clearRect, ni fillRect, ni drawImage, ni nada)
     · ningun requestAnimationFrame ni game loop
     · jugador, enemigos, disparos, movimiento, colisiones, vidas, score, oleadas,
       particulas, animaciones, sonidos, IA, fisica o controles jugables
     · ninguna llamada a Supabase, ninguna persistencia, ninguna economia

   Regla de esta estructura: Cline prepara el lienzo, el usuario construye el juego.
   Para empezar a dibujar, el siguiente paso es leer el contexto desde el ref:
       const ctx = canvasRef.current?.getContext('2d')
   ========================================================================== */

import { useRef } from 'react'
import { GALAGA_CANVAS_HEIGHT, GALAGA_CANVAS_WIDTH } from './galaga/constants'

export type GalagaCanvasProps = {
  /** Etiqueta accesible del lienzo. El game loop no depende de ella. */
  label?: string
}

export function GalagaCanvas({ label = 'Galaga' }: GalagaCanvasProps) {
  /* El ref es el unico cable entre React y el contexto 2D. Se crea aqui y no se
     usa todavia a proposito: no se dibuja nada. */
  const canvasRef = useRef<HTMLCanvasElement>(null)

  return (
    <canvas
      ref={canvasRef}
      className="pda-galaga-canvas"
      width={GALAGA_CANVAS_WIDTH}
      height={GALAGA_CANVAS_HEIGHT}
      aria-label={label}
    />
  )
}