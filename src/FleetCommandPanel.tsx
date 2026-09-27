import { useCallback, useEffect, useState } from 'react'
import { supabase } from './lib/supabase'
import {
  CARGO_LOADABLE_MISSIONS,
  RECALLABLE_STATUSES,
  coordinates,
  errorMessage,
  humanSeconds,
  numberFormat,
  parseAmount,
  planetLabel,
  secondsUntil,
  stamp,
  type MovementRow,
  type MovementShip,
  type PlanetLabel,
} from './screens/fleet/fleetContracts'
import { FleetDispatchLegacyLayout } from './screens/fleet/FleetModules'
import { useFleetDispatch, type DispatchProps } from './screens/fleet/useFleetDispatch'

/*
  SUPERFICIE JUGABLE DE FLOTAS

  Este archivo ya NO contiene el motor de la superficie de flotas: durante la
  migración al LGI UI Engine, la lógica de despacho se movió a
  `src/screens/fleet/useFleetDispatch.ts` y la presentación a
  `src/screens/fleet/FleetModules.tsx`. Aquí quedan:

    * `FleetDispatchPanel` — adaptador de compatibilidad: misma API pública y
      mismo DOM que antes (layout heredado), ahora sobre los módulos
      compartidos. Lo usa la vista de expediciones, que aún no está migrada.
    * `ActiveFleetsPanel`   — BLOQUE B (movimientos activos), intacto.

  Regla de autoridad (sin cambios): ningún número, transición ni rechazo se
  decide aquí; todo viene de un contrato certificado en Supabase.
*/

/**
 * Bloque A (despacho) — adaptador de compatibilidad.
 *
 * Conserva exactamente la firma y el markup anteriores a la migración, pero
 * delega la lógica en el hook compartido del engine. Así la pantalla migrada y
 * la vista de expediciones siguen compartiendo UNA sola implementación.
 */
export function FleetDispatchPanel(props: DispatchProps) {
  const model = useFleetDispatch(props)
  return <FleetDispatchLegacyLayout model={model} />
}

type ActiveFleetsProps = {
  playerId?: string
  /** Limita la lista a una misión (la vista de expediciones usa EXPEDITION). */
  missionFilter?: string
  title?: string
  onChanged?: () => void
}

type CargoForm = {
  fleetId: string
  metal: string
  crystal: string
  deuterium: string
  totalCargo: number | null
  capacity: number | null
}

function phaseOf(row: MovementRow, now: number): { label: string; remaining: number | null } {
  if (row.status === 'OUTBOUND') return { label: 'LLEGADA', remaining: secondsUntil(row.arrives_at, now) }
  if (row.status === 'HOLDING') return { label: 'ESPERA HASTA', remaining: secondsUntil(row.holding_until, now) }
  if (row.status === 'RETURNING') return { label: 'RETORNO', remaining: secondsUntil(row.returns_at, now) }
  return { label: 'CICLO CERRADO', remaining: null }
}

export function ActiveFleetsPanel({ playerId, missionFilter, title, onChanged }: ActiveFleetsProps) {
  const [movements, setMovements] = useState<MovementRow[]>([])
  const [shipsByFleet, setShipsByFleet] = useState<Record<string, MovementShip[]>>({})
  const [shipNames, setShipNames] = useState<Record<string, string>>({})
  const [planetById, setPlanetById] = useState<Record<string, PlanetLabel>>({})
  const [now, setNow] = useState(() => Date.now())
  const [busyId, setBusyId] = useState<string | null>(null)
  const [cargoForm, setCargoForm] = useState<CargoForm | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    if (!playerId) return
    let query = supabase
      .from('fleet_movements')
      .select(
        'id,player_id,mission_type,status,origin_planet_id,destination_planet_id,destination_galaxy,destination_system,destination_position,started_at,arrives_at,returns_at,holding_until,fuel_consumed,metal,crystal,deuterium',
      )
      .eq('player_id', playerId)
      .order('created_at', { ascending: false })
      .limit(50)
    if (missionFilter) query = query.eq('mission_type', missionFilter)
    const { data, error: movementError } = await query
    if (movementError) {
      setError(movementError.message)
      return
    }
    const rows = data ?? []
    setMovements(rows)

    const fleetIds = rows.map((row) => row.id)
    const planetIds = Array.from(
      new Set(
        rows
          .flatMap((row) => [row.origin_planet_id, row.destination_planet_id])
          .filter((id): id is string => typeof id === 'string' && id.length > 0),
      ),
    )

    const shipRows: MovementShip[] = []
    if (fleetIds.length > 0) {
      const { data: cargoRows, error: shipError } = await supabase
        .from('fleet_movement_ships')
        .select('fleet_id,ship_id,quantity')
        .in('fleet_id', fleetIds)
      if (shipError) setError(shipError.message)
      else shipRows.push(...(cargoRows ?? []))
    }

    const planetRows: PlanetLabel[] = []
    if (planetIds.length > 0) {
      const { data: locations, error: planetError } = await supabase
        .from('planets')
        .select('id,name,galaxy,system,position,kind')
        .in('id', planetIds)
      if (planetError) setError(planetError.message)
      else planetRows.push(...(locations ?? []))
    }

    const { data: definitions, error: definitionError } = await supabase
      .from('ship_definitions')
      .select('id,name')
      .order('id')
    if (definitionError) setError(definitionError.message)

    const grouped: Record<string, MovementShip[]> = {}
    shipRows.forEach((row) => {
      const bucket = grouped[row.fleet_id] ?? []
      bucket.push(row)
      grouped[row.fleet_id] = bucket
    })
    setShipsByFleet(grouped)
    setShipNames(Object.fromEntries((definitions ?? []).map((definition) => [definition.id, definition.name])))
    setPlanetById(Object.fromEntries(planetRows.map((planet) => [planet.id, planet])))
  }, [playerId, missionFilter])

  useEffect(() => {
    void load()
  }, [load])

  useEffect(() => {
    const ticker = window.setInterval(() => setNow(Date.now()), 10000)
    return () => window.clearInterval(ticker)
  }, [])

  const liveCount = movements.filter((row) => !['COMPLETED', 'CANCELLED'].includes(row.status)).length

  useEffect(() => {
    if (liveCount === 0) return
    const timer = window.setInterval(() => {
      setNow(Date.now())
      void load()
    }, 20000)
    return () => window.clearInterval(timer)
  }, [liveCount, load])

  async function recall(fleetId: string) {
    if (!playerId) return
    setBusyId(fleetId)
    setError(null)
    setNotice(null)
    try {
      const { data, error: recallError } = await supabase.rpc('recall_fleet', {
        p_player_id: playerId,
        p_fleet_id: fleetId,
      })
      if (recallError) throw recallError
      const row = (data ?? [])[0]
      setNotice(
        row
          ? `Retirada aceptada · estado ${row.out_status} · regreso ${stamp(row.out_returns_at)} (${humanSeconds(row.out_seconds_remaining)})`
          : 'Retirada aceptada.',
      )
      await load()
      onChanged?.()
    } catch (recallError) {
      setError(errorMessage(recallError, 'No se pudo retirar la flota.'))
    } finally {
      setBusyId(null)
    }
  }

  /** Abre la bodega leyendo capacidad y carga actuales por el propio contrato: una carga de 0 no muta
   *  nada y devuelve la capacidad real calculada por el servidor. */
  async function openCargo(fleetId: string) {
    setBusyId(fleetId)
    setError(null)
    setNotice(null)
    try {
      const { data, error: cargoError } = await supabase.rpc('load_fleet_cargo', {
        p_fleet_id: fleetId,
        p_metal: 0,
        p_crystal: 0,
        p_deuterium: 0,
      })
      if (cargoError) throw cargoError
      const row = (data ?? [])[0]
      setCargoForm({
        fleetId,
        metal: '0',
        crystal: '0',
        deuterium: '0',
        totalCargo: row ? row.total_cargo : null,
        capacity: row ? row.cargo_capacity : null,
      })
    } catch (cargoError) {
      setError(errorMessage(cargoError, 'No se pudo consultar la bodega de la flota.'))
    } finally {
      setBusyId(null)
    }
  }

  async function submitCargo() {
    if (!cargoForm) return
    setBusyId(cargoForm.fleetId)
    setError(null)
    try {
      const { data, error: cargoError } = await supabase.rpc('load_fleet_cargo', {
        p_fleet_id: cargoForm.fleetId,
        p_metal: parseAmount(cargoForm.metal),
        p_crystal: parseAmount(cargoForm.crystal),
        p_deuterium: parseAmount(cargoForm.deuterium),
      })
      if (cargoError) throw cargoError
      const row = (data ?? [])[0]
      setNotice(
        row
          ? `Carga embarcada · total ${numberFormat(row.total_cargo)} / capacidad ${numberFormat(row.cargo_capacity)}`
          : 'Carga embarcada.',
      )
      setCargoForm(null)
      await load()
      onChanged?.()
    } catch (cargoError) {
      setError(errorMessage(cargoError, 'No se pudo embarcar la carga.'))
    } finally {
      setBusyId(null)
    }
  }

  function cargoSummary(row: MovementRow): string {
    const total = Number(row.metal) + Number(row.crystal) + Number(row.deuterium)
    if (total <= 0) return 'sin carga'
    return `${numberFormat(row.metal)} M · ${numberFormat(row.crystal)} C · ${numberFormat(row.deuterium)} D`
  }

  return (
    <section className="neo-panel">
      <div className="fleet-group-head">
        <h2>{title ?? 'FLOTAS ACTIVAS'}</h2>
        <span>
          {numberFormat(movements.length)} MOVIMIENTOS · {numberFormat(liveCount)} EN CURSO
          {missionFilter ? ` · ${missionFilter}` : ''}
        </span>
      </div>
      {notice && <p>{notice}</p>}
      {error && <p>ERROR: {error}</p>}

      {cargoForm && (
        <div className="fleet-controls">
          <span>
            BODEGA DE LA FLOTA {cargoForm.fleetId.slice(0, 8)}… · capacidad{' '}
            <b>{numberFormat(cargoForm.capacity)}</b> · carga actual <b>{numberFormat(cargoForm.totalCargo)}</b>
          </span>
          <label>
            <span>METAL</span>
            <input
              inputMode="numeric"
              value={cargoForm.metal}
              onChange={(event) =>
                setCargoForm((current) => (current ? { ...current, metal: event.target.value.replace(/[^0-9]/g, '') } : current))
              }
            />
          </label>
          <label>
            <span>CRISTAL</span>
            <input
              inputMode="numeric"
              value={cargoForm.crystal}
              onChange={(event) =>
                setCargoForm((current) => (current ? { ...current, crystal: event.target.value.replace(/[^0-9]/g, '') } : current))
              }
            />
          </label>
          <label>
            <span>DEUTERIO</span>
            <input
              inputMode="numeric"
              value={cargoForm.deuterium}
              onChange={(event) =>
                setCargoForm((current) => (current ? { ...current, deuterium: event.target.value.replace(/[^0-9]/g, '') } : current))
              }
            />
          </label>
          <button type="button" className="neo-button" disabled={busyId === cargoForm.fleetId} onClick={() => void submitCargo()}>
            {busyId === cargoForm.fleetId ? 'EMBARCANDO…' : 'EMBARCAR CARGA'}
          </button>
          <button type="button" className="neo-button secondary" onClick={() => setCargoForm(null)}>
            CANCELAR
          </button>
        </div>
      )}

      {movements.length === 0 ? (
        <div className="neo-empty">
          No hay movimientos de flota registrados para este jugador. El ciclo de vida es OUTBOUND → ARRIVED →
          RETURNING → COMPLETED, con HOLDING como estado persistido del apoyo ACS.
        </div>
      ) : (
        <div className="neo-list-panel">
          {movements.map((row) => {
            const phase = phaseOf(row, now)
            const ships = shipsByFleet[row.id] ?? []
            const recallable = RECALLABLE_STATUSES.includes(row.status)
            const loadable = row.status === 'OUTBOUND' && CARGO_LOADABLE_MISSIONS.includes(row.mission_type)
            return (
              <article className="neo-list-row" key={row.id}>
                <div>
                  <strong>{row.mission_type}</strong>
                  <small>
                    {planetLabel(planetById[row.origin_planet_id], row.origin_planet_id)} →{' '}
                    {coordinates(row.destination_galaxy, row.destination_system, row.destination_position)}
                    {row.destination_planet_id
                      ? ` · ${planetLabel(planetById[row.destination_planet_id], row.destination_planet_id)}`
                      : ''}
                  </small>
                  <small>
                    NAVES:{' '}
                    {ships.length > 0
                      ? ships
                          .map((ship) => `${shipNames[ship.ship_id] ?? ship.ship_id}×${numberFormat(ship.quantity)}`)
                          .join(', ')
                      : '—'}
                  </small>
                </div>
                <div>
                  <span className={`status-pill ${row.status.toLowerCase()}`}>{row.status}</span>
                  <small>
                    {phase.label}:{' '}
                    <b>{phase.remaining == null ? '—' : `${phase.remaining > 0 ? '' : '+'}${humanSeconds(phase.remaining)}`}</b>
                  </small>
                </div>
                <div>
                  <small>SALIDA <b>{stamp(row.started_at)}</b></small>
                  <small>LLEGADA <b>{stamp(row.arrives_at)}</b></small>
                  {row.holding_until && <small>ESPERA HASTA <b>{stamp(row.holding_until)}</b></small>}
                </div>
                <div>
                  <small>REGRESO <b>{stamp(row.returns_at)}</b></small>
                  <small>CARGA <b>{cargoSummary(row)}</b></small>
                  <small>COMBUSTIBLE <b>{numberFormat(row.fuel_consumed)}</b></small>
                  <div className="fleet-selection-tools">
                    {recallable && (
                      <button
                        type="button"
                        className="neo-button secondary"
                        disabled={busyId === row.id}
                        onClick={() => void recall(row.id)}
                      >
                        {busyId === row.id ? 'RETIRANDO…' : 'RETIRAR'}
                      </button>
                    )}
                    {loadable && (
                      <button
                        type="button"
                        className="neo-button secondary"
                        disabled={busyId === row.id}
                        onClick={() => void openCargo(row.id)}
                      >
                        BODEGA
                      </button>
                    )}
                  </div>
                </div>
              </article>
            )
          })}
        </div>
      )}
    </section>
  )
}
