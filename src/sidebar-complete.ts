import { supabase } from './lib/supabase'

type Player = { id: string; username: string | null }
type Planet = { id: string; name: string; galaxy: number; system: number; position: number; is_homeworld: boolean; players?: Player | Player[] | null }

const EXTRA_ITEMS = [
  { id: 'messages', label: 'MENSAJES', icon: '✉', kind: 'messages' },
  { id: 'alliance', label: 'ALIANZA', icon: '⬡', kind: 'alliance' },
  { id: 'stats', label: 'ESTADÍSTICAS', icon: '▥', kind: 'stats' },
  { id: 'search', label: 'BUSCAR', icon: '⌕', kind: 'search' },
  { id: 'notes', label: 'NOTAS', icon: '▤', kind: 'notes' },
  { id: 'help', label: 'AYUDA', icon: '?', kind: 'help' },
  { id: 'settings', label: 'CONFIGURACIÓN', icon: '⚙', kind: 'settings' },
] as const

const STYLE_ID = 'lgi-complete-sidebar-style'
const PANEL_ID = 'lgi-sidebar-utility-panel'

function getCurrentPlayerId() {
  return supabase
    .from('planets')
    .select('players(id)')
    .eq('is_homeworld', true)
    .eq('is_destroyed', false)
    .limit(1)
    .maybeSingle()
    .then(({ data }) => {
      const player = Array.isArray(data?.players) ? data?.players[0] : data?.players
      return (player as Player | null | undefined)?.id ?? null
    })
}

function injectStyle() {
  if (document.getElementById(STYLE_ID)) return
  const style = document.createElement('style')
  style.id = STYLE_ID
  style.textContent = `
    .neo-nav-extra{position:relative}
    .neo-nav-extra .lgi-extra-icon{display:grid;place-items:center;width:28px;height:28px;flex:0 0 28px;border:1px solid rgba(126,180,255,.16);border-radius:7px;color:#8fa3bd;font-size:15px;font-family:var(--font-button,sans-serif)}
    .neo-nav-extra:hover .lgi-extra-icon,.neo-nav-extra.active .lgi-extra-icon{color:#35d0ff;border-color:rgba(53,208,255,.4);box-shadow:0 0 12px rgba(53,208,255,.12)}
    #${PANEL_ID}{position:fixed;left:calc(var(--neo-sidebar-width,260px) + 24px);top:96px;width:min(620px,calc(100vw - 320px));max-height:calc(100vh - 140px);overflow:auto;z-index:250;background:rgba(5,9,16,.98);border:1px solid rgba(126,180,255,.22);border-radius:14px;box-shadow:0 18px 55px rgba(0,0,0,.6);padding:20px;color:#d7e3f4;font-family:var(--font-body,sans-serif)}
    #${PANEL_ID} .lgi-utility-head{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:16px}
    #${PANEL_ID} h2{margin:0;font-family:var(--font-heading,sans-serif);letter-spacing:.08em}
    #${PANEL_ID} h3{margin:16px 0 8px;font-family:var(--font-heading,sans-serif);color:#35d0ff}
    #${PANEL_ID} button{font-family:var(--font-button,sans-serif)}
    #${PANEL_ID} .lgi-close{border:1px solid rgba(126,180,255,.2);background:rgba(20,28,42,.8);color:#d7e3f4;border-radius:7px;padding:6px 10px;cursor:pointer}
    #${PANEL_ID} .lgi-note,#${PANEL_ID} input,#${PANEL_ID} textarea{width:100%;box-sizing:border-box;background:#080e17;color:#d7e3f4;border:1px solid rgba(126,180,255,.2);border-radius:9px;padding:10px}
    #${PANEL_ID} .lgi-note{min-height:180px;resize:vertical}
    #${PANEL_ID} .lgi-actions{display:flex;gap:8px;margin-top:10px;flex-wrap:wrap}
    #${PANEL_ID} .lgi-action{border:1px solid rgba(53,208,255,.28);background:rgba(20,38,55,.8);color:#d7e3f4;border-radius:8px;padding:8px 12px;cursor:pointer}
    #${PANEL_ID} .lgi-status{margin:8px 0;color:#8fa3bd;font-size:12px}
    #${PANEL_ID} .lgi-stat-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}
    #${PANEL_ID} .lgi-stat{border:1px solid rgba(126,180,255,.14);border-radius:9px;padding:12px;background:rgba(20,28,42,.5)}
    #${PANEL_ID} .lgi-stat strong{display:block;font-family:var(--font-number,monospace);font-size:20px;margin-top:4px}
    #${PANEL_ID} .lgi-list{display:grid;gap:8px}
    #${PANEL_ID} .lgi-row{border:1px solid rgba(126,180,255,.12);border-radius:9px;padding:11px;background:rgba(20,28,42,.42)}
    #${PANEL_ID} .lgi-row strong{display:block;color:#d7e3f4}
    #${PANEL_ID} .lgi-row small{color:#8fa3bd}
    #${PANEL_ID} .lgi-row.unread{border-color:rgba(53,208,255,.35)}
    #${PANEL_ID} .lgi-coord{font-family:var(--font-number,monospace);color:#35d0ff}
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

function status(text: string) {
  const p = document.createElement('p')
  p.className = 'lgi-status'
  p.textContent = text
  return p
}

async function showNotes(source: HTMLElement) {
  const wrap = document.createElement('div')
  const area = document.createElement('textarea')
  area.className = 'lgi-note'
  area.placeholder = 'Escribe tus notas del imperio...'
  const save = document.createElement('button')
  save.className = 'lgi-action'
  save.type = 'button'
  save.textContent = 'GUARDAR EN SUPABASE'
  const state = status('Cargando notas...')
  wrap.append(area, state, save)
  openPanel('NOTAS', wrap, source)

  const playerId = await getCurrentPlayerId()
  if (!playerId) { state.textContent = 'No se encontró el jugador actual.'; return }
  const { data, error } = await supabase.from('player_notes').select('content').eq('player_id', playerId).maybeSingle()
  if (error) { state.textContent = error.message; return }
  area.value = data?.content ?? ''
  state.textContent = 'Notas vinculadas al jugador actual.'
  save.onclick = async () => {
    save.disabled = true
    const { error: saveError } = await supabase.from('player_notes').upsert({ player_id: playerId, content: area.value, updated_at: new Date().toISOString() })
    state.textContent = saveError ? saveError.message : 'Guardado correctamente ✓'
    save.disabled = false
  }
}

async function showMessages(source: HTMLElement) {
  const wrap = document.createElement('div')
  const list = document.createElement('div')
  list.className = 'lgi-list'
  wrap.append(list)
  openPanel('MENSAJES', wrap, source)
  list.append(status('Cargando bandeja...'))
  const playerId = await getCurrentPlayerId()
  if (!playerId) { list.replaceChildren(status('No se encontró el jugador actual.')); return }
  const { data, error } = await supabase.from('player_messages').select('id,sender_player_id,subject,body,read_at,created_at').eq('recipient_player_id', playerId).order('created_at', { ascending: false }).limit(50)
  if (error) { list.replaceChildren(status(error.message)); return }
  if (!data?.length) { list.replaceChildren(status('Bandeja vacía.')); return }
  list.replaceChildren(...data.map((message) => {
    const row = document.createElement('article')
    row.className = `lgi-row${message.read_at ? '' : ' unread'}`
    row.innerHTML = `<strong></strong><small></small><p></p>`
    row.querySelector('strong')!.textContent = message.subject || '(sin asunto)'
    row.querySelector('small')!.textContent = new Date(message.created_at).toLocaleString('es-ES')
    row.querySelector('p')!.textContent = message.body
    row.onclick = async () => {
      if (message.read_at) return
      const { error: readError } = await supabase.from('player_messages').update({ read_at: new Date().toISOString() }).eq('id', message.id).eq('recipient_player_id', playerId)
      if (!readError) row.classList.remove('unread')
    }
    return row
  }))
}

async function showStats(source: HTMLElement) {
  const wrap = document.createElement('div')
  const grid = document.createElement('div')
  grid.className = 'lgi-stat-grid'
  wrap.append(status('Consultando Supabase...'), grid)
  openPanel('ESTADÍSTICAS', wrap, source)
  const queries = await Promise.all([
    supabase.from('planets').select('*', { count: 'exact', head: true }).eq('is_destroyed', false),
    supabase.from('players').select('*', { count: 'exact', head: true }),
    supabase.from('fleet_movements').select('*', { count: 'exact', head: true }),
    supabase.from('universe_galaxies').select('*', { count: 'exact', head: true }),
  ])
  const labels = ['PLANETAS', 'JUGADORES', 'MOVIMIENTOS DE FLOTA', 'GALAXIAS']
  grid.replaceChildren(...queries.map((q, i) => {
    const card = document.createElement('div')
    card.className = 'lgi-stat'
    card.textContent = labels[i]
    const strong = document.createElement('strong')
    strong.textContent = q.error ? 'ERR' : String(q.count ?? 0)
    card.appendChild(strong)
    return card
  }))
}

async function showSearch(source: HTMLElement) {
  const wrap = document.createElement('div')
  const input = document.createElement('input')
  input.placeholder = 'Nombre o coordenadas: 1:2:3'
  const button = document.createElement('button')
  button.className = 'lgi-action'
  button.textContent = 'BUSCAR'
  const list = document.createElement('div')
  list.className = 'lgi-list'
  wrap.append(input, button, list)
  openPanel('BUSCAR EN EL UNIVERSO', wrap, source)
  const run = async () => {
    const term = input.value.trim()
    if (!term) return
    list.replaceChildren(status('Buscando...'))
    const coord = term.match(/^(\d+):(\d+):(\d+)$/)
    let query = supabase.from('planets').select('id,name,galaxy,system,position,is_homeworld,players(username)').eq('is_destroyed', false).limit(50)
    if (coord) query = query.eq('galaxy', Number(coord[1])).eq('system', Number(coord[2])).eq('position', Number(coord[3]))
    else query = query.ilike('name', `%${term}%`)
    const { data, error } = await query
    if (error) { list.replaceChildren(status(error.message)); return }
    if (!data?.length) { list.replaceChildren(status('Sin resultados.')); return }
    list.replaceChildren(...(data as Planet[]).map((planet) => {
      const row = document.createElement('article')
      row.className = 'lgi-row'
      const player = Array.isArray(planet.players) ? planet.players[0] : planet.players
      row.innerHTML = `<strong></strong><small></small>`
      row.querySelector('strong')!.textContent = planet.name
      row.querySelector('small')!.innerHTML = `<span class="lgi-coord">[${planet.galaxy}:${planet.system}:${planet.position}]</span> · ${player?.username ?? 'sin jugador'}`
      return row
    }))
  }
  button.onclick = run
  input.onkeydown = (event) => { if (event.key === 'Enter') void run() }
}

function showAlliance(source: HTMLElement) {
  const wrap = document.createElement('div')
  wrap.append(status('La base de datos social está preparada como siguiente bloque: alianzas, miembros, rangos y solicitudes.'))
  openPanel('ALIANZA', wrap, source)
}

function showHelp(source: HTMLElement) {
  const wrap = document.createElement('div')
  const h = document.createElement('h3')
  h.textContent = 'NAVEGACIÓN'
  const p = document.createElement('p')
  p.textContent = 'Los botones de producción, investigación, hangar, defensas, flota, galaxia y expediciones ya consultan Supabase desde las vistas principales. Este menú añade comunicaciones, búsqueda, notas y estadísticas.'
  wrap.append(h, p)
  openPanel('AYUDA', wrap, source)
}

function showSettings(source: HTMLElement) {
  const settings = document.querySelector<HTMLButtonElement>('button[aria-label*="configuración" i],button[aria-label*="config" i]')
  if (settings) { settings.click(); return }
  const wrap = document.createElement('div')
  wrap.append(status('El panel de configuración se controla desde el editor de apariencia. La escala por defecto está fijada en 175%.'))
  openPanel('CONFIGURACIÓN', wrap, source)
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
      if (item.kind === 'messages') return void showMessages(button)
      if (item.kind === 'stats') return void showStats(button)
      if (item.kind === 'search') return void showSearch(button)
      if (item.kind === 'notes') return void showNotes(button)
      if (item.kind === 'settings') return showSettings(button)
      if (item.kind === 'help') return showHelp(button)
      return showAlliance(button)
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
  const observer = new MutationObserver(() => { if (document.querySelector('.neo-nav')) addExtras() })
  observer.observe(document.documentElement, { childList: true, subtree: true })
}

export {}
