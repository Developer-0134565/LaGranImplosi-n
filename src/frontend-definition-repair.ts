import { supabase } from './lib/supabase'

type Kind = 'building' | 'research' | 'ship' | 'defense'

type Definition = {
  id: string
  name: string
  description?: string | null
  max_level?: number | null
  ship_type?: string | null
  [key: string]: unknown
}

const KIND_BY_TITLE: Record<string, Kind> = {
  EDIFICIOS: 'building',
  'INVESTIGACIÓN': 'research',
  HANGAR: 'ship',
  DEFENSAS: 'defense',
}

let repairing = false

function currentKind(): Kind | null {
  const eyebrow = document.querySelector('.neo-main-view .neo-eyebrow')?.textContent ?? ''
  for (const [title, kind] of Object.entries(KIND_BY_TITLE)) {
    if (eyebrow.includes(title)) return kind
  }
  return null
}

async function getGuestContext() {
  const { data: players, error: pe } = await supabase
    .from('players')
    .select('id,username,is_guest')
    .eq('is_guest', true)
    .order('created_at', { ascending: true })

  if (pe || !players?.length) throw pe ?? new Error('No hay jugador invitado disponible.')

  const playerIds = players.map((p) => p.id)
  const { data: planets, error: ple } = await supabase
    .from('planets')
    .select('id,name,galaxy,system,position,is_homeworld,player_id')
    .in('player_id', playerIds)
    .eq('is_destroyed', false)
    .order('galaxy')
    .order('system')
    .order('position')

  if (ple || !planets?.length) throw ple ?? new Error('No hay planeta invitado disponible.')

  const homeworld = planets.find((p) => p.is_homeworld && p.name === 'Dev Homeworld')
    ?? planets.find((p) => p.is_homeworld)
    ?? planets[0]
  const player = players.find((p) => p.id === homeworld.player_id) ?? players[0]
  return { homeworld, player }
}

async function fetchDefinitions(kind: Kind): Promise<Definition[]> {
  if (kind === 'building') {
    const { data, error } = await supabase.from('building_definitions').select('id,name,description,max_level').order('id')
    if (error) throw error
    return (data ?? []) as Definition[]
  }
  if (kind === 'research') {
    const { data, error } = await supabase.from('research_definitions').select('id,name,description,max_level').order('id')
    if (error) throw error
    return (data ?? []) as Definition[]
  }
  if (kind === 'ship') {
    const { data, error } = await supabase
      .from('ship_definitions')
      .select('id,name,description,ship_type,base_metal,base_crystal,base_deuterium,attack,shield,hull,cargo_capacity,speed')
      .order('ship_type').order('id')
    if (error) throw error
    return (data ?? []) as Definition[]
  }
  const { data, error } = await supabase
    .from('defense_definitions')
    .select('id,name,description,metal_cost,crystal_cost,deuterium_cost,attack,shield,hull')
    .order('id')
  if (error) throw error
  return (data ?? []) as Definition[]
}

async function fetchOwned(kind: Kind, homeworldId: string, playerId: string) {
  if (kind === 'building') {
    const { data } = await supabase.from('planet_buildings').select('building_id,level').eq('planet_id', homeworldId)
    return Object.fromEntries((data ?? []).map((r) => [r.building_id, Number(r.level) || 0]))
  }
  if (kind === 'research') {
    const { data } = await supabase.from('player_research').select('research_id,level').eq('player_id', playerId)
    return Object.fromEntries((data ?? []).map((r) => [r.research_id, Number(r.level) || 0]))
  }
  if (kind === 'ship') {
    const { data } = await supabase.from('planet_ships').select('ship_id,quantity').eq('planet_id', homeworldId)
    return Object.fromEntries((data ?? []).map((r) => [r.ship_id, Number(r.quantity) || 0]))
  }
  const { data } = await supabase.from('planet_defenses').select('defense_id,quantity').eq('planet_id', homeworldId)
  return Object.fromEntries((data ?? []).map((r) => [r.defense_id, Number(r.quantity) || 0]))
}

function buildCard(kind: Kind, d: Definition, level: number, homeworldId: string, playerId: string) {
  const card = document.createElement('article')
  card.className = 'neo-panel neo-definition'
  card.dataset.frontendRepair = 'true'

  const title = document.createElement('div')
  title.className = 'neo-panel-title'
  const icon = kind === 'building' ? '▦' : kind === 'research' ? '⚗' : kind === 'ship' ? '✦' : '⬢'
  title.innerHTML = `<span>${icon} ${d.name}</span>`

  const body = document.createElement('div')
  body.className = 'neo-definition-body'
  const description = document.createElement('p')
  description.textContent = d.description || 'Sistema operativo del juego.'
  const current = document.createElement('strong')
  current.textContent = kind === 'building' || kind === 'research'
    ? `Nivel ${level}`
    : `Cantidad ${level}`
  body.append(description, current)

  const button = document.createElement('button')
  button.type = 'button'
  button.className = 'neo-button'
  button.textContent = kind === 'building' ? 'CONSTRUIR' : kind === 'research' ? 'INVESTIGAR' : kind === 'ship' ? 'CONSTRUIR' : 'FABRICAR'
  button.addEventListener('click', async () => {
    button.disabled = true
    try {
      const rpc = kind === 'building' ? 'start_building' : kind === 'research' ? 'start_research' : kind === 'ship' ? 'start_ship' : 'start_defense'
      const args = kind === 'building'
        ? { p_player_id: playerId, p_planet_id: homeworldId, p_building_id: d.id }
        : kind === 'research'
          ? { p_player_id: playerId, p_planet_id: homeworldId, p_research_id: d.id }
          : kind === 'ship'
            ? { p_player_id: playerId, p_planet_id: homeworldId, p_ship_id: d.id, p_quantity: 1 }
            : { p_player_id: playerId, p_planet_id: homeworldId, p_defense_id: d.id, p_quantity: 1 }
      const { error } = await supabase.rpc(rpc, args)
      if (error) throw error
      button.textContent = 'INICIADO'
    } catch (error) {
      button.disabled = false
      button.textContent = error instanceof Error ? error.message : 'ERROR'
    }
  })

  card.append(title, body, button)
  return card
}

async function repairCurrentView() {
  if (repairing) return
  const root = document.querySelector('.neo-main-view') as HTMLElement | null
  if (!root) return
  const kind = currentKind()
  if (!kind) return

  const counter = root.querySelector('.neo-counter')
  const grid = root.querySelector('.neo-card-grid') as HTMLElement | null
  if (!counter || !grid) return
  if (grid.children.length > 0) return
  if (!/0\s*ELEMENTOS/i.test(counter.textContent ?? '')) return

  repairing = true
  try {
    const [{ homeworld, player }, definitions] = await Promise.all([getGuestContext(), fetchDefinitions(kind)])
    const owned = await fetchOwned(kind, homeworld.id, player.id)
    if (!definitions.length) return

    grid.replaceChildren(...definitions.map((d) => buildCard(kind, d, owned[d.id] ?? 0, homeworld.id, player.id)))
    counter.textContent = `${definitions.length} ELEMENTOS`
  } catch (error) {
    const message = error instanceof Error ? error.message : 'No se pudo cargar el catálogo.'
    let diagnostic = root.querySelector('[data-frontend-repair-error]') as HTMLElement | null
    if (!diagnostic) {
      diagnostic = document.createElement('div')
      diagnostic.dataset.frontendRepairError = 'true'
      diagnostic.className = 'neo-panel'
      root.appendChild(diagnostic)
    }
    diagnostic.textContent = `CATÁLOGO: ${message}`
  } finally {
    repairing = false
  }
}

function install() {
  const observer = new MutationObserver(() => { void repairCurrentView() })
  observer.observe(document.body, { childList: true, subtree: true })
  void repairCurrentView()
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install, { once: true })
else install()
