# MARCIANITOS / GALAGA — PROGRESO DE APRENDIZAJE

## Contexto

**Juego:** Marcianitos  
**Nombre técnico/origen:** Galaga  
**Ubicación:** `src/screens/pda/games/`  
**Objetivo:** aprender HTML5 Canvas construyendo personalmente el juego.

### Regla de trabajo

El usuario implementará el gameplay de Marcianitos paso a paso.

ChatGPT actúa como profesor/examinador:

1. Presenta un test de **5 respuestas (A–E)**.
2. El usuario elige una respuesta.
3. Si acierta, recibe una pista pequeña y el siguiente test.
4. Si falla, se le indica la respuesta correcta y una explicación breve.
5. No se entrega el juego completo ni se salta directamente a fases posteriores.

## Estructura inicial

Cline preparó únicamente la estructura base:

```text
src/screens/pda/games/
├── GalagaCanvas.tsx
└── galaga/
    ├── constants.ts
    └── types.ts
```

El Canvas ya existe con `useRef<HTMLCanvasElement>(null)` y dimensiones `480x640`.

**No hay gameplay implementado.**

## Fases previstas

1. Canvas + contexto 2D  ← **EN CURSO**
2. Game loop
3. Nave del jugador
4. Input / movimiento
5. Disparos
6. Enemigos
7. Colisiones
8. Score / vidas
9. Waves
10. Pulido

## Progreso actual — Fase 1

### Test 1
Pregunta: ¿Cuál sería la primera función/concepto a implementar?

Respuesta del usuario: **B — correcta**.

Concepto aprendido:

```text
useRef
  ↓
canvasRef.current
  ↓
HTMLCanvasElement
```

### Test 2
Pregunta: ¿Cómo obtener el contexto 2D?

El usuario respondió inicialmente **D — incorrecta** y después **C — incorrecta**.

Respuesta correcta:

```ts
canvasRef.current?.getContext("2d")
```

Concepto aprendido:

```text
canvasRef.current
  ↓
getContext("2d")
  ↓
CanvasRenderingContext2D
```

### Test 3
Pregunta: ¿Cómo guardar/obtener el contexto dentro de `useEffect`?

Respuesta del usuario: **B — correcta**.

```ts
const ctx = canvasRef.current?.getContext("2d")
```

### Test 4 — PENDIENTE

Pregunta actual:

¿Por qué usar `useEffect` para acceder al Canvas?

A. Porque convierte automáticamente el canvas en un juego.

B. Porque permite acceder al DOM después de que React haya montado el componente.

C. Porque `useEffect` crea automáticamente un `CanvasRenderingContext2D`.

D. Porque `useEffect` sustituye a `requestAnimationFrame`.

E. Porque cualquier código que use `useRef` debe estar obligatoriamente dentro de `useEffect`.

**El usuario todavía no ha respondido.**

## Regla importante

No avanzar al game loop hasta cerrar correctamente la Fase 1.

No implementar código por el usuario salvo que lo pida expresamente o sea necesario para explicar un concepto.
