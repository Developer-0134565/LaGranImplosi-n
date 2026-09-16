import { useEffect, useMemo } from 'react'
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
  planet_resources?: Array<{ metal: number|string; crystal: number|string; deuterium: number|string; energy: number|string }>
}

const INTERVAL_MS = 10_000
const SELECT = 'id,name,galaxy,system,position,player_id,is_homeworld,is_destroyed,planet_resources(metal,crystal,deuterium,energy)'

export function useTemporalSync(playerId: string|undefined, planets: TemporalPlanet[], setPlanets: Dispatch<SetStateAction<TemporalPlanet[]>>) {
  const planetIds = useMemo(
    () => planets.filter(planet => planet.player_id === playerId && !planet.is_destroyed).map(planet => planet.id).sort().join(','),
    [planets, playerId],
  )

  useEffect(() => {
    if (!playerId || !planetIds) return
    let alive = true
    let running = false

    const sync = async () => {
      if (running) return
      running = true
      try {
        const ids = planetIds.split(',').filter(Boolean)
        const refreshed = new Map<string, TemporalPlanet>()

        for (const planetId of ids) {
          const { error } = await supabase.rpc('sync_current_planet_resources', {
            p_player_id: playerId,
            p_planet_id: planetId,
            p_until: new Date().toISOString(),
          })
          if (error) continue

          const { data } = await supabase.from('planets').select(SELECT).eq('id', planetId).maybeSingle()
          if (data) refreshed.set(planetId, data as TemporalPlanet)
        }

        if (alive && refreshed.size) {
          setPlanets(current => current.map(planet => refreshed.get(planet.id) ?? planet))
        }
      } finally {
        running = false
      }
    }

    void sync()
    const timer = window.setInterval(() => void sync(), INTERVAL_MS)
    return () => { alive = false; window.clearInterval(timer) }
  }, [playerId, planetIds, setPlanets])
}
