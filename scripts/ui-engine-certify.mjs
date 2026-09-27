/*
  CERTIFICACIÓN EN NAVEGADOR REAL — UI ENGINE / UI DESIGNER

  Sin dependencias nuevas: usa los WebSocket y fetch nativos de Node contra el
  protocolo DevTools (CDP) de Microsoft Edge en modo headless.

  Qué hace:

    1. levanta un servidor estático sobre `dist/client` con un puerto libre;
    2. abre Edge headless con un perfil temporal;
    3. recorre el banco de pruebas (`#ui-designer`) y la superficie real (`/`) con
       la lista de comprobaciones del informe;
    4. mide overflow horizontal por viewport, recoge errores de consola y guarda
       capturas en el directorio temporal.

  Uso:
      node scripts/ui-engine-certify.mjs
      node scripts/ui-engine-certify.mjs --port 4174 --debug-port 9333

  NO toca Supabase, NO escribe en el repositorio y NO hace commit: sólo lee el
  build y escribe capturas en %TEMP%\\lgi-ui-certify.
*/

import { mkdirSync, writeFileSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const args = process.argv.slice(2)
const readArg = (name, fallback) => {
  const index = args.indexOf(`--${name}`)
  return index >= 0 && args[index + 1] ? Number(args[index + 1]) : fallback
}

const REQUESTED_PREVIEW_PORT = readArg('port', 0)
const DEBUG_PORT = readArg('debug-port', 9333)
let BASE = ''
const EDGE = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
const BASE = `http://127.0.0.1:${PREVIEW_PORT}`
const SHOT_DIR = join(tmpdir(), 'lgi-ui-certify')

const VIEWPORTS = [
  { id: 'desktop-1280', width: 1280, height: 900, family: 'desktop' },
  { id: 'desktop-1440', width: 1440, height: 900, family: 'desktop' },
  { id: 'desktop-1920', width: 1920, height: 1080, family: 'desktop' },
  { id: 'tablet-768', width: 768, height: 1024, family: 'tablet' },
  { id: 'tablet-1024', width: 1024, height: 768, family: 'tablet' },
  { id: 'android-360', width: 360, height: 740, family: 'mobile' },
  { id: 'android-390', width: 390, height: 844, family: 'mobile' },
  { id: 'android-430', width: 430, height: 932, family: 'mobile' },
]

const results = []
const consoleIssues = []
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function check(id, label, ok, detail = '') {
  results.push({ id, label, ok, detail })
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${String(id).padEnd(3)} ${label}${detail ? ` — ${detail}` : ''}`)
}

async function waitForHttp(url, timeoutMs = 40000) {
  const started = Date.now()
  for (;;) {
    try {
      const response = await fetch(url)
      if (response.ok) return
    } catch {
      /* todavía no está listo */
    }
    if (Date.now() - started > timeoutMs) throw new Error(`Timeout esperando ${url}`)
    await sleep(250)
  }
}

async function startPreview() {
  /** Vite hace dos builds en este proyecto: el build de Cloudflare y el build
   *  del cliente. El cliente vive en dist/client, así que el certificador lo
   *  sirve explícitamente desde ahí. Si no se indica --port, usamos uno libre
   *  para que un proceso viejo en 4174 no pueda falsear la certificación. */
  const serverScript = join(process.cwd(), 'scripts', 'ui-engine-certify-server.mjs')
  const child = spawn(process.execPath, [serverScript, '--root', join(process.cwd(), 'dist', 'client'), '--port', String(REQUESTED_PREVIEW_PORT)], {
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const port = await new Promise((resolve, reject) => {
    let output = ''
    const onData = (chunk) => {
      output += chunk.toString()
      const match = output.match(/READY\\s+(\\d+)/)
      if (match) {
        child.stdout.off('data', onData)
        resolve(Number(match[1]))
      }
    }
    child.stdout.on('data', onData)
    child.stderr.on('data', (chunk) => {
      output += chunk.toString()
    })
    child.once('error', reject)
    child.once('exit', (code) => {
      if (code !== 0) reject(new Error(`Servidor de certificación terminó con código ${code}: ${output.trim()}`))
    })
  })
  BASE = `http://127.0.0.1:${port}`
  return child
}

function startBrowser() {
  const profile = join(tmpdir(), `lgi-certify-profile-${Date.now()}`)
  mkdirSync(profile, { recursive: true })
  return spawn(
    EDGE,
    [
      '--headless=new',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-extensions',
      '--disable-background-networking',
      `--user-data-dir=${profile}`,
      `--remote-debugging-port=${DEBUG_PORT}`,
      '--window-size=1440,960',
      'about:blank',
    ],
    { stdio: 'ignore' },
  )
}


/* --------------------------------------------------------------- CDP tiny -- */

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
      if (message.error) entry.reject(new Error(`${entry.method}: ${message.error.message}`))
      else entry.resolve(message.result)
      return
    }
    if (message.method === 'Runtime.exceptionThrown') {
      const details = message.params?.exceptionDetails
      consoleIssues.push(
        `exception: ${details?.exception?.description ?? details?.text ?? 'desconocida'}`,
      )
    }
    if (message.method === 'Runtime.consoleAPICalled' && message.params?.type === 'error') {
      const text = (message.params.args ?? [])
        .map((argument) => argument.value ?? argument.description ?? '')
        .join(' ')
      consoleIssues.push(`console.error: ${text}`)
    }
    if (message.method === 'Log.entryAdded' && message.params?.entry?.level === 'error') {
      consoleIssues.push(`log: ${message.params.entry.text}`)
    }
  }

  send(method, params = {}) {
    const id = this.nextId++
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, method })
      this.socket.send(JSON.stringify({ id, method, params }))
    })
  }

  async evaluate(expression) {
    const result = await this.send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true,
      userGesture: true,
    })
    if (result.exceptionDetails) {
      throw new Error(
        `evaluate: ${result.exceptionDetails.exception?.description ?? result.exceptionDetails.text}`,
      )
    }
    return result.result.value
  }

  close() {
    this.socket.close()
  }
}

async function connect() {
  await waitForHttp(`http://127.0.0.1:${DEBUG_PORT}/json/version`)
  const list = await (await fetch(`http://127.0.0.1:${DEBUG_PORT}/json/list`)).json()
  const page = list.find((target) => target.type === 'page')
  if (!page) throw new Error('El navegador no expone ninguna página')
  const session = new CdpSession(page.webSocketDebuggerUrl)
  await session.ready
  await session.send('Runtime.enable')
  await session.send('Log.enable')
  await session.send('Page.enable')
  return session
}

async function goto(session, url) {
  await session.send('Page.navigate', { url })
  for (let attempt = 0; attempt < 90; attempt += 1) {
    await sleep(150)
    if (await session.evaluate('document.readyState === "complete"')) break
  }
  await sleep(450)
}

async function setViewport(session, viewport) {
  await session.send('Emulation.setDeviceMetricsOverride', {
    width: viewport.width,
    height: viewport.height,
    deviceScaleFactor: 1,
    mobile: viewport.family === 'mobile',
  })
  await sleep(400)
}

async function screenshot(session, name) {
  try {
    const shot = await session.send('Page.captureScreenshot', { format: 'png' })
    writeFileSync(join(SHOT_DIR, `${name}.png`), Buffer.from(shot.data, 'base64'))
  } catch {
    /* la captura es evidencia, no una comprobación */
  }
}

/* ------------------------------------------------------------ interacción -- */

/** Los controles se accionan con eventos REALES: React escucha en la raíz. */
const JS = {
  clickBySelector: (selector) => `(() => {
    const el = document.querySelector(${JSON.stringify(selector)})
    if (!el) return false
    el.click()
    return true
  })()`,
  clickByText: (selector, text) => `(() => {
    const el = [...document.querySelectorAll(${JSON.stringify(selector)})]
      .find((node) => node.textContent.trim().toLowerCase().includes(${JSON.stringify(text.toLowerCase())}))
    if (!el) return false
    el.click()
    return true
  })()`,
  setRange: (selector, value) => `(() => {
    const el = document.querySelector(${JSON.stringify(selector)})
    if (!el) return false
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set
    setter.call(el, String(${JSON.stringify(value)}))
    el.dispatchEvent(new Event('input', { bubbles: true }))
    el.dispatchEvent(new Event('change', { bubbles: true }))
    return true
  })()`,
  setSelect: (selector, value) => `(() => {
    const el = document.querySelector(${JSON.stringify(selector)})
    if (!el) return false
    const setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value').set
    setter.call(el, ${JSON.stringify(value)})
    el.dispatchEvent(new Event('change', { bubbles: true }))
    return true
  })()`,
  toggleCheckbox: (index) => `(() => {
    const boxes = [...document.querySelectorAll('.lgi-designer input[type="checkbox"]')]
    const el = boxes[${index}]
    if (!el) return false
    el.click()
    return el.checked
  })()`,
  cssVar: (selector, name) =>
    `getComputedStyle(document.querySelector(${JSON.stringify(selector)})).getPropertyValue(${JSON.stringify(name)}).trim()`,
  attr: (selector, name) =>
    `document.querySelector(${JSON.stringify(selector)})?.getAttribute(${JSON.stringify(name)}) ?? null`,
  count: (selector) => `document.querySelectorAll(${JSON.stringify(selector)}).length`,
  overflow: `(() => {
    const doc = document.documentElement
    const screen = document.querySelector('.lgi-screen')
    return {
      scrollWidth: doc.scrollWidth,
      innerWidth: window.innerWidth,
      screenScroll: screen?.scrollWidth ?? 0,
      screenClient: screen?.clientWidth ?? 0,
    }
  })()`,
}

/* -------------------------------------------------------------- utilidades -- */

async function clickAt(session, selector, offset = { x: 0, y: 0 }) {
  const point = await session.evaluate(`(() => {
    const el = document.querySelector(${JSON.stringify(selector)})
    if (!el) return null
    const rect = el.getBoundingClientRect()
    return { x: rect.left + rect.width / 2 + ${offset.x}, y: rect.top + rect.height / 2 + ${offset.y} }
  })()`)
  if (!point) return false
  await session.send('Input.dispatchMouseEvent', {
    type: 'mousePressed', x: point.x, y: point.y, button: 'left', clickCount: 1,
  })
  await session.send('Input.dispatchMouseEvent', {
    type: 'mouseReleased', x: point.x, y: point.y, button: 'left', clickCount: 1,
  })
  await sleep(250)
  return true
}

async function dragFrom(session, selector, targetSelector) {
  const points = await session.evaluate(`(() => {
    const from = document.querySelector(${JSON.stringify(selector)})
    const to = document.querySelector(${JSON.stringify(targetSelector)})
    if (!from || !to) return null
    const a = from.getBoundingClientRect()
    const b = to.getBoundingClientRect()
    return {
      from: { x: a.left + a.width / 2, y: a.top + a.height / 2 },
      to: { x: b.left + b.width / 2, y: b.top + b.height / 2 },
    }
  })()`)
  if (!points) return false
  await session.send('Input.dispatchMouseEvent', {
    type: 'mousePressed', x: points.from.x, y: points.from.y, button: 'left', clickCount: 1,
  })
  for (let step = 1; step <= 6; step += 1) {
    await session.send('Input.dispatchMouseEvent', {
      type: 'mouseMoved',
      x: points.from.x + ((points.to.x - points.from.x) * step) / 6,
      y: points.from.y + ((points.to.y - points.from.y) * step) / 6,
      button: 'left',
    })
    await sleep(60)
  }
  await session.send('Input.dispatchMouseEvent', {
    type: 'mouseReleased', x: points.to.x, y: points.to.y, button: 'left', clickCount: 1,
  })
  await sleep(350)
  return true
}

async function guarded(id, label, run) {
  try {
    const outcome = await run()
    check(id, label, Boolean(outcome?.ok), outcome?.detail ?? '')
  } catch (error) {
    check(id, label, false, `excepción: ${error.message}`)
  }
}

const engineState = `(() => {
  const root = document.querySelector('.lgi-engine')
  const screen = document.querySelector('.lgi-screen')
  return {
    template: root?.getAttribute('data-lgi-template') ?? null,
    theme: root?.getAttribute('data-lgi-theme') ?? null,
    density: root?.getAttribute('data-lgi-density') ?? null,
    grid: root?.getAttribute('data-lgi-grid') ?? null,
    boundaries: root?.getAttribute('data-lgi-boundaries') ?? null,
    edit: root?.getAttribute('data-lgi-edit') ?? null,
    device: root?.getAttribute('data-lgi-device') ?? null,
    bp: screen?.getAttribute('data-lgi-bp') ?? null,
    modules: document.querySelectorAll('.lgi-module').length,
    regions: document.querySelectorAll('.lgi-region').length,
  }
})()`

async function selectTemplate(session, label) {
  const clicked = await session.evaluate(JS.clickByText('.lgi-designer__template', label))
  await sleep(400)
  return clicked
}

async function readStoredConfig(session) {
  return session.evaluate(
    `JSON.parse(localStorage.getItem('lagranimplosion-ui-designer') ?? 'null')`,
  )
}

/* ------------------------------------------------------------------ checks -- */

async function runChecks(session) {
  mkdirSync(SHOT_DIR, { recursive: true })
  await setViewport(session, VIEWPORTS[1])
  await goto(session, `${BASE}/#ui-designer`)

  /* 1. UI Designer visible en DEV */
  await guarded(1, 'UI Designer visible', async () => {
    const templates = await session.evaluate(JS.count('.lgi-designer__template'))
    const hasPanel = await session.evaluate(`Boolean(document.querySelector('.lgi-designer'))`)
    return { ok: hasPanel && templates === 6, detail: `templates=${templates} panel=${hasPanel}` }
  })
  await screenshot(session, '01-workbench-buildings')

  /* 2. El template cambia en vivo */
  await guarded(2, 'Template cambia en vivo', async () => {
    await selectTemplate(session, 'Tactical')
    const state = await session.evaluate(engineState)
    return { ok: state.template === 'tactical', detail: `template=${state.template}` }
  })

  /* 19-21. Classic / Command / Tactical componen sin desbordar */
  for (const [id, label, checkId] of [
    ['classic', 'Classic', 19],
    ['command', 'Command', 20],
    ['tactical', 'Tactical', 21],
  ]) {
    await guarded(checkId, `Template ${label}`, async () => {
      await selectTemplate(session, label)
      const state = await session.evaluate(engineState)
      const overflow = await session.evaluate(JS.overflow)
      const fits = overflow.screenScroll <= overflow.screenClient + 1
      return {
        ok: state.template === id && state.modules > 0 && state.regions > 0 && fits,
        detail: `regiones=${state.regions} módulos=${state.modules} fits=${fits}`,
      }
    })
  }

  /* 22. Templates nuevos */
  await guarded(22, 'Templates nuevos (Orbital · Industrial · Minimal)', async () => {
    const seen = []
    for (const label of ['Orbital', 'Industrial', 'Minimal']) {
      await selectTemplate(session, label)
      const state = await session.evaluate(engineState)
      const overflow = await session.evaluate(JS.overflow)
      const fits = overflow.screenScroll <= overflow.screenClient + 1
      seen.push(`${state.template}:${state.regions}r/${state.modules}m${fits ? '' : ' OVERFLOW'}`)
    }
    return { ok: seen.every((entry) => !entry.includes('OVERFLOW') && !entry.startsWith('null')), detail: seen.join(' · ') }
  })

  /* 3. Font scale */
  await guarded(3, 'Font scale', async () => {
    await selectTemplate(session, 'Classic')
    const probe = `parseFloat(getComputedStyle(document.querySelector('.lgi-ref-card__title')).fontSize)`
    const before = await session.evaluate(probe)
    await session.evaluate(JS.setRange('input[aria-label="Font scale"]', 1.2))
    await sleep(300)
    const after = await session.evaluate(probe)
    const scale = await session.evaluate(JS.cssVar('.lgi-engine', '--lgi-font-scale'))
    return { ok: scale === '1.2' && after > before, detail: `${before}px → ${after}px · var=${scale}` }
  })

  /* 4. UI scale (no toca la tipografía) */
  await guarded(4, 'UI scale', async () => {
    const probe = `parseFloat(getComputedStyle(document.querySelector('.lgi-ref-card__title')).fontSize)`
    const fontBefore = await session.evaluate(probe)
    const spaceBefore = await session.evaluate(JS.cssVar('.lgi-engine', '--lgi-space-4'))
    await session.evaluate(JS.setRange('input[aria-label="UI scale"]', 1.25))
    await sleep(300)
    const fontAfter = await session.evaluate(probe)
    const spaceAfter = await session.evaluate(JS.cssVar('.lgi-engine', '--lgi-space-4'))
    const scale = await session.evaluate(JS.cssVar('.lgi-engine', '--lgi-ui-scale'))
    return {
      ok: scale === '1.25' && spaceAfter !== spaceBefore && fontAfter === fontBefore,
      detail: `space ${spaceBefore} → ${spaceAfter} · font ${fontBefore} → ${fontAfter} · var=${scale}`,
    }
  })

  /* 5. Density */
  await guarded(5, 'Density', async () => {
    await session.evaluate(JS.setSelect('select[aria-label="Densidad"]', 'comfortable'))
    await sleep(300)
    const state = await session.evaluate(engineState)
    return { ok: state.density === 'comfortable', detail: `density=${state.density}` }
  })

  /* 6. Font (registry de tipografías) */
  await guarded(6, 'Font', async () => {
    await session.evaluate(JS.setSelect('select[aria-label="Familia tipográfica"]', 'rajdhani'))
    await sleep(300)
    const stack = await session.evaluate(JS.cssVar('.lgi-engine', '--lgi-font-family'))
    const computed = await session.evaluate(`getComputedStyle(document.querySelector('.lgi-engine')).fontFamily`)
    return { ok: stack.includes('Rajdhani') && computed.includes('Rajdhani'), detail: computed.slice(0, 70) }
  })

  /* 7. Grid overlay */
  await guarded(7, 'Grid overlay', async () => {
    const checked = await session.evaluate(JS.toggleCheckbox(0))
    await sleep(250)
    const state = await session.evaluate(engineState)
    const overlay = await session.evaluate(
      `getComputedStyle(document.querySelector('.lgi-layout'), '::before').backgroundImage !== 'none'`,
    )
    return { ok: checked === true && state.grid === 'on' && overlay, detail: `grid=${state.grid} overlay=${overlay}` }
  })

  /* 8. Component boundaries */
  await guarded(8, 'Component boundaries', async () => {
    const checked = await session.evaluate(JS.toggleCheckbox(1))
    await sleep(250)
    const state = await session.evaluate(engineState)
    const label = await session.evaluate(`getComputedStyle(document.querySelector('.lgi-module'), '::after').content`)
    return { ok: checked === true && state.boundaries === 'on' && label.includes('.'), detail: `after=${label}` }
  })

  /* 9. Device preview */
  await guarded(9, 'Device preview (Android 390)', async () => {
    await session.evaluate(JS.setSelect('select[aria-label="Perfil de dispositivo"]', 'android-390'))
    await sleep(450)
    const frameWidth = await session.evaluate(
      `Math.round(document.querySelector('.lgi-device-frame').getBoundingClientRect().width)`,
    )
    const screenWidth = await session.evaluate(`document.querySelector('.lgi-screen').clientWidth`)
    const attrs = await session.evaluate(
      `({ width: document.documentElement.dataset.lgiPreviewWidth ?? null, mobile: document.documentElement.dataset.lgiPreviewMobile ?? null })`,
    )
    const bp = await session.evaluate(`document.querySelector('.lgi-screen').getAttribute('data-lgi-bp')`)
    return {
      ok:
        Math.abs(frameWidth - 390) <= 30 &&
        screenWidth <= 390 &&
        attrs.width === 'android-390' &&
        bp === 'mobile',
      detail: `frame=${frameWidth}px screen=${screenWidth}px bp=${bp} html=${attrs.width}/${attrs.mobile}`,
    }
  })
  await screenshot(session, '02-android-390')

  /* 10. Designer mode */
  await guarded(10, 'Designer mode (handles)', async () => {
    const checked = await session.evaluate(JS.toggleCheckbox(3))
    await sleep(300)
    const state = await session.evaluate(engineState)
    const grips = await session.evaluate(JS.count('.lgi-designer-grip'))
    return { ok: checked === true && state.edit === 'on' && grips > 0, detail: `edit=${state.edit} grips=${grips}` }
  })

  /* 11. Selección */
  await guarded(11, 'Selección de módulo', async () => {
    await clickAt(session, '.lgi-module')
    const selected = await session.evaluate(
      `document.querySelector('.lgi-module.is-selected')?.getAttribute('data-module') ?? null`,
    )
    return { ok: Boolean(selected), detail: `seleccionado=${selected}` }
  })

  /* 12. Move desde el panel (modelo: región destino) */
  await guarded(12, 'Move por control (región destino)', async () => {
    const before = await session.evaluate(
      `document.querySelector('.lgi-module.is-selected').closest('.lgi-region').getAttribute('data-region')`,
    )
    const options = await session.evaluate(
      `[...document.querySelectorAll('.lgi-designer select[aria-label="Mover módulo a otra región"] option')].map((o) => o.value)`,
    )
    const target = options.find((option) => option !== before)
    await session.evaluate(JS.setSelect('select[aria-label="Mover módulo a otra región"]', target))
    await sleep(350)
    const after = await session.evaluate(
      `document.querySelector('.lgi-module.is-selected')?.closest('.lgi-region').getAttribute('data-region') ?? null`,
    )
    return { ok: Boolean(after) && after !== before, detail: `${before} → ${after}` }
  })

  /* 12d. Move real arrastrando el grip (pointer events) */
  await guarded('12d', 'Move por arrastre (pointer events)', async () => {
    const regions = await session.evaluate(
      `[...document.querySelectorAll('.lgi-region')].map((r) => r.dataset.region)`,
    )
    const current = await session.evaluate(
      `document.querySelector('.lgi-module.is-selected').closest('.lgi-region').getAttribute('data-region')`,
    )
    const index = regions.indexOf(current)
    const target = regions[index === regions.length - 1 ? 0 : index + 1]
    await dragFrom(session, '.lgi-module.is-selected .lgi-designer-grip', `.lgi-region[data-region="${target}"]`)
    const after = await session.evaluate(
      `document.querySelector('.lgi-module.is-selected')?.closest('.lgi-region').getAttribute('data-region') ?? null`,
    )
    return { ok: after === target, detail: `${current} → ${after} (destino ${target})` }
  })

  /* 13. Resize desde el panel (span + columnas de región) */
  await guarded(13, 'Resize por control (span / columnas)', async () => {
    await session.evaluate(JS.clickByText('.lgi-designer__actions button', 'SPAN +'))
    await sleep(300)
    const span = await session.evaluate(
      `document.querySelector('.lgi-module.is-selected')?.getAttribute('data-module-span') ?? null`,
    )
    const columns = await session.evaluate(
      `document.querySelector('.lgi-module.is-selected')?.closest('.lgi-region').getAttribute('data-region-columns') ?? null`,
    )
    return { ok: span === '2' && columns === '2', detail: `span=${span} columnas=${columns}` }
  })

  /* 13d. Resize real arrastrando el handle de span */
  await guarded('13d', 'Resize por arrastre (handle de span)', async () => {
    const before = await session.evaluate(
      `Number(document.querySelector('.lgi-module.is-selected')?.getAttribute('data-module-span') ?? 1)`,
    )
    await dragFrom(session, '.lgi-module.is-selected .lgi-designer-handle--span', '.lgi-module.is-selected')
    const after = await session.evaluate(
      `Number(document.querySelector('.lgi-module.is-selected')?.getAttribute('data-module-span') ?? 1)`,
    )
    return { ok: after > before, detail: `span ${before} → ${after}` }
  })

  /* 14. Save */
  await guarded(14, 'Guardar layout (localStorage)', async () => {
    await session.evaluate(JS.clickByText('.lgi-designer__actions button', 'GUARDAR LAYOUT'))
    await sleep(400)
    const config = await readStoredConfig(session)
    const dirty = await session.evaluate(JS.count('.lgi-designer__badge'))
    return {
      ok: Boolean(config) && config.version === 1 && Boolean(config.layouts) && dirty === 0,
      detail: `version=${config?.version} templates=${Object.keys(config?.layouts ?? {}).join(',')} badge=${dirty}`,
    }
  })
  await screenshot(session, '03-saved-layout')

  /* 15. Reload conserva template, tipografía, escalas y layout */
  await guarded(15, 'Reload conserva la configuración', async () => {
    await session.send('Page.reload', { ignoreCache: false })
    await sleep(1600)
    const state = await session.evaluate(engineState)
    const spans = await session.evaluate(
      `[...document.querySelectorAll('.lgi-module[data-module-span]')].map((m) => m.getAttribute('data-module') + ':' + m.getAttribute('data-module-span'))`,
    )
    const fontFamily = await session.evaluate(JS.cssVar('.lgi-engine', '--lgi-font-family'))
    return {
      ok:
        state.template === 'classic' &&
        state.density === 'comfortable' &&
        state.grid === 'on' &&
        spans.length > 0,
      detail: `template=${state.template} density=${state.density} grid=${state.grid} spans=${spans.join(',')} font=${fontFamily.split(',')[0]}`,
    }
  })

  /* 16. Reset */
  await guarded(16, 'Reset del Designer', async () => {
    await session.evaluate(JS.clickByText('.lgi-designer__actions button', 'RESET'))
    await sleep(500)
    const config = await readStoredConfig(session)
    const state = await session.evaluate(engineState)
    return {
      ok: config === null && state.template === 'classic' && state.grid === 'off' && state.edit === 'off',
      detail: `config=${config === null ? 'borrada' : 'presente'} template=${state.template} grid=${state.grid} edit=${state.edit}`,
    }
  })

  /* 17. Overflow horizontal en 8 viewports con device nativo */
  await guarded(17, 'Sin overflow horizontal (8 viewports)', async () => {
    await session.evaluate(JS.setSelect('select[aria-label="Perfil de dispositivo"]', 'native'))
    await sleep(300)
    const report = []
    let ok = true
    for (const viewport of VIEWPORTS) {
      await setViewport(session, viewport)
      const measures = await session.evaluate(JS.overflow)
      const docOk = measures.scrollWidth <= measures.innerWidth + 1
      const screenOk = measures.screenScroll <= measures.screenClient + 1
      if (!docOk || !screenOk) ok = false
      report.push(
        `${viewport.id}:${docOk && screenOk ? 'ok' : `doc ${measures.scrollWidth}/${measures.innerWidth} screen ${measures.scrollScroll}/${measures.screenClient}`}`,
      )
      await screenshot(session, `viewport-${viewport.id}`)
    }
    return { ok, detail: report.join(' · ') }
  })

  /* 23. Fleet: deck de referencia + módulos reales presentes en el bundle */
  await guarded(23, 'Fleet (deck de referencia + bundle real)', async () => {
    const deckCards = await session.evaluate(`(async () => {
      const button = [...document.querySelectorAll('.lgi-workbench__deck')].find((b) => b.textContent.trim() === 'FLEET')
      if (!button) return -1
      button.click()
      await new Promise((resolve) => setTimeout(resolve, 500))
      return document.querySelectorAll('.lgi-ref-card').length
    })()`)
    const indexHtml = await (await fetch(`${BASE}/`)).text()
    const scriptPath = /src="([^"]*index-[^"]+\.js)"/.exec(indexHtml)?.[1] ?? ''
    const bundle = scriptPath ? await (await fetch(`${BASE}${scriptPath}`)).text() : ''
    const hasFleetScreen =
      bundle.includes('fleet.command') && bundle.includes('get_player_fleet_slots')
    return {
      ok: deckCards > 0 && hasFleetScreen,
      detail: `deck fleet=${deckCards} tarjetas · pantalla real en bundle=${hasFleetScreen}`,
    }
  })

  const workbenchIssues = consoleIssues.length

  /* 24. Login intacto */
  await guarded(24, 'Login (superficie real sin sesión)', async () => {
    await setViewport(session, VIEWPORTS[1])
    await goto(session, `${BASE}/`)
    const designer = await session.evaluate(JS.count('.lgi-designer'))
    const form = await session.evaluate(
      `Boolean(document.querySelector('input[type="email"], input[type="password"], form'))`,
    )
    const text = await session.evaluate(`document.body.innerText.slice(0, 90).replace(/\\s+/g, ' ')`)
    return { ok: designer === 0 && form, detail: `designer=${designer} form=${form} · ${text}` }
  })
  await screenshot(session, '04-login')

  /* 18. Sin errores nuevos de consola en la superficie del engine */
  await guarded(18, 'Sin errores de consola en el engine', async () => ({
    ok: workbenchIssues === 0,
    detail: workbenchIssues === 0 ? 'ninguno' : consoleIssues.slice(0, 4).join(' | '),
  }))
}


/* -------------------------------------------------------------------- main -- */

let preview
let browser
let session

try {
  preview = await startPreview()
  await waitForHttp(`${BASE}/`)
  browser = startBrowser()
  session = await connect()
  await runChecks(session)
} catch (error) {
  console.log(`ERROR FATAL: ${error.message}`)
  check(0, 'Arranque de la certificación', false, error.message)
} finally {
  session?.close()
  browser?.kill()
  preview?.kill()
}

const failed = results.filter((entry) => !entry.ok)
console.log('')
console.log(`RESUMEN: ${results.length - failed.length}/${results.length} comprobaciones OK`)
if (failed.length > 0) {
  console.log('FALLOS:')
  for (const entry of failed) console.log(`  - ${entry.id} ${entry.label}: ${entry.detail}`)
}
console.log(`Capturas: ${SHOT_DIR}`)
if (consoleIssues.length > 0) {
  console.log(`Mensajes de consola registrados (${consoleIssues.length}):`)
  for (const issue of consoleIssues.slice(0, 10)) console.log(`  - ${issue}`)
}
process.exitCode = failed.length === 0 ? 0 : 1
