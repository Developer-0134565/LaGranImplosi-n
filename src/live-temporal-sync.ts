import { supabase } from './lib/supabase'

const SYNC_INTERVAL_MS = 10_000
const RESOURCE_SELECT = 'id,name,galaxy,system,position,is_homeworld,is_destroyed,players(id,username,is_guest),planet_resources(metal,crystal,deuterium,energy)'

type HomeworldRow = {
  id: string
  planet_resources?: Array<{ metal: number | string; crystal: number | string; deuterium: number | string; energy: number | string }>
  players?: Array<{ id: string; username: string; is_guest: boolean }>
}

function format(value: number | string | undefined) {
  const n = Number(value)
  return Number.isFinite(n) ? new Intl.NumberFormat('es-ES', { maximumFractionDigits: 0 }).format(n) : '—'
}

function paintResources(planet: HomeworldRow) {
  const resource = planet.planet_resources?.[0]
  if (!resource) return

  const values = [resource.metal, resource.crystal, resource.deuterium, resource.energy].map(format)
  document.querySelectorAll<HTMLElement>('.neo-resource-top .number').forEach((node, index) => {
    if (values[index] !== undefined) node.textContent = values[index]
  })
  document.querySelectorAll<HTMLElement>('.neo-resource .number').forEach((node, index) => {
    if (values[index] !== undefined) node.textContent = values[index]
  })

  const planetbar = document.querySelectorAll<HTMLElement>('.neo-planetbar-res span')
  if (planetbar[0]) planetbar[0].textContent = `M ${format(resource.metal)}`
  if (planetbar[1]) planetbar[1].textContent = `C ${format(resource.crystal)}`
}

async function sync() {
  const { data: homeworld, error: homeworldError } = await supabase
    .from('planets')
    .select(RESOURCE_SELECT)
    .eq('is_homeworld', true)
    .eq('is_destroyed', false)
    .limit(1)
    .maybeSingle()

  if (homeworldError || !homeworld) return
  const planet = homeworld as HomeworldRow
  const player = planet.players?.[0]
  if (!player) return

  const { error } = await supabase.rpc('sync_current_planet_resources', {
    p_player_id: player.id,
    p_planet_id: planet.id,
    p_until: new Date().toISOString(),
  })
  if (error) return

  const { data: fresh } = await supabase
    .from('planets')
    .select(RESOURCE_SELECT)
    .eq('id', planet.id)
    .maybeSingle()

  if (fresh) paintResources(fresh as HomeworldRow)

  // Let the existing React module loader refresh queues/statuses without creating a second UI.
  const active = document.querySelector<HTMLButtonElement>('.neo-nav-item.active')
  const label = active?.querySelector('b')?.textContent?.trim().toUpperCase()
  if (label && label !== 'OVERVIEW' && label !== 'PLANETAS') active?.click()
}

function boot() {
  void sync()
  const timer = window.setInterval(() => void sync(), SYNC_INTERVAL_MS)
  window.addEventListener('beforeunload', () => window.clearInterval(timer), { once: true })
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true })
else boot()
