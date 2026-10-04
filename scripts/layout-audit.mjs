/* =============================================================================
   AUDITORÍA DE LAYOUT DEL SHELL DE JUEGO (headless, CDP nativo, 0 dependencias)
   -----------------------------------------------------------------------------
   Reutiliza la infraestructura CDP de `ui-engine-certify.mjs` (Edge headless +
   WebSocket nativo) y su servidor estático. NO instala Playwright/Puppeteer.

   POR QUÉ EXISTE ESTE SCRIPT
   El shell de juego (`App.tsx` -> `UIEngineScreen`) exige sesión de Supabase y
   este repositorio NO tiene credenciales DEV en el entorno. En vez de adivinar la
   geometría leyendo CSS, este script:
     1. sirve el build REAL (dist/client) y carga la app real en el navegador;
     2. espera a que la hoja de estilos REAL esté aplicada;
     3. inyecta `layout-audit.fixture.html`, que reproduce la jerarquía DOM exacta
        que emite `UIEngineScreen` con el template `classic`;
     4. ejecuta `layout-audit.measure.js` dentro de la página y aplica reglas.

   LÍMITE DE VERACIDAD, explícito: mide la CASCADE CSS real y la distribución
   real del grid, pero NO la lógica de React ni los datos de Supabase. Prueba la
   maquetación (que es lo que se reporta), no el contenido. Para certificar el
   contenido hace falta una sesión real.

   Uso:  node scripts/layout-audit.mjs
   ========================================================================== */

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const args = process.argv.slice(2)
const readArg = (name, fallback) => {
  const i = args.indexOf('--' + name)
  return i >= 0 && args[i + 1] ? Number(args[i + 1]) : fallback
}
const DEBUG_PORT = readArg('debug-port', 9777)
const EDGE = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
const SHOT_DIR = join(tmpdir(), 'lgi-layout-audit')
const HERE = process.cwd()
let BASE = ''

mkdirSync(SHOT_DIR, { recursive: true })
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const findings = []
function note(severity, area, message) {
  findings.push({ severity: severity, area: area, message: message })
  console.log('  [' + severity.toUpperCase() + '] ' + area + ': ' + message)
}

/* ------------------------------------------------------------- CDP mínimo -- */

class CdpSession {
  constructor(webSocketUrl) {
    this.socket = new WebSocket(webSocketUrl)
    this.nextId = 1
    this.pending = new Map()
    this.ready = new Promise((resolve, reject) => {
      this.socket.addEventListener('open', () => resolve())
      this.socket.addEventListener('error', () => reject(new Error('WebSocket de CDP no disponible')))
    })
    this.socket.addEventListener('message', (event) => this.onMessage(event.data))
  }
  onMessage(raw) {
    const message = JSON.parse(typeof raw === 'string' ? raw : raw.toString())
    if (message.id) {
      const entry = this.pending.get(message.id)
      if (!entry) return
      this.pending.delete(message.id)
      if (message.error) entry.reject(new Error(entry.method + ': ' + message.error.message))
      else entry.resolve(message.result)
      return
    }
    if (message.method === 'Runtime.exceptionThrown') {
      const d = message.params && message.params.exceptionDetails
      console.log('  [page-exception] ' + ((d && d.exception && d.exception.description) || (d && d.text) || 'desconocida'))
    }
  }
  send(method, params) {
    const id = this.nextId++
    const p = params || {}
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve: resolve, reject: reject, method: method })
      this.socket.send(JSON.stringify({ id: id, method: method, params: p }))
    })
  }
}

async function connect() {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      const response = await fetch('http://127.0.0.1:' + DEBUG_PORT + '/json/list')
      const targets = await response.json()
      const page = targets.find((t) => t.type === 'page')
      if (page && page.webSocketDebuggerUrl) return new CdpSession(page.webSocketDebuggerUrl)
    } catch {
      /* el navegador aún no expone el puerto */
    }
    await sleep(250)
  }
  throw new Error('No se pudo conectar al CDP de Edge')
}

async function startPreview() {
  const serverScript = join(HERE, 'scripts', 'ui-engine-certify-server.mjs')
  const child = spawn(
    process.execPath,
    [serverScript, '--root', join(HERE, 'dist', 'client'), '--port', '0'],
    { stdio: ['ignore', 'pipe', 'pipe'] },
  )
  const port = await new Promise((resolve, reject) => {
    let output = ''
    const onData = (chunk) => {
      output += chunk.toString()
      const match = output.match(/READY\s+(\d+)/)
      if (match) {
        child.stdout.off('data', onData)
        resolve(Number(match[1]))
      }
    }
    child.stdout.on('data', onData)
    child.stderr.on('data', (chunk) => { output += chunk.toString() })
    child.once('error', reject)
    child.once('exit', (code) => {
      if (code !== 0) reject(new Error('servidor terminó ' + code + ': ' + output.trim()))
    })
  })
  BASE = 'http://127.0.0.1:' + port
  return child
}

function startBrowser() {
  const profile = join(tmpdir(), 'lgi-layout-profile-' + Date.now())
  mkdirSync(profile, { recursive: true })
  return spawn(
    EDGE,
    [
      '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
      '--disable-extensions', '--disable-background-networking',
      '--user-data-dir=' + profile, '--remote-debugging-port=' + DEBUG_PORT,
      '--window-size=1920,1080', 'about:blank',
    ],
    { stdio: 'ignore' },
  )
}

async function evaluate(cdp, expression) {
  const result = await cdp.send('Runtime.evaluate', {
    expression: expression,
    returnByValue: true,
    awaitPromise: true,
  })
  if (result.exceptionDetails) {
    const d = result.exceptionDetails
    throw new Error((d.exception && d.exception.description) || 'error de evaluación')
  }
  return result.result.value
}

async function setViewport(cdp, viewport) {
  await cdp.send('Emulation.setDeviceMetricsOverride', {
    width: viewport.width,
    height: viewport.height,
    deviceScaleFactor: 1,
    mobile: false,
  })
}

async function screenshot(cdp, name) {
  const shot = await cdp.send('Page.captureScreenshot', { format: 'png' })
  writeFileSync(join(SHOT_DIR, name + '.png'), Buffer.from(shot.data, 'base64'))
}

/* ------------------------------------------------- construcción del fixture -- */

/* SVG 2:1 en línea: ratio intrínseco conocido para poder auditar `object-fit`. */
const IMG_2x1 =
  'data:image/svg+xml;base64,' +
  Buffer.from(
    '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100">' +
      '<rect width="200" height="100" fill="#123"/><circle cx="100" cy="50" r="34" fill="#35d0ff"/></svg>',
  ).toString('base64')

const RESEARCH = ['ENERGÍA', 'HIPERCOMBUSTIBLE', 'TECNOLOGÍA DE ESCUDOS', 'ASTROFÍSICA', 'IMPULSO']
const NAV = ['OVERVIEW', 'EDIFICIOS', 'INVESTIGACIÓN', 'HANGAR', 'DEFENSAS', 'FLOTA',
  'GALAXIA', 'EXPEDICIONES', 'LUNA', 'MENSAJES', 'SOCIAL', 'PDA']
const BODIES = ['Homeworld', 'Sector Nueve', 'Luna de Homeworld', 'Base Rho']

function researchCard(i) {
  const costs = ['METAL', 'CRISTAL', 'DEUTERIO']
    .map((label, k) => {
      const key = ['metal', 'crystal', 'deut'][k]
      const amount = (12000 * (i + 1) * (k + 1)).toLocaleString('es-ES')
      return '<span class="resource-' + key + '">' + label + '<b>' + amount + '</b></span>'
    })
    .join('')
  const stats = RESEARCH.slice(0, 2)
    .map((label, k) => '<span>' + label + '<b>' + (12 + i) * (k + 1) + '</b></span>')
    .join('')
  const extra = ['DURACIÓN', 'ENERGÍA', 'PESOS']
    .map((label, k) => '<span>' + label + '<b>' + (i + 3) * (k + 7) + '</b></span>')
    .join('')
  return [
    '<article class="neo-panel neo-definition" data-card="' + i + '">',
    '<div class="neo-panel-title"><span>⚗</span><div><strong>' + RESEARCH[i % RESEARCH.length] + '</strong>',
    '<small>Nivel ' + (i + 1) + '. Mejora el rendimiento y el consumo de la red de investigación del imperio.</small></div></div>',
    '<div class="neo-definition-media"><img src="' + IMG_2x1 + '" alt=""><span>NIVEL ' + (i + 1) + '</span></div>',
    '<div class="neo-definition-costs">' + costs + '</div>',
    '<div class="neo-definition-stats">' + stats + '</div>',
    '<div class="neo-definition-extra">' + extra + '</div>',
    '<button type="button" class="neo-button">INVESTIGAR</button>',
    '</article>',
  ].join('')
}

/* Tabla espejo de src/ui-engine/templates/*.ts, recortada a los CINCO módulos
   que el shell real monta (App.tsx -> <UIEngineScreen modules={...}>). El
   barrido de templates es lo que convierte "parece sistémico" en una respuesta
   verificable: si un template rompe la geometría, se ve aquí.
   Un módulo sin placement cae a 'main' en UIEngineScreen (fallback), que es
   justo el comportamiento que hay que reproducir. */
const TEMPLATES = {
  classic: {
    regions: ['rail', 'main', 'aside'],
    placement: {
      'resources.summary': 'main',
      'navigation.rail': 'rail',
      'navigation.main': 'main',
      'planet.bodies': 'aside',
      'fleet.launch': 'main',
    },
  },
  command: {
    regions: ['header', 'main', 'aside'],
    placement: {
      'navigation.main': 'main',
      'planet.bodies': 'aside',
      'fleet.launch': 'main',
    },
  },
  industrial: {
    regions: ['header', 'rail', 'main', 'aside', 'log', 'actions'],
    placement: {
      'resources.summary': 'header',
      'navigation.rail': 'rail',
      'navigation.main': 'main',
      'planet.bodies': 'aside',
      'fleet.launch': 'actions',
    },
  },
  minimal: {
    regions: ['header', 'main', 'aside'],
    placement: {
      'resources.summary': 'header',
      'navigation.main': 'main',
      'planet.bodies': 'aside',
      'fleet.launch': 'main',
    },
  },
  orbital: {
    regions: ['status', 'rail', 'main', 'ops', 'assets', 'actions'],
    placement: {
      'resources.summary': 'status',
      'navigation.rail': 'rail',
      'navigation.main': 'main',
      'planet.bodies': 'assets',
      'fleet.launch': 'actions',
    },
  },
  tactical: {
    regions: ['status', 'ops', 'assets', 'log', 'actions'],
    placement: {
      'resources.summary': 'status',
      'navigation.rail': 'ops',
      'navigation.main': 'log',
      'planet.bodies': 'assets',
      'fleet.launch': 'actions',
    },
  },
}

function buildRegionContent() {
  const nav = NAV.map((label, i) =>
    '<button type="button" class="neo-nav-item' + (i === 2 ? ' active' : '') + '">' +
    '<span>◈</span><b>' + label + '</b></button>').join('')

  const owned = BODIES.map((name, i) =>
    '<button type="button" class="owned-planet' + (i === 0 ? ' homeworld active' : '') + '">' +
    '<span class="owned-planet-orb">◉</span><span><strong>' + name + '</strong>' +
    '<small>1:' + (50 + i) + ':4</small></span></button>').join('')

  const cards = Array.from({ length: 12 }, (_, i) => researchCard(i)).join('')

  return {
    'resources.summary':
      '<header class="neo-header">' +
      '<div class="neo-brand"><strong>LA GRAN IMPLOSIÓN</strong><span>UNIVERSO EN EVOLUCIÓN</span>' +
      '<span class="neo-active-body">PLANETA ACTIVO: Homeworld 1:50:4</span></div>' +
      '<div class="neo-resources"><span>MET <b>1.204.338</b></span><span>CRY <b>884.021</b></span>' +
      '<span>DEU <b>402.115</b></span></div>' +
      '<button type="button" class="settings-button">&#9881;</button></header>',
    'navigation.rail':
      '<aside class="neo-sidebar">' +
      '<div class="neo-player"><span class="neo-avatar">&#128100;</span><div><small>JUGADOR</small>' +
      '<strong>Latias</strong></div></div>' +
      '<nav class="neo-nav">' + nav + '</nav></aside>',
    'navigation.main':
      '<main class="neo-main"><div class="neo-main-content">' +
      '<div class="neo-planetbar">Homeworld 1:50:4</div>' +
      '<div class="neo-main-view">' +
      '<div class="neo-section-head"><div>' +
      '<span class="neo-eyebrow">CENTRO DE CONTROL &middot; INVESTIGACIÓN</span>' +
      '<h1>Investigación</h1><p>Homeworld 1:50:4</p></div>' +
      '<span class="neo-counter">14 ELEMENTOS</span></div>' +
      '<div class="neo-card-grid">' + cards + '</div>' +
      '</div></div></main>',
    'planet.bodies':
      '<aside class="neo-owned-planets">' +
      '<div class="owned-planets-head"><span>IMPERIO</span><strong>CUERPO ACTIVO</strong></div>' +
      '<div class="owned-body-group">PLANETAS &middot; 3</div>' + owned + '</aside>',
    'fleet.launch':
      '<div class="neo-panel lgi-live-actions">' +
      '<button type="button" class="neo-button">&#9881; CONFIGURACIÓN</button></div>',
  }
}

function buildRegions(templateId) {
  const spec = TEMPLATES[templateId]
  if (!spec) throw new Error('template desconocido: ' + templateId)
  const nodes = buildRegionContent()

  /* UIEngineScreen recorre layout.order y agrupa por región DECLARADA; un módulo
     cuya región no existe cae a 'main' (o a la primera del template). Esa red de
     seguridad se reproduce aquí para no medir un layout que la app nunca monta. */
  const buckets = new Map()
  for (const region of spec.regions) buckets.set(region, [])
  const fallback = buckets.has('main') ? 'main' : spec.regions[0]
  for (const moduleId of Object.keys(nodes)) {
    const requested = spec.placement[moduleId] || 'main'
    const region = buckets.has(requested) ? requested : fallback
    buckets.get(region).push({ id: moduleId, node: nodes[moduleId] })
  }

  const sections = []
  for (const region of spec.regions) {
    const entries = buckets.get(region)
    if (!entries || entries.length === 0) continue
    const modules = entries.map((entry) =>
      '<div class="lgi-module" data-module="' + entry.id + '">' + entry.node + '</div>').join('')
    sections.push(
      '<section class="lgi-region" data-region="' + region + '" data-module-count="' +
      entries.length + '">' + modules + '</section>')
  }
  return sections.join('')
}

function buildFixture(templateId) {
  const template = readFileSync(join(HERE, 'scripts', 'layout-audit.fixture.html'), 'utf8')
  return template
    .split('<!-- FIXTURE:BEGIN -->').pop()
    .split('<!-- FIXTURE:END -->')[0]
    .replace('{{TEMPLATE}}', templateId)
    .replace('{{REGIONS}}', buildRegions(templateId))
}

/* ------------------------------------------------------------------ main -- */

const VIEWPORTS = [
  { name: 'desktop-1920', width: 1920, height: 1080 },
  { name: 'desktop-1600', width: 1600, height: 900 },
  { name: 'desktop-1440', width: 1440, height: 900 },
  { name: 'laptop-1280', width: 1280, height: 800 },
  { name: 'small-1024', width: 1024, height: 768 },
  { name: 'tablet-820', width: 820, height: 1180 },
  { name: 'mobile-390', width: 390, height: 844 },
]

const MEASURE_JS = readFileSync(join(HERE, 'scripts', 'layout-audit.measure.js'), 'utf8')
const TEMPLATE_IDS = Object.keys(TEMPLATES)

/* Filtros de un solo caso, para iterar en segundos en vez de en minutos:
     LAYOUT_AUDIT_TEMPLATE=classic LAYOUT_AUDIT_VIEWPORT=desktop-1440 */
const ONLY_TEMPLATE = process.env.LAYOUT_AUDIT_TEMPLATE || ''
const ONLY_VIEWPORT = process.env.LAYOUT_AUDIT_VIEWPORT || ''
const BREAK_NAV = process.env.LAYOUT_AUDIT_BREAK_NAV === '1'

const server = await startPreview()
const browser = startBrowser()

try {
  const cdp = await connect()
  await cdp.ready
  await cdp.send('Page.enable')
  await cdp.send('Runtime.enable')

  const report = []

  for (const templateId of TEMPLATE_IDS) {
  if (ONLY_TEMPLATE && templateId !== ONLY_TEMPLATE) continue
  for (const viewport of VIEWPORTS) {
    if (ONLY_VIEWPORT && viewport.name !== ONLY_VIEWPORT) continue
    const label = templateId + '/' + viewport.name
    await setViewport(cdp, viewport)
    await cdp.send('Page.navigate', { url: BASE })
    await sleep(1000)

    // Se espera a que el bundle haya enlazado su hoja de estilos y a que las
    // fuentes hayan resuelto: medir antes daría métricas de layout SIN styles,
    // que es precisamente el falso positivo más fácil de caer en esta auditoría.
    await evaluate(cdp, [
      '(async () => {',
      '  const links = Array.prototype.map.call(',
      "    document.querySelectorAll('link[rel=stylesheet]'), (l) => l.href)",
      '  await Promise.all(links.map((h) => new Promise((done) => {',
      "    const probe = document.createElement('link');",
      "    probe.rel = 'stylesheet'; probe.href = h;",
      '    probe.onload = done; probe.onerror = done;',
      '    document.head.appendChild(probe);',
      '  })))',
      '  if (document.fonts && document.fonts.ready) {',
      '    try { await document.fonts.ready } catch (e) {}',
      '  }',
      '  return true',
      '})()',
    ].join('\n'))

    // El fixture se cuelga de <body>, fuera de #root: así React no puede volver a
    // renderizar y borrar lo que vamos a medir. El CSS vive en <head>, intacto.
    /* INYECCIÓN DE FALLO (control negativo del propio arnés).
       Con LAYOUT_AUDIT_BREAK_NAV=1 se neutralizan las reglas que arreglarían la
       barra lateral, reproduciendo el bug original (`.neo-nav` sin regla, botones
       inline-block envueltos en dos columnas). Sirve para PROBAR QUE EL CHEQUEO
       DETECTA el fallo: un chequeo que nunca falla no prueba nada.
       Uso: LAYOUT_AUDIT_BREAK_NAV=1 node scripts/layout-audit.mjs  → debe fallar */
    if (BREAK_NAV) {
      await evaluate(cdp, [
        '(() => {',
        '  const s = document.createElement("style");',
        '  s.textContent = ".neo-nav{display:block!important}' +
          '.neo-nav-item{display:inline-block!important;width:auto!important}";',
        '  document.head.appendChild(s);',
        '  return true',
        '})()',
      ].join('\n'))
    }
    await evaluate(cdp, [
      '(() => {',
      '  document.body.innerHTML = ' + JSON.stringify(buildFixture(templateId)) + ';',
      '  return true',
      '})()',
    ].join('\n'))
    await sleep(600)

    const m = await evaluate(cdp, MEASURE_JS)
    /* `case` y no `viewport`: la medida trae su propio campo `viewport` ({w,h}),
       que si se deja después pisa la etiqueta del caso y el reporte deja de decir
       qué template/viewport es cada fila. */
    report.push(Object.assign({}, m, { case: label, template: templateId }))

    const vw = m.viewport.w
    const shellWidth = m.shell ? m.shell.width : null
    const fillsViewport = m.shell && Math.abs(shellWidth - vw) <= 1

    console.log('')
    console.log('== ' + label + ' (' + vw + 'x' + m.viewport.h + ') ==')
    console.log('   shell          : ' + (m.shell ? shellWidth + 'px  left=' + m.shell.left + ' right=' + m.shell.right : 'NO ENCONTRADO'))
    const w = (b) => (b ? b.width : '—')
    console.log('   regiones        : ' +
      Object.keys(m.regions).map((k) => k + '=' + w(m.regions[k])).join('  '))
    console.log('   columnas cards : ' + m.gridColumns)
    console.log('   card principal : ' + (m.firstCard ? m.firstCard.width + 'x' + m.firstCard.height : '—'))
    console.log('   main-content   : client=' + m.mainContent.clientWidth + ' scroll=' + m.mainContent.scrollWidth)
    console.log('   hallazgos       : overflow=' + m.overflowCount + ' overlaps=' + m.overlapCount +
      ' cardBleed=' + m.cardBleedCount + ' buttonFit=' + m.buttonFitCount)

    if (!fillsViewport) {
      note('bug', label, 'el shell NO llena el viewport: mide ' + shellWidth +
        'px de ' + vw + 'px (hueco derecho de ' + (vw - m.shell.right) + 'px)')
    }
    if (m.docOverflow.scrollWidth > m.docOverflow.clientWidth + 1) {
      note('bug', label, 'scroll horizontal de página: scrollWidth=' +
        m.docOverflow.scrollWidth + ' > clientWidth=' + m.docOverflow.clientWidth)
    }
    if (m.overflowCount > 0) {
      note('bug', label, m.overflowCount + ' caja(s) fuera del viewport: ' +
        m.overflowing.slice(0, 3).map((o) => o.el + ' +' + o.by + 'px').join(', '))
    }
    if (m.overlapCount > 0) {
      note('bug', label, m.overlapCount + ' solapamiento(s): ' +
        m.overlaps.slice(0, 3).map((o) => o.a + ' ∩ ' + o.b + ' (' + o.overlapX + 'x' + o.overlapY + ')').join(' | '))
    }
    if (m.cardBleedCount > 0) {
      note('bug', label, m.cardBleedCount + ' contenido(s) fuera de su tarjeta: ' +
        m.cardBleed.slice(0, 3).map((c) => c.el + ' +' + c.bleedBottom + 'px').join(', '))
    }
    if (m.buttonFitCount > 0) {
      note('bug', label, m.buttonFitCount + ' botón(es) recortado(s) o con tamaño cero')
    }
    if (m.mainContent.scrollWidth > m.mainContent.clientWidth + 1) {
      note('bug', label, 'el contenido central scrollea en horizontal: ' +
        m.mainContent.scrollWidth + ' > ' + m.mainContent.clientWidth)
    }
    for (const img of m.images) {
      if (img.fit === 'fill') {
        note('bug', label, 'imagen con object-fit:fill — deforma el ratio (' +
          img.natural.join('x') + ' → ' + img.renderedRatio + ')')
      }
    }
    /* La barra lateral es una lista; en móvil es una tira horizontal a propósito. */
    if (m.nav && m.nav.items > 1 && m.nav.stacked === false && viewport.width > 760) {
      note('bug', label, 'la navegación lateral NO es una lista: ' + m.nav.items +
        ' apartados se reparten en varias columnas (primero descentrado: item #' +
        m.nav.offending[0].index + ' left=' + m.nav.offending[0].left + ' vs ' +
        'ancho ' + m.nav.container.width + ')')
    }

    await screenshot(cdp, templateId + '-' + viewport.name)
  }
  }

  writeFileSync(join(SHOT_DIR, 'report.json'), JSON.stringify(report, null, 2))

  const hard = findings.filter((f) => f.severity === 'bug')
  console.log('')
  console.log('=================================================================')
  console.log('HALLAZGOS: ' + hard.length + ' bug(s), ' + (findings.length - hard.length) + ' aviso(s)')
  console.log('Capturas : ' + SHOT_DIR)
  process.exitCode = hard.length > 0 ? 1 : 0
} finally {
  try { browser.kill() } catch (e) {}
  try { server.kill() } catch (e) {}
}
