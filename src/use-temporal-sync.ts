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
  planet_resources?: Array<{ metal: number|string; crystal: number|string; deuterium: number|string; energy: number|string }>
}

const INTERVAL_MS = 10_000
const SELECT = 'id,name,galaxy,system,position,player_id,is_homeworld,is_destroyed,planet_resources(metal,crystal,deuterium,energy)'

export function useTemporalSync(playerId: string|undefined, home: TemporalPlanet|undefined, setPlanets: Dispatch<SetStateAction<TemporalPlanet[]>>) {
  useEffect(() => {
    if (!playerId || !home) return
    let alive = true
    let running = false
    const sync = async () => {
      if (running) return
      running = true
      try {
        const { error } = await supabase.rpc('sync_current_planet_resources', {
          p_player_id: playerId,
          p_planet_id: home.id,
          p_until: new Date().toISOString(),
        })
        if (error || !alive) return
        const { data } = await supabase.from('planets').select(SELECT).eq('id', home.id).maybeSingle()
        if (data && alive) {
          const fresh = data as TemporalPlanet
          setPlanets(current => current.map(planet => planet.id === fresh.id ? fresh : planet))
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
