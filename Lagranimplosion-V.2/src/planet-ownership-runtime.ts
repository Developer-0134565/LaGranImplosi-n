import { supabase } from './lib/supabase'

type PlanetRow = { id: string; name: string; galaxy: number; system: number; position: number; is_homeworld: boolean; is_destroyed: boolean; player_id: string | null }
type PlayerRow = { id: string; username: string; is_guest: boolean; player_type: string }

let lastSignature = ''
let syncTimer: number | null = null

function renderOwnedPlanets(owned: PlanetRow[]) {
  const container = document.querySelector<HTMLElement>('.neo-owned-planets')
  if (!container) return false

  const currentIds = Array.from(container.querySelectorAll<HTMLElement>('.owned-planet'))
    .map((node) => node.dataset.planetId || '')
    .filter(Boolean)
  const nextIds = owned.map((planet) => planet.id)
  if (currentIds.length === nextIds.length && currentIds.every((id, index) => id === nextIds[index])) return true

  const head = container.querySelector('.owned-planets-head')
  const fragment = document.createDocumentFragment()
  if (head) fragment.appendChild(head)

  for (const planet of owned) {
    const button = document.createElement('button')
    button.type = 'button'
    button.className = `owned-planet${planet.is_homeworld ? ' homeworld' : ''}`
    button.dataset.planetId = planet.id
    button.title = `${planet.name} [${planet.galaxy}:${planet.system}:${planet.position}]`

    const orb = document.createElement('span')
    orb.className = 'owned-planet-orb'
    orb.setAttribute('aria-hidden', 'true')
    orb.textContent = '◉'

    const text = document.createElement('span')
    const name = document.createElement('strong')
    name.textContent = planet.name
    const coords = document.createElement('small')
    coords.textContent = `[${planet.galaxy}:${planet.system}:${planet.position}]`
    text.append(name, coords)

    button.append(orb, text)
    fragment.appendChild(button)
  }

  container.replaceChildren(fragment)
  return true
}

async function syncOwnedPlanets() {
  const [{ data: planets, error: planetsError }, { data: players, error: playersError }] = await Promise.all([
    supabase.from('planets').select('id,name,galaxy,system,position,is_homeworld,is_destroyed,player_id').eq('is_destroyed', false).order('galaxy').order('system').order('position'),
    supabase.from('players').select('id,username,is_guest,player_type').eq('is_guest', true).eq('player_type', 'HUMAN'),
  ])

  if (planetsError || playersError) return

  const guestIds = new Set(((players ?? []) as PlayerRow[]).map((player) => player.id))
  const guestPlanets = ((planets ?? []) as PlanetRow[]).filter((planet) => planet.player_id && guestIds.has(planet.player_id))
  if (!guestPlanets.length) return

  const preferred = guestPlanets.find((planet) => planet.is_homeworld && planet.name === 'Homeworld')
  const fallback = guestPlanets.find((planet) => planet.is_homeworld)
  const homeworld = preferred ?? fallback
  if (!homeworld?.player_id) return

  const owned = guestPlanets.filter((planet) => planet.player_id === homeworld.player_id)
  const signature = owned.map((planet) => `${planet.id}:${planet.name}:${planet.galaxy}:${planet.system}:${planet.position}`).join('|')
  if (signature === lastSignature) {
    renderOwnedPlanets(owned)
    return
  }
  lastSignature = signature
  renderOwnedPlanets(owned)
}

function scheduleSync() {
  if (syncTimer !== null) window.clearTimeout(syncTimer)
  syncTimer = window.setTimeout(() => {
    syncTimer = null
    void syncOwnedPlanets()
  }, 0)
}

void syncOwnedPlanets()
window.setInterval(() => void syncOwnedPlanets(), 1500)

const observer = new MutationObserver(scheduleSync)
observer.observe(document.body, { childList: true, subtree: true })
