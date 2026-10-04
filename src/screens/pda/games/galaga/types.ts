/** Marcador de que este archivo es un hueco deliberado, no un olvido. */
export type GalagaNotImplementedYet = never

/* ---------------------------------------------------------------------------
   PUNTOS DE EXTENSION — TIPOS, TODOS VACIOS A PROPOSITO
   ---------------------------------------------------------------------------
   Aqui viviran las formas de datos del juego cuando se implemente. NO se declara
   ninguna ahora porque hacerlo seria INVENTAR mecanicas: elegir las entidades y sus
   campos es justamente parte del ejercicio de construccion del juego.

   Cuando se implemente, este archivo es el sitio natural para, por ejemplo:

     · Vec2        — posicion / desplazamiento
     · Player      — la nave del jugador
     · Enemy       — un enemigo Galaga (y su tipo/variante)
     · Projectile  — un disparo
     · Wave        — una oleada de enemigos
     · GameState   — marcador, vidas, nivel, enEjecucion...

   Los nombres concretos los decide quien programe el juego.
   ------------------------------------------------------------------------- */