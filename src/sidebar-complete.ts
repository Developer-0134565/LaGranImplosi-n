const EXTRA_ITEMS = [
  { id: 'messages', label: 'MENSAJES', icon: '✉', kind: 'messages' },
  { id: 'alliance', label: 'ALIANZA', icon: '⬡', kind: 'info' },
  { id: 'stats', label: 'ESTADÍSTICAS', icon: '▥', kind: 'stats' },
  { id: 'search', label: 'BUSCAR', icon: '⌕', kind: 'search' },
  { id: 'notes', label: 'NOTAS', icon: '▤', kind: 'notes' },
  { id: 'help', label: 'AYUDA', icon: '?', kind: 'help' },
  { id: 'settings', label: 'CONFIGURACIÓN', icon: '⚙', kind: 'settings' },
] as const

const STYLE_ID = 'lgi-complete-sidebar-style'
const PANEL_ID = 'lgi-sidebar-utility-panel'
const NOTES_KEY = 'lgi-sidebar-notes'

function injectStyle() {
  if (document.getElementById(STYLE_ID)) return
  const style = document.createElement('style')
  style.id = STYLE_ID
  style.textContent = `
    .neo-nav-extra{position:relative}
    .neo-nav-extra .lgi-extra-icon{display:grid;place-items:center;width:28px;height:28px;flex:0 0 28px;border:1px solid rgba(126,180,255,.16);border-radius:7px;color:#8fa3bd;font-size:15px;font-family:var(--font-button,sans-serif)}
    .neo-nav-extra:hover .lgi-extra-icon,.neo-nav-extra.active .lgi-extra-icon{color:#35d0ff;border-color:rgba(53,208,255,.4);box-shadow:0 0 12px rgba(53,208,255,.12)}
    #${PANEL_ID}{position:fixed;left:calc(var(--neo-sidebar-width,260px) + 24px);top:96px;width:min(520px,calc(100vw - 320px));max-height:calc(100vh - 140px);overflow:auto;z-index:250;background:rgba(5,9,16,.97);border:1px solid rgba(126,180,255,.22);border-radius:14px;box-shadow:0 18px 55px rgba(0,0,0,.6);padding:20px;color:#d7e3f4;font-family:var(--font-body,sans-serif)}
    #${PANEL_ID} .lgi-utility-head{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:16px}
    #${PANEL_ID} h2{margin:0;font-family:var(--font-heading,sans-serif);letter-spacing:.08em}
    #${PANEL_ID} button{font-family:var(--font-button,sans-serif)}
    #${PANEL_ID} .lgi-close{border:1px solid rgba(126,180,255,.2);background:rgba(20,28,42,.8);color:#d7e3f4;border-radius:7px;padding:6px 10px;cursor:pointer}
    #${PANEL_ID} .lgi-note{width:100%;min-height:180px;box-sizing:border-box;background:#080e17;color:#d7e3f4;border:1px solid rgba(126,180,255,.2);border-radius:9px;padding:12px;resize:vertical}
    #${PANEL_ID} .lgi-actions{display:flex;gap:8px;margin-top:10px;flex-wrap:wrap}
    #${PANEL_ID} .lgi-action{border:1px solid rgba(53,208,255,.28);background:rgba(20,38,55,.8);color:#d7e3f4;border-radius:8px;padding:8px 12px;cursor:pointer}
    #${PANEL_ID} .lgi-stat-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}
    #${PANEL_ID} .lgi-stat{border:1px solid rgba(126,180,255,.14);border-radius:9px;padding:12px;background:rgba(20,28,42,.5)}
    #${PANEL_ID} .lgi-stat strong{display:block;font-family:var(--font-number,monospace);font-size:20px;margin-top:4px}
    @media(max-width:900px){#${PANEL_ID}{left:20px;right:20px;width:auto}}
  `
  document.head.appendChild(style)
}

function closePanel() {
  document.getElementById(PANEL_ID)?.remove()
  document.querySelectorAll('.neo-nav-extra.active').forEach((el) => el.classList.remove('active'))
}

function openPanel(title: string, body: HTMLElement, source?: HTMLElement) {
  closePanel()
  const panel = document.createElement('section')
  panel.id = PANEL_ID
  const head = document.createElement('div')
  head.className = 'lgi-utility-head'
  const h2 = document.createElement('h2')
  h2.textContent = title
  const close = document.createElement('button')
  close.className = 'lgi-close'
  close.type = 'button'
  close.textContent = '×'
  close.onclick = closePanel
  head.append(h2, close)
  panel.append(head, body)
  document.body.appendChild(panel)
  source?.classList.add('active')
}

function showNotes(source: HTMLElement) {
  const wrap = document.createElement('div')
  const area = document.createElement('textarea')
  area.className = 'lgi-note'
  area.value = localStorage.getItem(NOTES_KEY) ?? ''
  area.placeholder = 'Escribe tus notas del imperio...'
  const actions = document.createElement('div')
  actions.className = 'lgi-actions'
  const save = document.createElement('button')
  save.className = 'lgi-action'
  save.type = 'button'
  save.textContent = 'GUARDAR'
  save.onclick = () => { localStorage.setItem(NOTES_KEY, area.value); save.textContent = 'GUARDADO ✓'; setTimeout(() => { save.textContent = 'GUARDAR' }, 1200) }
  actions.append(save)
  wrap.append(area, actions)
  openPanel('NOTAS', wrap, source)
}

function showStats(source: HTMLElement) {
  const wrap = document.createElement('div')
  const grid = document.createElement('div')
  grid.className = 'lgi-stat-grid'
  const planets = document.querySelectorAll('.neo-planet-row, .neo-planet-card').length
  const widgets = document.querySelectorAll('.dashboard-widget, [data-widget-id]').length
  const nav = document.querySelectorAll('.neo-nav-item').length + document.querySelectorAll('.neo-nav-extra').length
  const values = [['PLANETAS VISIBLES', String(planets)], ['WIDGETS DOM', String(widgets)], ['BOTONES', String(nav)], ['ESCALA', document.documentElement.style.getPropertyValue('--lgi-ui-scale') || '175%']]
  values.forEach(([label, value]) => { const card = document.createElement('div'); card.className = 'lgi-stat'; card.textContent = label; const strong = document.createElement('strong'); strong.textContent = value; card.appendChild(strong); grid.appendChild(card) })
  wrap.append(grid)
  openPanel('ESTADÍSTICAS', wrap, source)
}

function showInfo(title: string, text: string, source: HTMLElement) {
  const wrap = document.createElement('div')
  const p = document.createElement('p')
  p.textContent = text
  wrap.append(p)
  openPanel(title, wrap, source)
}

function addExtras() {
  const nav = document.querySelector('.neo-nav')
  if (!nav) return false
  EXTRA_ITEMS.forEach((item) => {
    if (nav.querySelector(`[data-lgi-extra="${item.id}"]`)) return
    const button = document.createElement('button')
    button.type = 'button'
    button.className = 'neo-nav-item neo-nav-extra'
    button.dataset.lgiExtra = item.id
    button.title = item.label
    const icon = document.createElement('span')
    icon.className = 'lgi-extra-icon'
    icon.textContent = item.icon
    const label = document.createElement('b')
    label.textContent = item.label
    button.append(icon, label)
    button.onclick = () => {
      if (item.kind === 'settings') {
        const settings = document.querySelector<HTMLButtonElement>('button[aria-label*="configuración" i],button[aria-label*="config" i]')
        settings?.click()
        if (!settings) showInfo('CONFIGURACIÓN', 'El panel de configuración está disponible desde el control de apariencia del encabezado.', button)
        return
      }
      if (item.kind === 'notes') return showNotes(button)
      if (item.kind === 'stats') return showStats(button)
      if (item.kind === 'messages') return showInfo('MENSAJES', 'Centro de comunicaciones preparado. La bandeja persistente de mensajes se conectará cuando el motor de mensajería esté habilitado.', button)
      if (item.kind === 'search') return showInfo('BUSCAR', 'Buscador del universo preparado para conectar con la galaxia y las coordenadas generadas.', button)
      if (item.kind === 'help') return showInfo('AYUDA', 'Usa la barra izquierda para navegar por el imperio. Las operaciones de edificios, investigación, hangar, defensas, flota, galaxia y expediciones siguen siendo las vistas principales.', button)
      return showInfo('ALIANZA', 'Módulo de alianza reservado para la siguiente capa social del juego.', button)
    }
    nav.appendChild(button)
  })
  return true
}

function boot() {
  injectStyle()
  if (addExtras()) return
  requestAnimationFrame(boot)
}

if (typeof window !== 'undefined') {
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true })
  else boot()
  const observer = new MutationObserver(() => { if (!document.querySelector('.neo-nav')) return; addExtras() })
  observer.observe(document.documentElement, { childList: true, subtree: true })
}

export {}
