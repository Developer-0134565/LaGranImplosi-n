# UI ENGINE / UI DESIGNER — LIVING TECHNICAL RECORD

> Durable technical record for the UI Engine and UI Designer. Operational status belongs in
> docs/PROJECT_CONTEXT_PROMPT.md; implementation details belong here.

## 1. Scope

The UI Engine provides the responsive layout/template layer and the DEV UI Designer provides a browser-based
layout editor. The Designer changes layout configuration only; it does not become authoritative for gameplay,
ownership or backend state.

Relevant implementation:
- src/ui-engine/UIEngine.tsx
- src/ui-engine/UIEngineScreen.tsx
- src/ui-engine/tokens.css
- src/ui-engine/designer/UIDesigner.tsx
- src/ui-engine/designer/designerStore.ts
- src/ui-engine/designer/designerInteractions.ts
- src/ui-engine/designer/designer.css
- src/ui-engine/reference/ReferenceGrids.tsx
- scripts/ui-engine-certify.mjs

## 2. Templates and regions

Current templates:
- classic: rail, main, aside
- command: header, main, aside
- tactical: status, ops, assets, log, actions
- orbital
- industrial
- minimal

The Designer supports template switching, font/UI scale, density, theme, device preview, grid/boundary/safe-area
overlays, edit mode, breakpoint variants, module selection, region movement, ordering and resizing.

## 3. Persistence

Designer configuration is stored in localStorage under:
- key: lagranimplosion-ui-designer
- schema version: 1

The store supports save/discard/reset, selection, layout overrides, movement, ordering, resizing and
region-span expansion, with sanitisation of persisted state.

## 4. Physical interaction contract

Module movement in edit mode starts from .lgi-designer-grip.

designerInteractions.ts:
1. validates the pointer/button;
2. prevents default browser behaviour;
3. captures the pointer on the grip;
4. selects the module;
5. tracks pointer movement;
6. resolves the region under the pointer with elementFromPoint;
7. highlights the candidate drop region;
8. on pointer release, calls the authoritative Designer store movement operation.

Resize uses pointer capture and converts horizontal movement to grid-span changes.

## 5. Browser certification

Certification script: scripts/ui-engine-certify.mjs
- serves dist/client with an explicit static server, MIME handling and SPA fallback;
- drives Edge through CDP;
- uses physical mouse input for selection, movement and resize;
- captures screenshots under %TEMP%\\lgi-ui-certify.

The certification currently contains 27 checks.

### Certified checks

The complete browser certification now passes all 27 checks. The final failing check was 12d, the physical
module drag, and it is now closed at the harness level.

The final physical-drag issue was proven to be a certification-harness geometry problem, not a production
Designer defect:
- the selected module's grip could be thousands of pixels outside the viewport;
- the destination region could simultaneously be thousands of pixels away;
- the harness therefore failed its elementFromPoint hit test before dispatching the drag;
- after making the harness scroll the source into view, press the grip, scroll the destination into view while
  retaining the button state, then dispatch the move/release at an in-viewport destination point, 12d passed.

Latest verified result:
PASS 12d Move por arrastre (pointer events) — status → ops (destino ops) · drag=true · eventos=3 ·
pointerdown@428,189:status pointermove@318,24:ops pointerup@318,24:ops

This proves the browser delivered the physical pointer sequence to the expected source and destination and the
module movement completed.

### Relevant certification history

- 8fc67c9: initial multi-region harness work.
- 37f639f: harness adjustment around physical module selection.
- f0c4663: force Designer device preview to desktop-1280 for the physical selection test.
- e51e730: instrument device state.
- c38ca7a: scroll selected modules into view before physical selection.
- a09938e: geometry-aware physical resize drag.
- 73005c3: hardened physical module move hit testing.
- e014756: normalized CDP drag pointermove events.
- 0f1565f: temporary pointer-event trace.
- 33194a9: added mouse-event trace alongside pointer events.
- 02ead27: exposed drag=true/false.
- 37538e5: exposed safe hit-test diagnostics.
- 4dc22d6: preserved hit-test diagnostics without throwing when source/target was missing.
- 289af0e: scrolled the drag source into view before hit testing.
- 6a7ec71: allowed physical drag across offscreen regions while preserving the pointer hold.
- 9ed1ec7: kept the final drag target inside the viewport after scrolling.

## 6. Certification interpretation

Do not modify production drag logic merely because a physical-drag certification fails. First establish:
- source is physically hit-testable;
- destination is physically hit-testable;
- both coordinates are inside the active viewport;
- CDP mouse dispatch actually occurs;
- page-level mouse/pointer events are observed;
- the final module region changes.

Only after those conditions are satisfied should designerInteractions.ts be treated as a production suspect.

## 7. Current status / next verification

The physical drag blocker is CLOSED at the harness level.

The complete 27/27 browser certification has now been recorded. The temporary drag diagnostics were removed;
the durable offscreen-source/destination drag geometry remains in the certification harness.

## 8. Boundaries

- No gameplay authority is delegated to the UI Designer.
- No frontend heuristic may replace backend ownership checks.
- Do not duplicate engine formulas in the Designer.
- Do not add a second layout engine to solve a Designer issue.
## 9. PDA Shell v1 (2026-09-28)

New player-facing SURFACE: a sci-fi Personal Data Assistant that acts as a modular container. It is
deliberately a container, not a system.

```
src/screens/pda/PdaShell.tsx   the shell + one component per module
src/styles/pda.css             frame, HUD, module tabs (new file, additive)
src/App.tsx                    view 'pda' + nav entry, fed from state already in memory
```

### Modules in v1

| Module | State | Notes |
|---|---|---|
| OVERVIEW | functional | Only renders data the app already holds (player, active body, resources, counters). 0 new calls, 0 new contracts. |
| MESSAGES | placeholder | `MessagesPanel` is NOT migrated here on purpose: the existing inbox stays the single source of truth. |
| NOTIFICATIONS | placeholder | No notification system is created. |
| IA ASSISTANT | placeholder, OFFLINE | No provider, no fetch, no keys, no data sent anywhere. |
| MINI-GAMES | placeholder, empty | No game installed. Galaga is a separate mission. |

### Visual language

The PDA reuses the existing `--neo-*` variables and existing components (`neo-section-head`,
`neo-eyebrow`, `neo-button`). It adds only PDA-specific framing: device border, HUD header, module tabs
and a scanline texture on the body. No global CSS was rewritten; `pda.css` is a new additive file.

### IA security requirement (documented, NOT implemented)

The future assistant must receive context ONLY through a server-side owner-scoped contract:

```
auth.uid() -> players.user_id -> players.id -> authorised summary -> IA
```

It must never reach Supabase directly, credentials, secrets, private tables, `service_role`, an arbitrary
`player_id`, or unauthorised global data. The v1 module states this in the UI and implements none of it.

### Boundaries respected

0 migrations · 0 new RPCs · 0 gameplay/engine changes · Messages untouched · no external calls.
## 10. PDA Messages v1 (2026-09-28)

El módulo `MESSAGES` de la PDA deja de ser un placeholder y monta el sistema de mensajes **existente**.
No es un módulo nuevo: es la misma bandeja, dentro del marco de la PDA.

```
PDA -> MESSAGES
  -> PlayerInboxPanel            (GameplayEnginePanel.tsx, sin modificar)
       -> get_player_messages    (lectura, contador, orden, límite)
       -> mark_message_read      (acción MARCAR LEÍDO)
```

### Qué se movió y qué NO

* `PlayerInboxPanel` se usa **sin cambios**. No se copió, no se reimplementó, no se duplicó.
* La navegación `MENSAJES` ahora abre la PDA con `initialModule="MESSAGES"`.
* `PdaMessages` es un **contenedor**: recibe `inbox` como slot desde `App.tsx` y lo monta dentro del
  marco PDA (módulo head + tabs + `pda.css`). No conoce la RPC, ni la carga, ni el estado de lectura.
* El contenido que ya viajaba en la vista `messages` (`PlayerInboxPanel`, `BattleReportsPanel`,
  `EspionageReportsPanel` y `renderMessages()`) entra por ese slot. Se conserva **tal cual**.
* Sigue habiendo **una sola instancia de la bandeja en toda la aplicación** (`App.tsx`). No hay dos
  inboxes activos, ni segunda consulta, ni segundo estado de lectura.

### Autoridad (no negociable)

| Contrato | Rol | Estado |
|---|---|---|
| `get_player_messages(p_limit, p_unread_only)` | lectura + filtro unread + orden + clamp | **sin cambios** |
| `mark_message_read(p_message_id)` | marcar leído (idempotente) | **sin cambios** |
| `player_messages` | cerrada a acceso directo del cliente | **sin cambios** |
| RLS / ACL | `authenticated` + `service_role`; `anon` denegado | **sin cambios** |

La cadena de propiedad es la misma y el cliente **no** puede proporcionar `player_id` ni owner arbitrario:

```
auth.uid() -> players.user_id -> players.id -> recipient_player_id
```

El `playerId` que la UI ya pasaba es sólo un guard de cliente (evita consultar sin sesión); la autoridad
la impone el servidor, que ignora cualquier identificador que llegue del cliente.

### Verificado

* `npx tsc -b` → 0 · `npx vite build` → 0 · `git diff --check` → 0
* `supabase/tests/pda_messages.sql` → **12 PASS / 0 FAIL** (`ROLLBACK`, sin datos LIVE)
  1. el dueño lo ve una vez y el filtro unread lo cuenta
  2. aparece en el filtro unread antes de marcar
  3. tras `mark_message_read` sale del filtro unread
  4. `read_at` persistido (el contador de la UI lo refleja)
  5. la segunda llamada es idempotente (`out_already_read`)
  6. el mensaje leído sigue en la bandeja completa (sólo se filtra del contador)
  7. otro jugador autenticado lee **0** filas de ese mensaje
  8. otro jugador **no** puede marcarlo leído (`PLAYER_MESSAGE_NOT_FOUND_OR_NOT_OWNED`)
  9. sin sesión la bandeja devuelve **0** filas
  10. ACL intacta en ambos contratos
  11. owner scoping intacto en ambos contratos
  12. `player_messages` sigue cerrada al acceso directo

### Limitación honesta

**BROWSER: ENVIRONMENT BLOCKED** — no había driver de navegador ni credencial DEV. La navegación visual
`PDA -> MESSAGES -> mensaje visible -> unread -> marcar leído` **no** está certificada en navegador;
compilación, build y contrato de servidor sí. La verificación de React pendiente es manual.

Nota sobre el fixture: una aserción anterior buscaba `'%pda%'` dentro del SQL de los contratos y daba
**falso positivo** — la palabra "up**date**" contiene literalmente el substring "pda". Se sustituyó por
una comprobación de propiedad real (cadena `auth.uid()` + guarda `NOT_OWNED`).
## 11. MINI-GAMES — Galaga: estructura base, SIN juego (2026-09-28)

> Galaga está **preparado estructuralmente**, pero **el gameplay lo implementará el usuario** como
> ejercicio de aprendizaje de HTML5 Canvas. No hay juego escrito.

```
src/screens/pda/games/
├── GalagaCanvas.tsx        componente React: monta el <canvas> y su ref
└── galaga/
    ├── constants.ts        SOLO el tamaño del lienzo (480x640)
    └── types.ts            marcador de "aún no implementado" (sin tipos de juego)
```

Qué hace hoy el componente, y nada más:

* monta el elemento `<canvas>`;
* guarda el nodo en un `useRef` para poder alcanzar el `CanvasRenderingContext2D`;
* fija `width`/`height` desde las constantes.

Qué **no** existe, deliberadamente: ningún `ctx.*`, ningún `requestAnimationFrame` ni game loop,
jugador, enemigos, disparos, movimiento, colisiones, vidas, score, oleadas, partículas, animaciones,
sonido, IA, física, controles, persistencia, Supabase ni leaderboard. Tampoco se eligió el modelo de
datos del juego (no hay `Vec2`, `Player`, `Enemy`…): inventar esas formas sería decidir la mecánica,
que es justo lo que corresponde construir.

`MINI-GAMES` monta el lienzo dentro del marco PDA con un aviso explícito de que el juego no existe.
El único CSS añadido es `.pda-galaga-canvas` (borde, fondo, `max-width`) en el `pda.css` ya existente:
sin sprites, sin imágenes y sin animaciones. **0 dependencias nuevas, 0 migraciones, 0 RPC.**

Criterio de cierre de esta misión: Cline prepara el lienzo, el usuario construye el juego.