import { supabase } from './lib/supabase'

type LayoutBox = { x: number; y: number; w?: number; h?: number }
const KEY = 'lagranimplosion-admin-layout-v1'
// V1: administración del dashboard de desarrollo. Cuando exista login real,
// esta comprobación deberá pasar a una autorización server-side/RPC.
const ADMIN_PLAYER_ID = '60f1043a-2fa6-416c-80db-2a83215b5404'
const targets = [
  ['HEADER', '.topbar'], ['NAVEGACION', '.sidebar'], ['CABECERA', '.hero'], ['RECURSOS', '.panel:nth-child(1)'],
  ['PLANETAS', '.panel:nth-child(2)'], ['ACCESO RAPIDO', '.panel.wide'], ['BOTONES NAVEGACION', '.nav-button'],
  ['BOTONES ACCESO RAPIDO', '.quick-grid button'], ['BOTONES ACCION', '.action-button'],
] as const

function read() { try { return JSON.parse(localStorage.getItem(KEY) || '{}') as Record<string, LayoutBox> } catch { return {} } }
function save(v: Record<string, LayoutBox>) { localStorage.setItem(KEY, JSON.stringify(v)) }

function makeEditable(el: HTMLElement, label: string, store: Record<string, LayoutBox>, key: string) {
  el.classList.add('admin-edit-target')
  el.dataset.adminLabel = label
  const saved = store[key]
  if (saved) {
    el.style.setProperty('--admin-x', `${saved.x}px`)
    el.style.setProperty('--admin-y', `${saved.y}px`)
    if (saved.w) el.style.setProperty('--admin-w', `${saved.w}px`)
    if (saved.h) el.style.setProperty('--admin-h', `${saved.h}px`)
    el.classList.add('admin-positioned')
  }

  let startX = 0, startY = 0, startBox: LayoutBox = { x: 0, y: 0 }, moving = false
  const drag = (e: PointerEvent) => {
    if (!moving) return
    const box = {
      x: Math.max(0, startBox.x + e.clientX - startX),
      y: Math.max(0, startBox.y + e.clientY - startY),
    }
    el.style.setProperty('--admin-x', `${box.x}px`)
    el.style.setProperty('--admin-y', `${box.y}px`)
    store[key] = { ...store[key], ...box }
    save(store)
  }
  const up = () => {
    moving = false
    el.classList.remove('admin-dragging')
    window.removeEventListener('pointermove', drag)
    window.removeEventListener('pointerup', up)
  }

  el.addEventListener('pointerdown', (e) => {
    if (!document.body.classList.contains('admin-editing')) return
    if ((e.target as HTMLElement).closest('input,select,textarea,a')) return
    // No anulamos el click normal: solo empieza a mover cuando el editor está activo.
    el.classList.add('admin-positioned')
    moving = true
    el.classList.add('admin-dragging')
    startX = e.clientX
    startY = e.clientY
    const r = el.getBoundingClientRect()
    startBox = { x: r.left, y: r.top, w: r.width, h: r.height }
    window.addEventListener('pointermove', drag)
    window.addEventListener('pointerup', up)
  })

  const ro = new ResizeObserver(() => {
    if (!document.body.classList.contains('admin-editing')) return
    const r = el.getBoundingClientRect()
    store[key] = { x: r.left, y: r.top, w: r.width, h: r.height }
    el.style.setProperty('--admin-w', `${r.width}px`)
    el.style.setProperty('--admin-h', `${r.height}px`)
    save(store)
  })
  ro.observe(el)
}

function bindTargets(store: Record<string, LayoutBox>) {
  targets.forEach(([label, sel]) => {
    document.querySelectorAll(sel).forEach((node, i) => {
      const el = node as HTMLElement
      const key = `${sel}#${i}`
      if (!el.dataset.adminBound) {
        el.dataset.adminBound = '1'
        makeEditable(el, label, store, key)
      }
    })
  })
}

function installAdminUi() {
  if (document.body.dataset.adminInstalled) return
  document.body.dataset.adminInstalled = '1'

  const store = read()
  const bar = document.createElement('div')
  bar.id = 'admin-design-toolbar'
  bar.innerHTML = '<strong>DISEÑO ADMIN</strong><span>Arrastra · redimensiona desde la esquina</span><button data-action="edit">EDITAR INTERFAZ</button><button data-action="reset">RESTABLECER</button>'
  document.body.appendChild(bar)

  let editing = false
  const activate = () => {
    editing = !editing
    document.body.classList.toggle('admin-editing', editing)
    bar.querySelector('[data-action="edit"]')!.textContent = editing ? 'SALIR DISEÑO' : 'EDITAR INTERFAZ'
    if (editing) bindTargets(store)
  }

  bar.addEventListener('click', (e) => {
    const b = (e.target as HTMLElement).closest('button')
    if (!b) return
    if (b.dataset.action === 'edit') activate()
    if (b.dataset.action === 'reset') {
      localStorage.removeItem(KEY)
      location.reload()
    }
  })

  const root = document.getElementById('root')
  if (root) new MutationObserver(() => { if (editing) bindTargets(store) }).observe(root, { childList: true, subtree: true })
}

async function checkAdmin() {
  // No dependemos de que React haya renderizado todavía: consultamos directamente
  // si existe al menos un planeta perteneciente al jugador administrador.
  const { data, error } = await supabase
    .from('planets')
    .select('player_id')
    .eq('player_id', ADMIN_PLAYER_ID)
    .eq('is_destroyed', false)
    .limit(1)

  if (error || !data?.length) return false
  return true
}

async function install() {
  if (document.body.dataset.adminInstalled) return

  // React y Supabase pueden tardar un instante en estar listos en el dashboard.
  // Reintentamos unas pocas veces para no depender del orden de renderizado.
  for (let attempt = 0; attempt < 8; attempt += 1) {
    if (await checkAdmin()) {
      document.body.classList.add('admin-mode')
      installAdminUi()
      return
    }
    await new Promise((resolve) => window.setTimeout(resolve, 500))
  }
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => { void install() })
else void install()
