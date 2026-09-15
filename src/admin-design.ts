import { supabase } from './lib/supabase'

type LayoutBox = { x: number; y: number; w?: number; h?: number }
const KEY = 'lagranimplosion-admin-layout-v2'
const ADMIN_PLAYER_ID = '60f1043a-2fa6-416c-80db-2a83215b5404'

// The editor never changes position/size of live game nodes. It creates a transparent
// design overlay with handles, so grid/flex/layout rules remain untouched while editing.
const targets = [
  ['CABECERA', '.neo-header'],
  ['MENÚ', '.neo-sidebar'],
  ['PLANETA', '.neo-planetbar'],
  ['CONTENIDO', '.neo-main'],
  ['PANEL', '.neo-panel'],
  ['BOTÓN', '.neo-nav-item'],
] as const

function read(): Record<string, LayoutBox> {
  try { return JSON.parse(localStorage.getItem(KEY) || '{}') as Record<string, LayoutBox> } catch { return {} }
}
function save(value: Record<string, LayoutBox>) { localStorage.setItem(KEY, JSON.stringify(value)) }

function installAdminUi() {
  if (document.body.dataset.adminInstalled) return
  document.body.dataset.adminInstalled = '1'
  const store = read()
  const bar = document.createElement('div')
  bar.id = 'admin-design-toolbar'
  bar.innerHTML = '<strong>DISEÑO ADMIN</strong><span>Editor seguro · no altera el layout real</span><button data-action="edit">EDITAR INTERFAZ</button><button data-action="reset">RESTABLECER</button>'
  document.body.appendChild(bar)

  const canvas = document.createElement('div')
  canvas.id = 'admin-layout-overlay'
  document.body.appendChild(canvas)
  let editing = false
  let selected: HTMLElement | null = null

  const clear = () => { canvas.replaceChildren(); selected = null }
  const saveRect = (key: string, rect: DOMRect) => {
    store[key] = { x: Math.round(rect.left), y: Math.round(rect.top), w: Math.round(rect.width), h: Math.round(rect.height) }
    save(store)
  }

  const draw = () => {
    clear()
    if (!editing) return
    targets.forEach(([label, selector]) => {
      document.querySelectorAll(selector).forEach((node, index) => {
        const el = node as HTMLElement
        const rect = el.getBoundingClientRect()
        if (rect.width < 4 || rect.height < 4) return
        const key = `${selector}#${index}`
        const box = document.createElement('button')
        box.type = 'button'
        box.className = 'admin-layout-box'
        box.dataset.key = key
        box.style.left = `${rect.left}px`
        box.style.top = `${rect.top}px`
        box.style.width = `${rect.width}px`
        box.style.height = `${rect.height}px`
        box.innerHTML = `<span>${label}</span><i class="admin-resize-handle" aria-hidden="true"></i>`
        canvas.appendChild(box)

        let mode: 'move' | 'resize' | null = null
        let sx = 0, sy = 0, sl = rect.left, st = rect.top, sw = rect.width, sh = rect.height
        const move = (e: PointerEvent) => {
          if (!mode) return
          if (mode === 'move') {
            box.style.left = `${Math.max(0, sl + e.clientX - sx)}px`
            box.style.top = `${Math.max(0, st + e.clientY - sy)}px`
          } else {
            box.style.width = `${Math.max(80, sw + e.clientX - sx)}px`
            box.style.height = `${Math.max(28, sh + e.clientY - sy)}px`
          }
        }
        const up = () => {
          if (!mode) return
          const r = box.getBoundingClientRect()
          saveRect(key, r)
          mode = null
          window.removeEventListener('pointermove', move)
          window.removeEventListener('pointerup', up)
        }
        box.addEventListener('pointerdown', (e) => {
          e.preventDefault(); e.stopPropagation()
          selected = box
          const target = e.target as HTMLElement
          mode = target.closest('.admin-resize-handle') ? 'resize' : 'move'
          sx = e.clientX; sy = e.clientY
          sl = box.getBoundingClientRect().left; st = box.getBoundingClientRect().top
          sw = box.getBoundingClientRect().width; sh = box.getBoundingClientRect().height
          window.addEventListener('pointermove', move)
          window.addEventListener('pointerup', up, { once: true })
        })
      })
    })
  }

  const toggle = () => {
    editing = !editing
    document.body.classList.toggle('admin-editing', editing)
    bar.querySelector('[data-action="edit"]')!.textContent = editing ? 'SALIR DISEÑO' : 'EDITAR INTERFAZ'
    draw()
  }

  bar.addEventListener('click', (event) => {
    const button = (event.target as HTMLElement).closest('button') as HTMLButtonElement | null
    if (!button) return
    if (button.dataset.action === 'edit') toggle()
    if (button.dataset.action === 'reset') {
      localStorage.removeItem(KEY)
      clear()
      location.reload()
    }
  })

  window.addEventListener('resize', () => { if (editing) draw() })
  const root = document.getElementById('root')
  if (root) new MutationObserver(() => { if (editing) draw() }).observe(root, { childList: true, subtree: true })
}

async function checkAdmin() {
  const { data, error } = await supabase.from('planets').select('player_id').eq('player_id', ADMIN_PLAYER_ID).eq('is_destroyed', false).limit(1)
  return !error && !!data?.length
}

async function install() {
  if (document.body.dataset.adminInstalled) return
  for (let attempt = 0; attempt < 8; attempt += 1) {
    if (await checkAdmin()) { document.body.classList.add('admin-mode'); installAdminUi(); return }
    await new Promise((resolve) => window.setTimeout(resolve, 500))
  }
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => { void install() })
else void install()
