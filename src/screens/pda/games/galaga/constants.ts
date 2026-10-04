/** TAMANO DEL LIENZO.
 *
 *  Placeholder deliberado: son las UNICAS constantes que la estructura necesita para
 *  poder crear un <canvas> con dimensiones concretas. NO hay balance, ni velocidades,
 *  ni vidas, ni puntuacion: eso lo escribira quien construya el juego.
 */
export const GALAGA_CANVAS_WIDTH = 480
export const GALAGA_CANVAS_HEIGHT = 640

/* ---------------------------------------------------------------------------
   PUNTOS DE EXTENSION — TODOS SIN IMPLEMENTAR A PROPOSITO
   ---------------------------------------------------------------------------
   El juego se construira aqui dentro. Estos son los sitios naturales donde encaja
   cada pieza, pero NADUNO existe todavia:

     · game loop   -> useEffect del componente + requestAnimationFrame
     · input       -> listeners de teclado (addEventListener) sobre window
     · entidades   -> jugador, enemigos Galaga, proyectiles
     · colisiones  -> deteccion de solapamiento entre entidades
     · renderizado -> las llamadas ctx.* que pintan cada frame
     · oleadas     -> progresion de niveles / difficulty

   Nada de eso se ha escrito. Cline prepara el lienzo; el juego lo construye el usuario.
   ------------------------------------------------------------------------- */