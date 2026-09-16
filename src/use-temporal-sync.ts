import { useEffect } from 'react'
import type { Dispatch, SetStateAction } from 'react'
import { supabase } from './lib/supabase'

type TemporalPlanet = {
  id: string
  name: string
  galaxy: number
  system: number
  position: number
  player_id: string
  is_homeworld: boolean
  is_destroyed: boolean
  universe_id?: string
  planet_resources?: Array<{ metal: number|string; crystal: number|string; deuterium: number|string; energy: number|string }>
}

const INTERVAL_MS = 10_000
const SELECT = 'id,name,galaxy,system,position,player_id,is_homeworld,is_destroyed,universe_id,planet_resources(metal,crystal,deuterium,energy)'

export function useTemporalSync(playerId: string|undefined, home: TemporalPlanet|undefined, setPlanets: Dispatch<SetStateAction<TemporalPlanet[]>>) {
  useEffect(() => {
    if (!playerId || !home) return
    let alive = true
    let running = false
    let resolvedUniverseId: string|undefined

    const sync = async () => {
      if (running) return
      running = true
      try {
        if (!resolvedUniverseId) {
          const { data: playerRow, error: playerError } = await supabase
            .from('players')
            .select('universe_id')
            .eq('id', playerId)
            .maybeSingle()

          if (playerError || !playerRow?.universe_id || !alive) return
          resolvedUniverseId = playerRow.universe_id
        }

        const { data: ownedPlanets, error: planetsError } = await supabase
          .from('planets')
          .select('id')
          .eq('universe_id', resolvedUniverseId)
          .eq('player_id', playerId)
          .eq('is_destroyed', false)

        if (planetsError || !alive) return

        const planetIds = (ownedPlanets ?? []).map(planet => planet.id)
        const results = await Promise.all(planetIds.map(async planetId => {
          const { error } = await supabase.rpc('sync_current_planet_resources', {
            p_player_id: playerId,
            p_planet_id: planetId,
            p_until: new Date().toISOString(),
          })
          if (error || !alive) return null

          const { data } = await supabase
            .from('planets')
            .select(SELECT)
            .eq('universe_id', resolvedUniverseId)
            .eq('id', planetId)
            .maybeSingle()

          return data ? [planetId, data as TemporalPlanet] as const : null
        }))

        if (alive) {
          const refreshed = new Map<string, TemporalPlanet>()
          for (const result of results) {
            if (result) refreshed.set(result[0], result[1])
          }
          if (refreshed.size) setPlanets(current => current.map(planet => refreshed.get(planet.id) ?? planet))
        }
      } finally {
        running = false
      }
    }

    void sync()
    const timer = window.setInterval(() => void sync(), INTERVAL_MS)
    return () => { alive = false; window.clearInterval(timer) }
  }, [playerId, home?.id, setPlanets])
}
