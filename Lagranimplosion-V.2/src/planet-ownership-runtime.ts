import { supabase } from './lib/supabase'

type PlanetRow = { id: string; name: string; galaxy: number; system: number; position: number; is_homeworld: boolean; is_destroyed: boolean; player_id: string | null }
type PlayerRow = { id: string; username: string; is_guest: boolean; player_type: string }

let lastSignature = ''

async function syncOwnedPlanets() {
  const [{ data: planets, error: planetsError }, { data: players, error: playersError }] = await Promise.all([
    supabase.from('planets').select('id,name,galaxy,system,position,is_homeworld,is_destroyed,player_id').eq('is_destroyed', false).order('galaxy').order('system').order('position'),
    supabase.from('players').select('id,username,is_guest,player_type').eq('is_guest', true).eq('player_type', 'HUMAN'),
  ])

  if (planetsError || playersError) return

  const guestIds = new Set(((players ?? []) as PlayerRow[]).map((player) => player.id))
  const guestPlanets = ((planets ?? []) as PlanetRow[]).filter((planet) => planet.player_id && guestIds.has(planet.player_id))

  if (!guestPlanets.length) return

  // The current test universe has two historical guest DevPlayer records.
  // Prefer the guest player whose homeworld is literally "Homeworld", then
  // fall back to the first guest homeworld. This matches the active V2 planet.
  const preferred = guestPlanets.find((planet) => planet.is_homeworld && planet.name === 'Homeworld')
  const fallback = guestPlanets.find((planet) => planet.is_homeworld)
  const homeworld = preferred ?? fallback
  if (!homeworld?.player_id) return

  const owned = guestPlanets.filter((planet) => planet.player_id === homeworld.player_id)
  const signature = owned.map((planet) => `${planet.id}:${planet.name}:${planet.galaxy}:${planet.system}:${planet.position}`).join('|')
  if (signature === lastSignature) return
  lastSignature = signature

  const container = document.querySelector<HTMLElement>('.neo-owned-planets')
  if (!container) return

  const head = container.querySelector('.owned-planets-head')
  container.replaceChildren(...[
    ...(head ? [head] : []),
    ...owned.map((planet) => {
      const button = document.createElement('button')
      button.type = 'button'
      button.className = `owned-planet${planet.is_homeworld ? ' homeworld' : ''}`
      button.dataset.planetId = planet.id
      button.title = `${planet.name} [${planet.galaxy}:${planet.system}:${planet.position}]`
      button.innerHTML = `<span class="owned-planet-orb" aria-hidden="true">◉</span><span><strong>${planet.name}</strong><small>[${planet.galaxy}:${planet.system}:${planet.position}]</small></span>`
      return button
    }),
  ])
}

void syncOwnedPlanets()
window.setInterval(() => void syncOwnedPlanets(), 1500)
