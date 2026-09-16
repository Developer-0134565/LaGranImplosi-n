import { supabase } from './lib/supabase'

const rootSelector = '.neo-main-content'
const formatNumber = (value: unknown) => {
  const n = Number(value)
  return Number.isFinite(n) ? new Intl.NumberFormat('es-ES', { maximumFractionDigits: 0 }).format(n) : '—'
}
const duration = (value: unknown) => {
  const s = Math.max(0, Math.round(Number(value) || 0))
  if (!s) return '—'
  const d = Math.floor(s / 86400)
  const h = Math.floor((s % 86400) / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = s % 60
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : m ? `${m}m ${sec}s` : `${sec}s`
}
const remaining = (iso: string) => duration(Math.max(0, (new Date(iso).getTime() - Date.now()) / 1000))
const text = (value: unknown) => value === null || value === undefined || value === '' ? 'No definido' : String(value)

type Def = Record<string, any>
let observer: MutationObserver | null = null
let lastView = ''
let busy = false

function activeView() {
  return document.querySelector<HTMLElement>('.neo-nav-item.active b')?.textContent?.trim() || ''
}
function detail(label: string, value: unknown) {
  const span = document.createElement('span')
  const em = document.createElement('em')
  em.textContent = label
  const b = document.createElement('b')
  b.textContent = text(value)
  span.append(em, b)
  return span
}
function section(title: string, items: HTMLElement[]) {
  const box = document.createElement('div')
  box.className = 'v2-info-section'
  const h = document.createElement('strong')
  h.textContent = title
  box.append(h)
  const grid = document.createElement('div')
  grid.className = 'v2-info-grid'
  items.forEach(x => grid.append(x))
  box.append(grid)
  return box
}

async function enrichDefinitions(kind: 'building' | 'research' | 'ship' | 'defense') {
  const table = kind === 'building' ? 'building_definitions' : kind === 'research' ? 'research_definitions' : kind === 'ship' ? 'ship_definitions' : 'defense_definitions'
  const { data: defs, error } = await supabase.from(table).select('*')
  if (error || !defs) return
  const prereqTable = `${kind === 'ship' ? 'ship' : kind}_prerequisites`
  const { data: prereqs } = await supabase.from(prereqTable).select('*')
  const cards = Array.from(document.querySelectorAll<HTMLElement>('.neo-definition'))
  cards.forEach(card => {
    if (card.querySelector('.v2-info-section')) return
    const name = card.querySelector('.neo-panel-title strong')?.textContent?.trim()
    const def = (defs as Def[]).find(d => d.name === name)
    if (!def) return
    const id = String(def.id)
    const rows = (prereqs ?? []).filter((p: Def) => String(p[`${kind}_id`]) === id || String(p[`${kind === 'ship' ? 'ship' : kind}_id`]) === id)
    const req = rows.length
      ? rows.map((p: Def) => `${p.building_id || p.research_id || p.prerequisite_building_id || p.prerequisite_research_id || 'Requisito'} nivel ${p.required_level ?? '—'}`).join(' · ')
      : 'Sin requisitos registrados'
    const effect = def.effect ?? def.effect_description ?? def.production_effect ?? def.bonus ?? 'No definido en la definición'
    const status = kind === 'building' || kind === 'research'
      ? `Nivel actual mostrado en la tarjeta · máximo ${text(def.max_level)}`
      : 'Cantidad disponible mostrada en la tarjeta'
    const items: HTMLElement[] = [detail('REQUISITOS', req), detail('EFECTO', effect), detail('ESTADO', status)]
    if (kind === 'ship') items.push(detail('TIPO', def.ship_type))
    card.append(section('INFORMACIÓN DEL ELEMENTO', items))
  })
}

function enrichQueues() {
  document.querySelectorAll<HTMLElement>('.neo-queue').forEach(queue => {
    queue.querySelectorAll<HTMLElement>('.v2-queue-detail').forEach(x => x.remove())
    const spans = Array.from(queue.querySelectorAll<HTMLElement>(':scope > span'))
    spans.forEach(span => {
      const match = span.textContent?.match(/·\s*(\d{2}:\d{2}:\d{2})$/)
      if (!match) return
      const box = document.createElement('small')
      box.className = 'v2-queue-detail'
      box.textContent = ` · finalización indicada arriba · tiempo restante actualizado: ${match[1]}`
      span.append(box)
    })
  })
}

async function enrichFleet() {
  const playerName = document.querySelector('.neo-player strong')?.textContent?.trim()
  if (!playerName) return
  const { data: players } = await supabase.from('players').select('id').eq('username', playerName).limit(1)
  const playerId = players?.[0]?.id
  if (!playerId) return
  const { data: rows } = await supabase.from('fleet_movements').select('*').eq('player_id', playerId).order('created_at', { ascending: false }).limit(50)
  if (!rows) return
  document.querySelectorAll<HTMLElement>('.neo-list-row').forEach(row => {
    if (row.querySelector('.v2-info-section')) return
    const destination = row.querySelector('small')?.textContent?.match(/\[(\d+:\d+:\d+)\]/)?.[1]
    const found = rows.find((r: Def) => `[${r.destination_galaxy}:${r.destination_system}:${r.destination_position}]` === `[${destination}]`)
    if (!found) return
    const info = section('DETALLE DE MISIÓN', [
      detail('MISIÓN', found.mission_type),
      detail('ESTADO', found.status),
      detail('CARGA METAL', formatNumber(found.metal)),
      detail('CARGA CRISTAL', formatNumber(found.crystal)),
      detail('CARGA DEUTERIO', formatNumber(found.deuterium)),
      detail('COMBUSTIBLE', formatNumber(found.fuel_consumed)),
    ])
    row.append(info)
  })
}

async function enrichMessages() {
  const playerName = document.querySelector('.neo-player strong')?.textContent?.trim()
  if (!playerName) return
  const { data: players } = await supabase.from('players').select('id').eq('username', playerName).limit(1)
  const playerId = players?.[0]?.id
  if (!playerId) return
  const [{ data: combat }, { data: espionage }, { data: expedition }] = await Promise.all([
    supabase.from('combat_battles').select('*').eq('attacker_player_id', playerId).order('created_at', { ascending: false }).limit(25),
    supabase.from('espionage_reports').select('*').eq('player_id', playerId).order('created_at', { ascending: false }).limit(25),
    supabase.from('expedition_results').select('*').eq('player_id', playerId).order('created_at', { ascending: false }).limit(25),
  ])
  document.querySelectorAll<HTMLElement>('.message-row').forEach(row => {
    if (row.querySelector('.v2-info-section')) return
    const title = row.querySelector('strong')?.textContent?.trim() || ''
    const time = row.querySelector('time')?.textContent?.trim() || ''
    let source: Def | undefined
    let items: HTMLElement[] = []
    if (title.toLowerCase().includes('combate')) {
      source = combat?.find((r: Def) => new Date(r.created_at).toLocaleTimeString('es-ES', { hour: '2-digit', minute: '2-digit', second: '2-digit' }) === time)
      if (source) items = [detail('RESULTADO', source.attacker_win ? 'Victoria' : source.defender_win ? 'Derrota' : 'Empate'), detail('SAQUEO METAL', formatNumber(source.loot_metal)), detail('SAQUEO CRISTAL', formatNumber(source.loot_crystal)), detail('SAQUEO DEUTERIO', formatNumber(source.loot_deuterium)), detail('ATACANTE ANTES', formatNumber(source.attacker_ships_before)), detail('ATACANTE DESPUÉS', formatNumber(source.attacker_ships_after)), detail('DEFENSOR ANTES', formatNumber(source.defender_ships_before)), detail('DEFENSOR DESPUÉS', formatNumber(source.defender_ships_after))]
    } else if (title.toLowerCase().includes('espionaje')) {
      source = espionage?.find((r: Def) => new Date(r.created_at).toLocaleTimeString('es-ES', { hour: '2-digit', minute: '2-digit', second: '2-digit' }) === time)
      if (source) items = [detail('NIVEL PROPIO', source.espionage_level), detail('NIVEL OBJETIVO', source.target_espionage_level), detail('METAL', formatNumber(source.metal)), detail('CRISTAL', formatNumber(source.crystal)), detail('DEUTERIO', formatNumber(source.deuterium)), detail('FLOTA', JSON.stringify(source.fleet ?? {})), detail('DEFENSAS', JSON.stringify(source.defenses ?? {}))]
    } else if (title.toLowerCase().includes('expedición')) {
      source = expedition?.find((r: Def) => new Date(r.resolved_at ?? r.created_at).toLocaleTimeString('es-ES', { hour: '2-digit', minute: '2-digit', second: '2-digit' }) === time)
      if (source) items = [detail('RESULTADO', source.outcome), detail('EVENTO', source.event_type), detail('METAL', formatNumber(source.metal)), detail('CRISTAL', formatNumber(source.crystal)), detail('DEUTERIO', formatNumber(source.deuterium)), detail('MATERIA OSCURA', formatNumber(source.dark_matter)), detail('PÉRDIDA', JSON.stringify(source.lost_ships ?? {})), detail('ENEMIGO', JSON.stringify(source.enemy_ships ?? {}))]
    }
    if (items.length) row.append(section('INFORME DETALLADO', items))
  })
}

async function sync() {
  if (busy) return
  busy = true
  try {
    const view = activeView()
    if (view !== lastView) {
      lastView = view
      document.querySelectorAll('.v2-info-section').forEach(x => x.remove())
    }
    if (view === 'EDIFICIOS') await enrichDefinitions('building')
    else if (view === 'INVESTIGACIÓN') await enrichDefinitions('research')
    else if (view === 'HANGAR') await enrichDefinitions('ship')
    else if (view === 'DEFENSAS') await enrichDefinitions('defense')
    else if (view === 'FLOTA' || view === 'EXPEDICIONES') await enrichFleet()
    else if (view === 'MENSAJES') await enrichMessages()
    enrichQueues()
  } finally { busy = false }
}

function start() {
  observer = new MutationObserver(() => void sync())
  observer.observe(document.querySelector(rootSelector) || document.body, { childList: true, subtree: true })
  void sync()
  window.setInterval(() => void sync(), 2000)
  window.setInterval(() => {
    document.querySelectorAll<HTMLElement>('.v2-countdown[data-finishes]').forEach(el => { el.textContent = remaining(el.dataset.finishes || '') })
  }, 1000)
}

start()
