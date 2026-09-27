import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'

/*
  Building demolition panel (downgrade) — exposes the LIVE contract added by
  20260926160000_building_demolition.sql.

  Authority rule: this panel decides nothing. `can_start_demolition` returns the cost, the duration, the ion
  level, the target level and the reason code for each owned building, and `start_demolition` is the only
  mutation. Every refusal is shown with the server's own reason (DEMOLITION_LEVEL_ZERO,
  DEMOLITION_BLOCKED_BY_DEPENDENTS, DEMOLITION_BLOCKED_BY_ACTIVE_RESEARCH,
  DEMOLITION_BLOCKED_BY_ACTIVE_UNIT_QUEUE, BUILDING_QUEUE_ALREADY_ACTIVE, INSUFFICIENT_RESOURCES, ...).

  Both contracts below are typed in database.types.ts (their entries were added by the
  2026-09-26 Supabase<->frontend contract audit).
*/

type DemolitionInfo = {
  allowed: boolean
  reason: string
  current_level: number
  target_level: number
  ion_technology_level: number
  cost_metal: number
  cost_crystal: number
  cost_deuterium: number
  duration_seconds: number
  available_metal: number
  available_crystal: number
  available_deuterium: number
  dependents_met: boolean
  research_idle: boolean
  unit_queue_idle: boolean
  queue_available: boolean
  is_downgrade: boolean
}

export type OwnedBuilding = { id: string; name: string; level: number }

const fmt = (value: number | null | undefined) => (value == null ? '—' : Math.floor(Number(value)).toLocaleString('es-ES'))

export default function BuildingDemolitionPanel({
  playerId,
  planetId,
  buildings,
  onDone,
}: {
  playerId?: string | null
  planetId?: string | null
  buildings: OwnedBuilding[]
  onDone?: () => void
}) {
  const [info, setInfo] = useState<Record<string, DemolitionInfo>>({})
  const [busy, setBusy] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!playerId || !planetId) return
    let cancelled = false
      let analysisError: string | null = null
    void (async () => {
      const entries = await Promise.all(
        buildings.map(async (building) => {
          const { data, error: inspectionError } = await supabase.rpc('can_start_demolition', {
            p_player_id: playerId,
            p_planet_id: planetId,
            p_building_id: building.id,
          })
          if (inspectionError) analysisError = inspectionError.message
          return [building.id, ((data ?? [])[0] ?? null) as DemolitionInfo | null] as const
        }),
      )
      if (!cancelled) {
        if (analysisError) setError(analysisError)
        setInfo(Object.fromEntries(entries.filter(([, row]) => Boolean(row)).map(([id, row]) => [id, row as DemolitionInfo])))
      }
    })()
    return () => {
      cancelled = true
    }
  }, [playerId, planetId, buildings])

  if (!playerId || !planetId || buildings.length === 0) return null

  async function demolish(building: OwnedBuilding, targetPlayerId: string, targetPlanetId: string) {
    setBusy(building.id)
    setNotice(null)
    setError(null)
    try {
      const { error: rpcError } = await supabase.rpc('start_demolition', {
        p_player_id: targetPlayerId,
        p_planet_id: targetPlanetId,
        p_building_id: building.id,
      })
      if (rpcError) throw rpcError
      setNotice(`${building.name}: demolición en cola hasta el nivel ${Math.max(0, building.level - 1)}.`)
      onDone?.()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No se pudo iniciar la demolición.')
    } finally {
      setBusy(null)
    }
  }

  return (
    <section className="neo-panel neo-definition">
      <div className="fleet-group-head">
        <h2>DEMOLICIÓN</h2>
        <span>
          RETIRAR UN NIVEL · COSTE = PRECIO DEL NIVEL −4 %/NIVEL DE ION · GUARDAS: DEPENDENCIAS, INVESTIGACIÓN
          ACTIVA, PEDIDO ACTIVO, COLA OCUPADA
        </span>
      </div>
      {notice && <div className="neo-empty">{notice}</div>}
      {error && <div className="neo-empty">ERROR: {error}</div>}
      <div className="neo-definition-list">
        {buildings.map((building) => {
          const row = info[building.id]
          return (
            <article className="neo-panel" key={building.id}>
              <div className="fleet-group-head">
                <h2>{building.name}</h2>
                <span>NIVEL {building.level}</span>
              </div>
              <div className="neo-definition-stats">
                <span>
                  COSTE <b>{row ? `${fmt(row.cost_metal)} / ${fmt(row.cost_crystal)} / ${fmt(row.cost_deuterium)}` : '—'}</b>
                </span>
                <span>
                  ION <b>{row ? row.ion_technology_level : '—'}</b>
                </span>
                <span>
                  DESTINO <b>{row ? row.target_level : '—'}</b>
                </span>
                <span>
                  SEGUNDOS <b>{row ? fmt(row.duration_seconds) : '—'}</b>
                </span>
                <span>
                  ESTADO <b>{row ? (row.allowed ? 'LISTO' : row.reason) : '—'}</b>
                </span>
              </div>
              <button type="button" className="neo-button" disabled={busy === building.id || !row?.allowed} onClick={() => void demolish(building, playerId, planetId)}>
                {busy === building.id ? 'DEMOLIENDO…' : 'DEMOLER UN NIVEL'}
              </button>
            </article>
          )
        })}
      </div>
    </section>
  )
}
