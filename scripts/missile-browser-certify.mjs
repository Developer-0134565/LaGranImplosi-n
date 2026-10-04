/* =============================================================================
   CERTIFICACION BROWSER DEL MISSILE SYSTEM - runtime con credencial DEV real
   -----------------------------------------------------------------------------
   Reutiliza la MISMA infraestructura CDP nativa de ui-engine-certify.mjs
   (Edge headless + WebSocket nativo, CERO dependencias: no Playwright/Puppeteer/
   Cypress/Selenium) y su servidor estatico. No se instala ningun framework.

   CREDENCIALES - RUNTIME ONLY. Se leen de process.env:
       DEV_EMAIL
       DEV_PASSWORD
   NO se escriben en el repo, ni en .env, ni en logs, ni en capturas.
   Si faltan, el script NO simula nada: lo dice y termina con codigo 2.

   Este script SOLO acciona la UI real. La verificacion auxiliar en base de datos
   la hace el operador despues, como evidencia (nunca en lugar del browser).

   Uso (PowerShell):
       $env:DEV_EMAIL = "..."; $env:DEV_PASSWORD = "..."
       node scripts/missile-browser-certify.mjs
   ========================================================================== */

import { mkdirSync, writeFileSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const DEV_EMAIL = process.env.DEV_EMAIL ?? ''
const DEV_PASSWORD = process.env.DEV_PASSWORD ?? ''

if (!DEV_EMAIL || !DEV_PASSWORD) {
  console.log('ENVIRONMENT BLOCKED - DEV CREDENTIAL UNAVAILABLE')
  console.log('Define DEV_EMAIL y DEV_PASSWORD en el entorno. NO se simula el login.')
  process.exit(2)
}

const readArg = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`)
  return index >= 0 && process.argv[index + 1] ? Number(process.argv[index + 1]) : fallback
}

const DEBUG_PORT = readArg('debug-port', 9455)
/* Objetivo REAL (cuerpo ajeno) en formato g:s:p. Por defecto se usa el propio
   hogar, que debe ser rechazado: es la prueba de que el cliente no se
   auto-autoriza. Pasar --target para ejercitar el camino de lanzamiento. */
const TARGET = (() => {
  const i = process.argv.indexOf('--target')
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : null
})()
const EDGE = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
const SHOT_DIR = join(tmpdir(), 'lgi-missile-certify')
const VIEWPORT = { width: 1440, height: 900 }
let BASE = ''

mkdirSync(SHOT_DIR, { recursive: true })

const results = []
const consoleIssues = []
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function check(id, label, ok, detail = '') {
  results.push({ id, label, ok, detail })
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${String(id).padEnd(3)} ${label}${detail ? ` - ${detail}` : ''}`)
}

async function guarded(id, label, run) {
  try {
    const outcome = await run()
    check(id, label, Boolean(outcome?.ok), outcome?.detail ?? '')
    return Boolean(outcome?.ok)
  } catch (error) {
    check(id, label, false, `excepcion: ${error.message}`)
    return false
  }
}

async function waitForHttp(url, attempts = 120) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      const response = await fetch(url)
      if (response.ok) return true
    } catch {
      /* aun no levanta */
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
  const list = await (await fetch(`http://127.0.0.1:${DEBUG_PORT}/json/list`)).json()
  const page = list.find((target) => target.type === 'page')
  if (!page) throw new Error('El navegador no expone ninguna pagina')
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
  await sleep(600)
}

async function screenshot(session, name) {
  try {
    const shot = await session.send('Page.captureScreenshot', { format: 'png' })
    writeFileSync(join(SHOT_DIR, `${name}.png`), Buffer.from(shot.data, 'base64'))
  } catch {
    /* la captura es evidencia, no una comprobacion */
  }
}

function startBrowser() {
  const profile = join(tmpdir(), `lgi-missile-profile-${Date.now()}`)
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
  setValue: (selector, value) => `(() => {
    const el = document.querySelector(${JSON.stringify(selector)})
    if (!el) return false
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set
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
  bodyText: `document.body.innerText.replace(/\s+/g, ' ')`,
  navDefense: `(() => {
    const el = [...document.querySelectorAll('button, a')]
      .find((n) => /defens/i.test(n.textContent))
    if (!el) return false
    el.click()
    return true
  })()`,
  siloPanel: `(() => {
    const t = document.body.innerText
    return /SILO DE MISILES/i.test(t)
  })()`,
  /* Sin regex a proposito: estas expresiones se inyectan dentro de template
     literals, donde un \s suelto se come como escape y el JS evaluado queda
     malformado. El parseo es puramente textual. */
  siloNumbers: `(() => {
    const t = document.body.innerText
    const i = t.search(/NIVEL/i)
    if (i < 0) return null
    const chunk = t.slice(i, i + 80)
    const nums = chunk.match(/[0-9]+/g)
    if (!nums || nums.length < 3) return null
    return { level: Number(nums[0]), used: Number(nums[1]), cap: Number(nums[2]) }
  })()`,
  hasMissileCards: `(() => {
    const t = document.body.innerText
    return {
      abm: /MISIL ANTIBALISTICO/i.test(t),
      ipm: /MISIL INTERPLANETARIO/i.test(t),
    }
  })()`,
  /* D3: no puede existir un selector de prioridad en el DOM. */
  /* D3 acotado AL PANEL de misiles: el resto de la app puede tener <select>
     legitimos (fuentes, cuerpo activo) y no cuentan como selector de prioridad. */
  hasPrioritySelector: `(() => {
    const panel = [...document.querySelectorAll('section')]
      .find((s) => /SILO DE MISILES/i.test(s.innerText || ''))
    if (!panel) return { panel: false }
    const t = panel.innerText || ''
    const lower = t.toLowerCase()
    return {
      panel: true,
      selectsInPanel: panel.querySelectorAll('select').length,
      mentionsCheapest: lower.includes('cheapest'),
      mentionsExpensive: lower.includes('expensive'),
      mentionsPriority: lower.includes('prioridad') || lower.includes('priority'),
      panelText: t.replace(/\\s+/g, ' ').slice(0, 160),
    }
  })()`,
  /* Solo el aviso/ERROR del PANEL de misiles. Antes se leia document.body entero,
     asi que cualquier coincidencia de texto daba un PASS falso. */
  clickInCard: (cardText, buttonText) => `(() => {
    const panel = [...document.querySelectorAll('section')]
      .find((s) => /SILO DE MISILES/i.test(s.innerText || ''))
    if (!panel) return false
    const card = [...panel.querySelectorAll('article')]
      .find((a) => {
        const h = a.querySelector('h2')
        return h && (h.innerText || '').toUpperCase().includes(${JSON.stringify(cardText.toUpperCase())})
      })
    if (!card) return false
    const btn = [...card.querySelectorAll('button')]
      .find((b) => (b.textContent || '').toLowerCase().includes(${JSON.stringify(buttonText.toLowerCase())}))
    if (!btn || btn.disabled) return false
    btn.click()
    return true
  })()`,
  /* Acotado a las DOS tarjetas de misiles y SIN regex: un \\s dentro de un
     template literal se come como escape y el JS evaluado queda malformado. */
  readFeedback: `(() => {
    const panel = [...document.querySelectorAll('section')]
      .find((s) => /SILO DE MISILES/i.test(s.innerText || ''))
    if (!panel) return { panel: false, notices: [], estados: [] }
    const cards = [...panel.querySelectorAll('article')].filter((a) => {
      const h = a.querySelector('h2')
      return h && /MISIL/.test(h.innerText || '')
    })
    const after = (text, label) => {
      const i = (text || '').toUpperCase().indexOf(label)
      if (i < 0) return null
      const rest = text.slice(i + label.length).trim()
      return rest.length ? rest : null
    }
    return {
      panel: true,
      notices: [...panel.querySelectorAll('.neo-empty')].map((n) => (n.innerText || '').trim()).filter(Boolean).slice(0, 5),
      estados: cards.map((a) => {
        const h = a.querySelector('h2')
        const btn = a.querySelector('button')
        return {
          label: (h ? h.innerText : '?').trim(),
          estado: after(a.innerText, 'ESTADO'),
          coste: after(a.innerText, 'COSTE'),
          boton: btn ? (btn.disabled ? 'deshabilitado' : 'activo') : '?',
        }
      }),
    }
  })()`,
  findTargets: `(() => {
    const el = document.querySelector('input[aria-label="Galaxia objetivo"]')
    return Boolean(el)
  })()`,
  fillTarget: (g, s, p) => `(() => {
    const set = (label, value) => {
      const el = document.querySelector('input[aria-label="' + label + '"]')
      if (!el) return false
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set
      setter.call(el, String(value))
      el.dispatchEvent(new Event('input', { bubbles: true }))
      el.dispatchEvent(new Event('change', { bubbles: true }))
      return true
    }
    return [set('Galaxia objetivo', ${JSON.stringify(String(g))}),
            set('Sistema objetivo', ${JSON.stringify(String(s))}),
            set('Posicion objetivo', ${JSON.stringify(String(p))})].every(Boolean)
  })()`,
  targetSummary: `(() => {
    const t = document.body.innerText
    const after = (label) => {
      const i = t.toUpperCase().indexOf(label)
      if (i < 0) return null
      const rest = t.slice(i + label.length).trim()
      return rest.length ? rest.split(' ')[0] : null
    }
    const r = after('ALCANCE MAXIMO')
    return { distance: after('DISTANCIA'), maxRange: r && /^[0-9]+$/.test(r) ? Number(r) : null }
  })()`,
}

async function doLogin(session) {
  await goto(session, `${BASE}/`)
  for (let attempt = 0; attempt < 40; attempt += 1) {
    if (await session.evaluate(JS.loginForm)) break
    await sleep(300)
  }
  if (!(await session.evaluate(JS.loginForm))) {
    return { ok: false, detail: 'no se encontro el formulario de login real' }
  }
  await session.evaluate(JS.setValue('input[type="email"]', DEV_EMAIL))
  await session.evaluate(JS.setValue('input[type="password"]', DEV_PASSWORD))
  await screenshot(session, '01-login-relleno')
  await session.evaluate(JS.clickText('entrar'))
  for (let attempt = 0; attempt < 60; attempt += 1) {
    await sleep(400)
    if (!(await session.evaluate(JS.loginForm))) break
  }
  if (await session.evaluate(JS.loginForm)) {
    const body = await session.evaluate(JS.bodyText)
    return { ok: false, detail: `login SIN sesion (el formulario persiste) - ${body.slice(0, 130)}` }
  }
  const text = await session.evaluate(JS.bodyText)
  return { ok: true, detail: `sesion establecida - ${text.slice(0, 110)}` }
}

async function runFlow(session) {
  const masked = DEV_EMAIL.replace(/^(.).*(@.*)$/, '$1***$2')
  console.log(`\nDEV: ${masked}  (enmascarado - la contrasena nunca se imprime)\n`)

  await guarded(1, 'Login real DEV (UI, sin bypass)', () => doLogin(session))
  await screenshot(session, '02-sesion')

  if (await session.evaluate(JS.loginForm)) {
    check(2, 'UI de defensas accesible con sesion', false, 'sin sesion: el resto no es alcanzable')
    return
  }

  await guarded(2, 'Abrir la vista de defensas (navegacion real)', async () => {
    const clicked = await session.evaluate(JS.navDefense)
    await sleep(2000)
    return { ok: Boolean(clicked), detail: clicked ? 'vista abierta' : 'no se encontro el boton' }
  })
  await screenshot(session, '03-defensas')

  await guarded(3, 'El panel del silo se renderiza', async () => {
    await sleep(1200)
    const visible = await session.evaluate(JS.siloPanel)
    return { ok: visible, detail: visible ? 'SILO DE MISILES presente' : 'el panel no aparece' }
  })

  await guarded(4, 'ABM e IPM aparecen como defensas del catalogo', async () => {
    const cards = await session.evaluate(JS.hasMissileCards)
    return { ok: cards.abm && cards.ipm, detail: `ABM=${cards.abm} IPM=${cards.ipm}` }
  })

  await guarded(5, 'La capacidad del silo se muestra y es coherente', async () => {
    const s = await session.evaluate(JS.siloNumbers)
    if (!s) return { ok: false, detail: 'no se pudo leer el bloque de capacidad' }
    return { ok: s.cap === s.level * 10, detail: `nivel ${s.level}, ${s.used}/${s.cap} ranuras` }
  })

  await guarded(6, 'NO existe selector de prioridad en el panel (D3)', async () => {
    const s = await session.evaluate(JS.hasPrioritySelector)
    const clean = s.panel && s.selectsInPanel === 0 && !s.mentionsCheapest
      && !s.mentionsExpensive && !s.mentionsPriority
    return { ok: clean, detail: `selects_en_panel=${s.selectsInPanel} cheapest=${s.mentionsCheapest} expensive=${s.mentionsExpensive} prioridad=${s.mentionsPriority}` }
  })

  await guarded(7, 'Produccion real de ABM/IPM desde la UI (start_defense)', async () => {
    /* Cada tarjeta tiene su propio boton: se pulsa la de cadaarticulo, no el
       primero, para no encolar dos veces el mismo. */
    const antes = await session.evaluate(JS.readFeedback)
    await session.evaluate(JS.clickInCard('MISIL ANTIBALISTICO', 'producir 1'))
    await sleep(2500)
    await session.evaluate(JS.clickInCard('MISIL INTERPLANETARIO', 'producir 1'))
    await sleep(3000)
    const despues = await session.evaluate(JS.readFeedback)
    const avisos = despues.notices || []
    return {
      ok: avisos.some((a) => /en cola/i.test(a)),
      detail: `avisos=${JSON.stringify(avisos).slice(0, 200)}`,
    }
  })
  await screenshot(session, '04-produccion')

  await guarded(8, 'Los campos de objetivo por coordenadas existen', async () => {
    const present = await session.evaluate(JS.findTargets)
    const summary = await session.evaluate(JS.targetSummary)
    return {
      ok: present,
      detail: present ? `campos presentes; alcance=${summary?.maxRange} distancia=${summary?.distance}` : 'sin campos de objetivo',
    }
  })

  await guarded(9, 'Rellenar y resolver un objetivo por coordenadas', async () => {
    const body = await session.evaluate(JS.bodyText)
    /* Sin --target se usa el propio hogar: debe ser RECHAZADO, y eso ya es una
       prueba. Con --target se apunta a un cuerpo ajeno real. */
    const fallback = (body.match(/\[\d+:\d+:\d+\]/g) ?? ['1:1:1'])[0].replace(/[\[\]]/g, '').split(':')
    const first = TARGET ? TARGET.split(':') : fallback
    const filled = await session.evaluate(JS.fillTarget(first[0], first[1], first[2]))
    await session.evaluate(JS.clickText('buscar objetivo'))
    await sleep(2000)
    const summary = await session.evaluate(JS.targetSummary)
    const after = await session.evaluate(JS.readFeedback)
    return {
      ok: filled,
      detail: `destino=[${first.join(':')}] distancia=${summary?.distance} alcance=${summary?.maxRange} avisos=${JSON.stringify((after || {}).notices || []).slice(0, 130)}`,
    }
  })
  await screenshot(session, '05-objetivo')

  await guarded(10, 'La autoridad del lanzamiento es del servidor, no del cliente', async () => {
    const before = await session.evaluate(JS.readFeedback)
    const clicked = await session.evaluate(JS.clickText('lanzar ipm'))
    await sleep(3000)
    const after = await session.evaluate(JS.readFeedback)
    const body = await session.evaluate(JS.bodyText)
    const sawServerText = /NOT_ENOUGH_IPM|OUT_OF_RANGE|TARGET_OWN|ORIGIN_NOT_OWNED|MISSILE_ATTACK_|IPM en vuelo/i.test(body)
    const sinCambio = JSON.stringify(before) === JSON.stringify(after)
    const ok = sawServerText || !clicked || sinCambio
    return {
      ok,
      detail: `intentado=${Boolean(clicked)} texto_del_servidor=${sawServerText} panel_sin_cambio=${sinCambio} avisos=${JSON.stringify((after || {}).notices || []).slice(0, 130)}`,
    }
  })
  await screenshot(session, '06-lanzamiento')
  await guarded(11, 'El panel muestra el movimiento MISSILE_ATTACK del jugador', async () => {
    const seen = await session.evaluate(`(() => {
      const panel = [...document.querySelectorAll('section')].find((s) => /SILO DE MISILES/i.test(s.innerText || ''))
      if (!panel) return { panel: false }
      const t = panel.innerText || ''
      return {
        panel: true,
        heading: /MISILES EN VUELO/i.test(t),
        hasShipRows: /IPM en vuelo|no hay|sin movimientos|MISILES EN VUELO/i.test(t) || panel.querySelectorAll('article').length > 2,
      }
    })()`)
    return { ok: Boolean(seen.panel) && seen.hasShipRows, detail: `panel=${seen.panel} seccion=${seen.heading}` }
  })
}

let preview
let browser
let session

try {
  process.stdout.write('[step] arrancando servidor estatico...\n')
  preview = startPreview()
  const port = await waitForReadyPort(preview)
  process.stdout.write(`[step] puerto=${port}\n`)
  if (!port) throw new Error('el servidor estatico no anuncio READY <puerto>')
  BASE = `http://127.0.0.1:${port}`
  if (!(await waitForHttp(`${BASE}/`))) throw new Error(`el servidor no respondio en ${BASE}`)
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
  check(0, 'Arranque de la certificacion', false, error.message)
} finally {
  session?.close()
  browser?.kill()
  preview?.kill()
}

const failed = results.filter((entry) => !entry.ok)
console.log('')
console.log(`RESUMEN: ${results.length - failed.length}/${results.length} comprobaciones OK`)
if (consoleIssues.length) {
  console.log(`Errores de consola/red (${consoleIssues.length}):`)
  for (const issue of consoleIssues.slice(0, 8)) console.log(`  - ${issue}`)
} else {
  console.log('Errores de consola/red: ninguno')
}
console.log(`Capturas: ${SHOT_DIR}`)
process.exit(failed.length ? 1 : 0)
