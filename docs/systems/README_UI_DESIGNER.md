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