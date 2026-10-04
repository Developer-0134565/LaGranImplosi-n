/* ==========================================================================
   MEDICIÓN DEL LAYOUT — se ejecuta DENTRO de la página (scripts/layout-audit.mjs
   lo inyecta con Runtime.evaluate). Es JS plano a propósito: vive en su propio
   archivo para no competir con los template literals del runner.

   Devuelve el informe CRUDO. Toda interpretación vive en el runner de Node, que
   es donde las reglas se pueden leer y auditar.

   Qué mide, y contra qué síntoma reportado:
     1. `overflowing`   → cajas cuya derecha se sale del viewport.
     2. `docOverflow`   → scroll horizontal de página ("contenido cortado").
     3. `overlaps`      → hermanos que se pisan en un grid/flex ("texto
                           superpuesto", stats que chocan con la descripción).
     4. `cardBleed`     → contenido que sale de SU PROPIA tarjeta.
     5. `buttonFit`     → botón recortado o con tamaño cero.
     6. `images`        → object-fit y deformación del ratio intrínseco.
     7. `shell`/`regions` → si el shell ocupa el ancho del viewport entero.
   ========================================================================== */
(() => {
  const de = document.documentElement
  const vw = de.clientWidth
  const vh = de.clientHeight

  const sig = (el) => {
    const cls = typeof el.className === 'string' ? el.className.trim() : ''
    const base = el.tagName.toLowerCase()
    return cls ? base + '.' + cls.split(/\s+/).join('.') : base
  }

  const box = (sel) => {
    const el = document.querySelector(sel)
    if (!el) return null
    const b = el.getBoundingClientRect()
    return {
      left: Math.round(b.left),
      right: Math.round(b.right),
      top: Math.round(b.top),
      bottom: Math.round(b.bottom),
      width: Math.round(b.width),
      height: Math.round(b.height),
    }
  }

  /* 1) desborde horizontal.
        Se ignoran las cajas que un ANCESTRO recorta: si `.neo-owned-planets`
        tiene `overflow-x:hidden`, un hijo `inline-flex` de 180px puede medir más
        allá del viewport y aun así NOverse. Contarlas produce falsos positivos
        que hay que distinguir de un desborde real. */
  const isClipped = (el) => {
    for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
      const st = getComputedStyle(p)
      if (st.overflowX !== 'visible' || st.overflowY !== 'visible') return true
    }
    return false
  }

  const overflowing = []
  const clippedOnly = []
  for (const el of document.querySelectorAll('.lgi-live-shell *')) {
    const b = el.getBoundingClientRect()
    if (b.width < 1 && b.height < 1) continue
    if (b.right > vw + 1) {
      const entry = { el: sig(el), right: Math.round(b.right), by: Math.round(b.right - vw) }
      if (isClipped(el)) clippedOnly.push(entry)
      else overflowing.push(entry)
    }
  }

  /* 3) solapamiento entre hermanos dentro de contenedores grid/flex.
        Se ignoran los posicionados en absoluto/fijo: se solapan a propósito. */
  const overlaps = []
  const checkGrid = (parentSel) => {
    for (const parent of document.querySelectorAll(parentSel)) {
      const kids = Array.prototype.filter.call(parent.children, (k) => {
        const st = getComputedStyle(k)
        if (st.display === 'none') return false
        if (st.position === 'absolute' || st.position === 'fixed') return false
        if (st.display === 'contents') return false
        return true
      })
      for (let i = 0; i < kids.length; i += 1) {
        for (let j = i + 1; j < kids.length; j += 1) {
          const a = kids[i].getBoundingClientRect()
          const b = kids[j].getBoundingClientRect()
          const ox = Math.min(a.right, b.right) - Math.max(a.left, b.left)
          const oy = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top)
          if (ox > 1 && oy > 1) {
            overlaps.push({
              parent: sig(parent),
              a: sig(kids[i]),
              b: sig(kids[j]),
              overlapX: Math.round(ox),
              overlapY: Math.round(oy),
            })
          }
        }
      }
    }
  }
  checkGrid('.neo-card-grid')
  checkGrid('.neo-definition-costs')
  checkGrid('.neo-definition-stats')
  checkGrid('.neo-definition-extra')
  checkGrid('.neo-definition')

  /* 4) contenido que se sale de su propia tarjeta */
  const cardBleed = []
  for (const card of document.querySelectorAll('.neo-definition')) {
    const cb = card.getBoundingClientRect()
    for (const child of card.querySelectorAll(':scope > *')) {
      const b = child.getBoundingClientRect()
      if (b.height < 1) continue
      const bleedBottom = Math.round(b.bottom - cb.bottom)
      const bleedRight = Math.round(b.right - cb.right)
      if (bleedBottom > 1 || bleedRight > 1) {
        cardBleed.push({ el: sig(child), bleedBottom: bleedBottom, bleedRight: bleedRight })
      }
    }
  }

  /* 5) botón que no cabe en su tarjeta */
  const buttonFit = []
  for (const card of document.querySelectorAll('.neo-definition')) {
    const cb = card.getBoundingClientRect()
    for (const btn of card.querySelectorAll('.neo-button')) {
      const b = btn.getBoundingClientRect()
      const clipped = b.bottom > cb.bottom + 1 || b.right > cb.right + 1 || b.top < cb.top - 1
      const zero = b.width < 4 || b.height < 4
      if (clipped || zero) {
        buttonFit.push({
          el: sig(btn),
          w: Math.round(b.width),
          h: Math.round(b.height),
          clipped: clipped,
          zero: zero,
        })
      }
    }
  }

  /* 6) object-fit y ratio de imagen */
  const images = []
  for (const img of document.querySelectorAll('.neo-definition-media img')) {
    const st = getComputedStyle(img)
    const b = img.getBoundingClientRect()
    const natRatio =
      img.naturalWidth && img.naturalHeight ? img.naturalWidth / img.naturalHeight : null
    images.push({
      fit: st.objectFit,
      renderedRatio: b.height ? Math.round((b.width / b.height) * 1000) / 1000 : 0,
      naturalRatio: natRatio ? Math.round(natRatio * 1000) / 1000 : null,
      natural: [img.naturalWidth, img.naturalHeight],
    })
  }

  /* 7) La navegación lateral debe ser una LISTA.
        Esta comprobación existe por un bug real que la auditoría NO detectó:
        `.neo-nav` no tenía ninguna regla, sus <button> inline-block se envolvían
        en dos columnas y las 42 combinaciones pasaban limpias. Un sidebar
        "desordenado" es exactamente este fallo, así que se comprueba la forma:
        mismo `left` para todos, `top` estrictamente creciente, ancho ≈ contenedor. */
  const nav = {
    container: null,
    items: [],
    stacked: null,
    offending: [],
  }
  const navEl = document.querySelector('.neo-nav')
  if (navEl) {
    const cb = navEl.getBoundingClientRect()
    nav.container = { width: Math.round(cb.width) }
    const items = Array.prototype.slice.call(navEl.querySelectorAll('.neo-nav-item'))
    nav.items = items.length
    if (items.length > 1) {
      const rects = items.map((el) => {
        const b = el.getBoundingClientRect()
        return { left: Math.round(b.left), top: Math.round(b.top), width: Math.round(b.width) }
      })
      const lefts = rects.map((r) => r.left)
      const sameColumn = lefts.every((l) => Math.abs(l - lefts[0]) <= 2)
      let increasing = true
      for (let i = 1; i < rects.length; i += 1) {
        if (rects[i].top <= rects[i - 1].top) { increasing = false }
      }
      // ancho ≈ el del contenedor ⇒ cada fila ocupa la línea entera (lista)
      const fullWidth = rects.every((r) => cb.width > 0 && r.width >= cb.width - 4)
      nav.stacked = sameColumn && increasing && fullWidth
      if (!nav.stacked) {
        for (let i = 0; i < rects.length; i += 1) {
          if (i > 0 && (Math.abs(rects[i].left - rects[0].left) > 2 || rects[i].top <= rects[i - 1].top)) {
            nav.offending.push({ index: i, left: rects[i].left, top: rects[i].top, width: rects[i].width })
          }
        }
      }
    } else {
      nav.stacked = true
    }
  }

  const scroller = document.querySelector('.neo-main-content')
  const grid = document.querySelector('.neo-card-grid')

  return {
    viewport: { w: vw, h: vh },
    docOverflow: {
      scrollWidth: de.scrollWidth,
      clientWidth: vw,
      bodyScrollWidth: document.body.scrollWidth,
    },
    shell: box('.lgi-live-shell'),
    layout: box('.lgi-layout'),
    regions: {
      rail: box('[data-region="rail"]'),
      main: box('[data-region="main"]'),
      aside: box('[data-region="aside"]'),
    },
    mainContent: scroller
      ? {
          clientWidth: scroller.clientWidth,
          scrollWidth: scroller.scrollWidth,
          clientHeight: scroller.clientHeight,
          scrollHeight: scroller.scrollHeight,
        }
      : null,
    firstCard: box('.neo-definition'),
    gridColumns: grid ? getComputedStyle(grid).gridTemplateColumns : null,
    overflowing: overflowing.slice(0, 25),
    overflowCount: overflowing.length,
    clippedCount: clippedOnly.length,
    overlaps: overlaps.slice(0, 25),
    overlapCount: overlaps.length,
    cardBleed: cardBleed.slice(0, 25),
    cardBleedCount: cardBleed.length,
    buttonFit: buttonFit.slice(0, 25),
    buttonFitCount: buttonFit.length,
    images: images.slice(0, 4),
    imageCount: images.length,
    nav: nav,
  }
})()
