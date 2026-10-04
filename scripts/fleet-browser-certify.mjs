/* =============================================================================
   CERTIFICACIÓN BROWSER DEL FLUJO DE FLOTAS — runtime con credencial DEV real
   -----------------------------------------------------------------------------
   Reutiliza la MISMA infraestructura CDP nativa de `ui-engine-certify.mjs`
   (Edge headless + WebSocket nativo, CERO dependencias: no Playwright/Puppeteer/
   Cypress/Selenium) y su servidor estático. No se instala ningún framework.

   CREDENCIALES — RUNTIME ONLY. Se leen de `process.env`:
       DEV_EMAIL
       DEV_PASSWORD
   NO se escriben en el repo, ni en `.env`, ni en logs, ni en capturas.
   Si faltan, el script NO simula nada: lo dice y termina.

   Este script SÓLO acciona la UI real. La verificación auxiliar en base de datos
   la hace el operador después, como evidencia (nunca en lugar del browser).

   Uso (PowerShell):
       $env:DEV_EMAIL = "..."; $env:DEV_PASSWORD = "..."
       node scripts/fleet-browser-certify.mjs
   ========================================================================== */

import { mkdirSync, writeFileSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const DEV_EMAIL = process.env.DEV_EMAIL ?? ''
const DEV_PASSWORD = process.env.DEV_PASSWORD ?? ''

if (!DEV_EMAIL || !DEV_PASSWORD) {
  console.log('ENVIRONMENT BLOCKED — DEV CREDENTIAL UNAVAILABLE')
  console.log('Define DEV_EMAIL y DEV_PASSWORD en el entorno. NO se simula el login.')
  process.exit(2)
}

const readArg = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`)
  return index >= 0 && process.argv[index + 1] ? Number(process.argv[index + 1]) : fallback
}

const DEBUG_PORT = readArg('debug-port', 9444)
/* LÍMITE DE PASO (misión 2026-10-03).
   `CERTIFY_MAX_STEP` corta el recorrido en el paso indicado. Por defecto (o ausente) NO cambia
   nada: se ejecutan los 9 pasos, igual que siempre. Sirve para correr la parte de DIAGNÓSTICO
   (1-7: login, navegación, selectores, gate del botón) sin tocar datos del jugador, porque
   el paso 8 pulsa LANZAR con una selección inválida y el 9 hace un DESPACHO REAL.
   Uso:  CERTIFY_MAX_STEP=7 node scripts/fleet-browser-certify.mjs            (diagnóstico)
         node scripts/fleet-browser-certify.mjs                             (recorrido completo) */
const MAX_STEP = Number(process.env.CERTIFY_MAX_STEP ?? '99')
const MUTATING_STEP = 8   // desde aquí el recorrido puede escribir en el mundo del jugador
const EDGE = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
const SHOT_DIR = join(tmpdir(), 'lgi-fleet-certify')
const VIEWPORT = { width: 1440, height: 900, family: 'desktop' }
let BASE = ''

mkdirSync(SHOT_DIR, { recursive: true })

const results = []
const consoleIssues = []
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function check(id, label, ok, detail = '') {
  results.push({ id, label, ok, detail })
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${String(id).padEnd(3)} ${label}${detail ? ` — ${detail}` : ''}`)
}

async function guarded(id, label, run) {
  if (id > MAX_STEP) {
    check(id, label, true, `OMITIDO (CERTIFY_MAX_STEP=${MAX_STEP}) — paso ${id >= MUTATING_STEP ? 'que muta datos' : 'posterior'} no ejecutado`)
    return null
  }
  try {
    const outcome = await run()
    check(id, label, Boolean(outcome?.ok), outcome?.detail ?? '')
    return Boolean(outcome?.ok)
  } catch (error) {
    check(id, label, false, `excepción: ${error.message}`)
    return false
  }
}

async function waitForHttp(url, attempts = 120) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      const response = await fetch(url)
      if (response.ok) return true
    } catch {
      /* aún no levanta */
    }
    await sleep(150)
  }
  return false
}

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
      consoleIssues.push(`exception: ${details?.exception?.description ?? details?.text ?? 'desconocida'}`)
    }
    if (message.method === 'Runtime.consoleAPICalled' && message.params?.type === 'error') {
      const text = (message.params.args ?? []).map((a) => a.value ?? a.description ?? '').join(' ')
      consoleIssues.push(`console.error: ${text}`)
    }
    if (message.method === 'Log.entryAdded' && message.params?.entry?.level === 'error') {
      consoleIssues.push(`log: ${message.params.entry.text}`)
    }
  }

  send(method, params = {}) {
    const id = this.nextId++
    return new Promise((resolve, reject) => {
      /* La clave DEBE ser el id: onMessage busca con pending.get(message.id). */
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
      throw new Error(result.exceptionDetails.exception?.description ?? result.exceptionDetails.text)
    }
    return result.result.value
  }

  close() { this.socket.close() }
}

async function connect() {
  process.stdout.write('[connect] esperando /json/version...\n')
  await waitForHttp(`http://127.0.0.1:${DEBUG_PORT}/json/version`)
  process.stdout.write('[connect] /json/version ok, listando targets...\n')
  const list = await (await fetch(`http://127.0.0.1:${DEBUG_PORT}/json/list`)).json()
  const page = list.find((target) => target.type === 'page')
  if (!page) throw new Error('El navegador no expone ninguna página')
  process.stdout.write(`[connect] target=${page.type} ws=${Boolean(page.webSocketDebuggerUrl)}\n`)
  const session = new CdpSession(page.webSocketDebuggerUrl)
  process.stdout.write('[connect] abriendo WebSocket...\n')
  await session.ready
  process.stdout.write('[connect] WebSocket abierto\n')
  await session.send('Runtime.enable')
  await session.send('Log.enable')
  await session.send('Page.enable')
  process.stdout.write('[connect] dominios habilitados\n')
  return session
}

async function goto(session, url) {
  await session.send('Page.navigate', { url })
  for (let attempt = 0; attempt < 90; attempt += 1) {
    await sleep(150)
    if (await session.evaluate('document.readyState === "complete"')) break
  }
  await sleep(600)
}

async function screenshot(session, name) {
  try {
    const shot = await session.send('Page.captureScreenshot', { format: 'png' })
    writeFileSync(join(SHOT_DIR, `${name}.png`), Buffer.from(shot.data, 'base64'))
  } catch {
    /* la captura es evidencia, no una comprobación */
  }
}

function startBrowser() {
  /** Perfil ÚNICO por ejecución: reutilizar uno deja el lock de Edge y la
   *  conexión CDP se queda colgada. Mismo criterio que ui-engine-certify.mjs. */
  const profile = join(tmpdir(), `lgi-fleet-profile-${Date.now()}`)
  mkdirSync(profile, { recursive: true })
  return spawn(EDGE, [
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
  ], { stdio: 'ignore' })
}

function startPreview() {
  /** Mismo arranque que ui-engine-certify.mjs: sirve dist/client y lee el puerto
   *  real que anuncia el servidor con "READY <puerto>". */
  const serverScript = join(process.cwd(), 'scripts', 'ui-engine-certify-server.mjs')
  return spawn(process.execPath, [
    serverScript,
    '--root', join(process.cwd(), 'dist', 'client'),
    '--port', '0',
  ], { stdio: ['ignore', 'pipe', 'pipe'] })
}

function waitForReadyPort(child) {
  return new Promise((resolve) => {
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
    setTimeout(() => resolve(0), 15000)
  })
}

const JS = {
  loginForm: `(() => {
    const email = document.querySelector('input[type="email"]')
    const pass = document.querySelector('input[type="password"]')
    const button = [...document.querySelectorAll('button[type="submit"]')]
      .find((b) => /entrar|sign in|log in/i.test(b.textContent))
    return Boolean(email && pass && button)
  })()`,
  setValue: (selector, value, tag) => `(() => {
    const el = document.querySelector(${JSON.stringify(selector)})
    if (!el) return false
    const proto = ${JSON.stringify(tag)} === 'SELECT' ? HTMLSelectElement : HTMLInputElement
    const setter = Object.getOwnPropertyDescriptor(proto.prototype, 'value').set
    setter.call(el, String(${JSON.stringify(value)}))
    el.dispatchEvent(new Event('input', { bubbles: true }))
    el.dispatchEvent(new Event('change', { bubbles: true }))
    return true
  })()`,
  clickText: (text) => `(() => {
    const el = [...document.querySelectorAll('button')]
      .find((b) => b.textContent.trim().toLowerCase().includes(${JSON.stringify(text.toLowerCase())}))
    if (!el) return false
    el.click()
    return true
  })()`,
  bodyText: `document.body.innerText.replace(/\\s+/g, ' ').slice(0, 400)`,
  navFleet: `(() => {
    /* El botón de navegación lleva icono + etiqueta ("✦FLOTA"), así que la
       coincidencia es por contenido, no por texto exacto. */
    const el = [...document.querySelectorAll('button, a')]
      .find((n) => /flota/i.test(n.textContent) && !/desplaz|flota de/i.test(n.textContent))
    if (!el) return false
    el.click()
    return true
  })()`,
}

async function doLogin(session) {
  await goto(session, `${BASE}/`)
  for (let attempt = 0; attempt < 40; attempt += 1) {
    if (await session.evaluate(JS.loginForm)) break
    await sleep(300)
  }
  if (!(await session.evaluate(JS.loginForm))) {
    return { ok: false, detail: 'no se encontró el formulario de login real' }
  }
  await session.evaluate(JS.setValue('input[type="email"]', DEV_EMAIL, 'INPUT'))
  await session.evaluate(JS.setValue('input[type="password"]', DEV_PASSWORD, 'INPUT'))
  await screenshot(session, '01-login-relleno')
  await session.evaluate(JS.clickText('entrar'))
  for (let attempt = 0; attempt < 60; attempt += 1) {
    await sleep(400)
    if (!(await session.evaluate(JS.loginForm))) break
  }
  if (await session.evaluate(JS.loginForm)) {
    const body = await session.evaluate(JS.bodyText)
    return { ok: false, detail: `login SIN sesión (el formulario persiste) · ${body.slice(0, 130)}` }
  }
  const text = await session.evaluate(JS.bodyText)
  return { ok: true, detail: `sesión establecida · ${text.slice(0, 110)}` }
}

async function runFlow(session) {
  const masked = DEV_EMAIL.replace(/^(.).*(@.*)$/, '$1***$2')
  console.log(`\nDEV: ${masked}  (parcialmente enmascarado — la contraseña nunca se imprime)\n`)

  await guarded(1, 'Login real DEV (UI, sin bypass)', () => doLogin(session))
  await screenshot(session, '02-sesion')

  if (await session.evaluate(JS.loginForm)) {
    check(2, 'Fleet UI accesible con sesión', false, 'sin sesión: el resto del flujo no es alcanzable')
    return
  }

  await guarded(2, 'Abrir vista Fleet (navegación real)', async () => {
    const clicked = await session.evaluate(JS.navFleet)
    await sleep(1500)
    const text = await session.evaluate(JS.bodyText)
    /* El encabezado "Flotas" vive más allá del nav: no bastaba con recortar. */
    const heading = await session.evaluate(`(() => {
      const h = [...document.querySelectorAll('h1,h2,h3')].find((n) => /flotas|fleet/i.test(n.textContent))
      return h ? h.textContent.trim() : null
    })()`)
    return { ok: clicked && heading !== null, detail: `click=${clicked} · encabezado="${heading ?? 'no encontrado'}"` }
  })
  await screenshot(session, '03-fleet')

  await guarded(3, 'Origen: selector con planeta propio', async () => {
    const info = await session.evaluate(`(() => {
      const origin = document.querySelectorAll('.fleet-controls select')[0]
      if (!origin) return null
      const opts = [...origin.options].map((o) => ({ value: o.value, label: o.textContent.trim() }))
      return { count: opts.length, options: opts }
    })()`)
    if (!info) return { ok: false, detail: 'no se encontró el selector de origen' }
    if (info.count === 0) return { ok: false, detail: 'el selector de origen no ofrece planetas' }
    await session.evaluate(JS.setValue('.fleet-controls select', info.options[0].value, 'SELECT'))
    await sleep(800)
    return { ok: true, detail: `${info.count} opciones · ${info.options[0].label}` }
  })

  await guarded(4, 'Misión: selección de misiones', async () => {
    const info = await session.evaluate(`(() => {
      const mission = document.querySelectorAll('.fleet-controls select')[1]
      if (!mission) return null
      return {
        count: mission.options.length,
        options: [...mission.options].map((o) => ({ value: o.value, label: o.textContent.trim() })),
        current: mission.value,
      }
    })()`)
    if (!info) return { ok: false, detail: 'no se encontró el selector de misión' }
    /* El jugador DEV sólo posee 1 light_fighter: ESPIONAGE es imposible (el
       servidor exige espionage_probe). ATTACK sí acepta la_light_fighter. */
    const preferred = info.options.find((o) => /^attack$/i.test(o.value))
    const chosen = preferred ?? info.options[0]
    /* Ambos <select> viven en <label> distintos dentro de .fleet-controls, así que
       :nth-of-type no aplica: se localiza por índice entre los select del bloque. */
    await session.evaluate('(() => {' + [
      '  const mission = document.querySelectorAll(\'.fleet-controls select\')[1]',
      '  if (!mission) return false',
      "  const setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value').set",
      '  setter.call(mission, ' + JSON.stringify(chosen.value) + ')',
      "  mission.dispatchEvent(new Event('change', { bubbles: true }))",
      '  return true',
      '})()',
    ].join('\n'))
    await sleep(800)
    const now = await session.evaluate('document.querySelectorAll(\'.fleet-controls select\')[1].value')
    return {
      ok: now === chosen.value,
      detail: `${info.count} misiones · seleccionada "${chosen.value}" (antes: ${info.current}, ahora: ${now})`,
    }
  })

  await guarded(5, 'Naves: selección por input real', async () => {
    const selector = '.neo-definition input[type="number"]:not([disabled])'
    const found = await session.evaluate('(() => {' + [
      '  const input = document.querySelector(' + JSON.stringify(selector) + ')',
      '  return input ? { aria: input.getAttribute("aria-label"), max: input.max } : null',
      '})()',
    ].join('\n'))
    if (!found) return { ok: false, detail: 'no hay ningún selector de cantidad habilitado' }
    await session.evaluate(JS.setValue(selector, '1', 'INPUT'))
    await sleep(800)
    const value = await session.evaluate('document.querySelector(' + JSON.stringify(selector) + ').value')
    return { ok: value === '1', detail: `${found.aria} · max=${found.max} · valor=${value}` }
  })
  await screenshot(session, '04-seleccion')

  /* Destino real y válido: 1:1:4 es un planeta IA ajeno. 1:1:1 es el propio
     Homeworld y el servidor lo rechaza ("El destino debe ser distinto del
     planeta de origen"), así que apuntar al origen no puede certificar nada. */
  const TARGET = { galaxy: '1', system: '1', position: '4' }
  const fillDestination = async (values) => {
    await session.evaluate('(() => {' + [
      '  const map = ' + JSON.stringify(values),
      "  const wanted = { 'galaxia': map.galaxy, 'sistema': map.system, 'posici': map.position }",
      "  for (const label of document.querySelectorAll('.fleet-controls label')) {",
      "    const span = label.querySelector('span') ? label.querySelector('span').textContent : ''",
      '    let key = null',
      "    if (/galaxia/i.test(span)) key = 'galaxia'",
      "    else if (/sistema/i.test(span)) key = 'sistema'",
      "    else if (/posici/i.test(span)) key = 'posici'",
      '    if (!key) continue',
      '    const input = label.querySelector(\'input\')',
      '    if (!input) continue',
      "    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set",
      '    setter.call(input, wanted[key])',
      "    input.dispatchEvent(new Event('input', { bubbles: true }))",
      '  }',
      '  return true',
      '})()',
    ].join('\n'))
    await sleep(700)
  }

  await guarded(6, 'Destino: coordenadas si la misión las pide', async () => {
    const keys = await session.evaluate(`(() => {
      const found = []
      for (const label of document.querySelectorAll('.fleet-controls label')) {
        const span = label.querySelector('span') ? label.querySelector('span').textContent : ''
        if (/galaxia/i.test(span)) found.push('galaxy')
        else if (/sistema/i.test(span)) found.push('system')
        else if (/posici/i.test(span)) found.push('position')
      }
      return found
    })()`)
    if (keys.length === 0) return { ok: true, detail: 'la misión NO pide coordenadas (destino propio/de sistema)' }
    await fillDestination(TARGET)
    /* Verificación real: leer el DOM de vuelta. Sin esto el paso daba PASS
       aunque React hubiera descartado el valor (y la flota nunca salía). */
    const after = await session.evaluate(`(() => {
      const out = []
      for (const label of document.querySelectorAll('.fleet-controls label')) {
        const span = label.querySelector('span') ? label.querySelector('span').textContent : ''
        if (!/galaxia|sistema|posici/i.test(span)) continue
        out.push({ span: span.trim(), value: label.querySelector('input') ? label.querySelector('input').value : '' })
      }
      return out
    })()`)
    const filled = after.filter((f) => f.value !== '')
    if (filled.length === 0) {
      return { ok: false, detail: `las coordenadas NO se quedaron escritas (${after.map((f) => `${f.span}=[${f.value}]`).join(' ')})` }
    }
    return { ok: true, detail: `DOM verificado → ${filled.map((f) => `${f.span}=${f.value}`).join(' ')}` }
  })
  await screenshot(session, '05-destino')

  const launch = await session.evaluate(`(() => {
    const button = [...document.querySelectorAll('button')].find((b) => /^lanzar/i.test(b.textContent.trim()))
    if (!button) return null
    return {
      text: button.textContent.trim(),
      disabled: button.disabled,
      context: button.parentElement?.parentElement?.innerText?.replace(/\\s+/g, ' ').slice(0, 140) ?? '',
    }
  })()`)

  await guarded(7, 'Botón LANZAR y su gate de UI', async () => {
    if (!launch) return { ok: false, detail: 'no se encontró el botón LANZAR' }
    return { ok: launch.disabled === false, detail: `"${launch.text}" disabled=${launch.disabled} · ${launch.context}` }
  })

  /* N2/N3 real. `launchBlock` (useFleetDispatch.ts) sólo pre-bloquea estados que
     devuelven los contratos del servidor (slots, expedición, colonias); el resto
     lo decide el backend. Por eso el negativo se comprueba PULSANDO LANZAR con
     una selección inválida y exigiendo el ERROR del servidor, no el disabled. */
  await guarded(8, 'N2/N3: el servidor rechaza la selección inválida', async () => {
    await session.evaluate(`(() => {
      for (const label of document.querySelectorAll('.fleet-controls label')) {
        const span = label.querySelector('span') ? label.querySelector('span').textContent : ''
        if (!/galaxia|sistema|posici/i.test(span)) continue
        const input = label.querySelector('input')
        if (!input) continue
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set
        setter.call(input, '')
        input.dispatchEvent(new Event('input', { bubbles: true }))
      }
      const ship = document.querySelector('.neo-definition input[type="number"]:not([disabled])')
      if (ship) {
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set
        setter.call(ship, '0')
        ship.dispatchEvent(new Event('input', { bubbles: true }))
      }
      return true
    })()`)
    await sleep(1000)
    await session.evaluate(JS.clickText('lanzar'))
    let rejection = null
    for (let attempt = 0; attempt < 30; attempt += 1) {
      await sleep(500)
      rejection = await session.evaluate(`(() => {
        const paras = Array.prototype.slice.call(document.querySelectorAll('p'))
        for (const p of paras) {
          const t = p.textContent.trim()
          if (t.indexOf('ERROR') === 0) return t
        }
        return null
      })()`)
      if (rejection) break
    }
    if (rejection) return { ok: true, detail: `rechazo autoritativo del servidor → ${rejection}` }
    return { ok: false, detail: 'pulso LANZAR sin naves ni coordenadas y el servidor NO mostró ningún ERROR' }
  })

  /* Restaurar la selección válida antes del dispatch real (mismo destino 1:1:4). */
  await session.evaluate(`(() => {
    const ship = document.querySelector('.neo-definition input[type="number"]:not([disabled])')
    if (ship) {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set
      setter.call(ship, '1')
      ship.dispatchEvent(new Event('input', { bubbles: true }))
    }
    return true
  })()`)
  await fillDestination(TARGET)
  await sleep(500)

  const ready = await session.evaluate(`(() => {
    const button = Array.prototype.slice.call(document.querySelectorAll('button'))
      .find((b) => /^lanzar/i.test(b.textContent.trim()))
    if (!button) return null
    return { text: button.textContent.trim(), disabled: button.disabled }
  })()`)

  if (ready && ready.disabled === false) {
    await guarded(9, 'DISPATCH real desde la UI', async () => {
      await session.evaluate(JS.clickText('lanzar'))
      /* Evidencia real: el aviso de éxito o el ERROR del servidor. El botón
         contiene literalmente "LANZAR", así que buscar esa palabra en el body
         daba un PASS falso incluso sin despacho alguno. */
      let verdict = null
      for (let attempt = 0; attempt < 40; attempt += 1) {
        await sleep(500)
        verdict = await session.evaluate(`(() => {
          const head = document.querySelector('.fleet-launch-head')
          const paras = Array.prototype.slice.call(document.querySelectorAll('p'))
          let error = null
          for (const p of paras) {
            const t = p.textContent.trim()
            if (t.indexOf('ERROR') === 0) { error = t; break }
          }
          const headText = head ? head.innerText.replace(/\\s+/g, ' ').trim() : ''
          return { error: error, head: headText }
        })()`)
        if (verdict.error || verdict.head) break
      }
      if (verdict.error) return { ok: false, detail: `el servidor rechazó el despacho → ${verdict.error}` }
      if (!verdict.head) return { ok: false, detail: 'sin aviso de éxito tras el clic en LANZAR' }
      return { ok: true, detail: `cabecera de lanzamiento → "${verdict.head}"` }
    })
    await screenshot(session, '06-post-dispatch')
  } else {
    check(9, 'DISPATCH real desde la UI', false, 'LANZAR bloqueado: no existe flujo despachable con esta selección')
  }
}

/* -------------------------------------------------------------------- main -- */

let preview
let browser
let session

try {
  process.stdout.write('[step] arrancando servidor estatico...\n')
  preview = startPreview()
  const port = await waitForReadyPort(preview)
  process.stdout.write(`[step] puerto=${port}\n`)
  if (!port) throw new Error('el servidor estático no anunció READY <puerto>')
  BASE = `http://127.0.0.1:${port}`
  if (!(await waitForHttp(`${BASE}/`))) throw new Error(`el servidor no respondió en ${BASE}`)
  process.stdout.write('[step] arrancando Edge...\n')
  browser = startBrowser()
  process.stdout.write('[step] conectando CDP...\n')
  session = await connect()
  process.stdout.write('[step] CDP conectado\n')
  await session.send('Emulation.setDeviceMetricsOverride', {
    width: VIEWPORT.width,
    height: VIEWPORT.height,
    deviceScaleFactor: 1,
    mobile: false,
  })
  await runFlow(session)
} catch (error) {
  console.log(`ERROR FATAL: ${error.message}`)
  check(0, 'Arranque de la certificación', false, error.message)
} finally {
  session?.close()
  browser?.kill()
  preview?.kill()
}

const failed = results.filter((entry) => !entry.ok)
/* Un paso OMITIDO no es un PASS: se cuenta aparte para que un recorrido parcial
   nunca pueda leerse como una certificacion completa. */
const skipped = results.filter((entry) => entry.detail.startsWith('OMITIDO'))
const ran = results.filter((entry) => !entry.detail.startsWith('OMITIDO'))
const ranFailed = ran.filter((entry) => !entry.ok)
console.log('')
if (skipped.length) {
  console.log(`EJECUCIÓN PARCIAL: ${skipped.length} paso(s) OMITIDO(S) por CERTIFY_MAX_STEP=${MAX_STEP}.`)
  console.log(`  Los pasos >= ${MUTATING_STEP} escriben en el mundo del jugador y NO se certificaron.`)
  console.log(`  Esto NO es una certificacion de navegador completa.`)
}
console.log(`RESUMEN: ${ran.length - ranFailed.length}/${ran.length} comprobaciones ejecutadas OK (${skipped.length} omitidas)`)
if (consoleIssues.length) {
  console.log(`Errores de consola/red (${consoleIssues.length}):`)
  for (const issue of consoleIssues.slice(0, 8)) console.log(`  - ${issue}`)
} else {
  console.log('Errores de consola/red: ninguno')
}
console.log(`Capturas: ${SHOT_DIR}`)
if (skipped.length) process.exitCode = 3   // salida distinta de 0: NO es certificacion completa
process.exit(failed.length ? 1 : 0)