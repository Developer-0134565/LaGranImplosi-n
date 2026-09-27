import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'

/*
  SUPERFICIE LUNAR — BLOQUE E (falange + puerta de salto) sobre los contratos LIVE del motor lunar.

  Regla de autoridad: este panel no decide nada. El rango de la falange (`level² − 1`), su coste (5 000 de
  deuterio de la propia luna), la propiedad de ambas lunas, la transferibilidad de cada nave y el cooldown de la
  puerta de salto los determina el servidor; aquí sólo se muestran sus respuestas y sus rechazos literales
  (PHALANX_*, JUMP_GATE_*). No se reproduce ninguna fórmula en TypeScript.

  Contratos utilizados (todos LIVE, ninguno nuevo):
    get_player_moons()                                                · información de lunas propias
    scan_with_phalanx(p_player_id, p_moon_id, p_galaxy, p_system)      · falange
    execute_jump_gate(p_player_id, p_source_moon_id, p_target_moon_id, p_ships)
  Lecturas directas permitidas por RLS (propietario): `planet_ships`, `ship_definitions`.
*/

type MoonRow = {
  out_moon_id: string
  out_parent_planet_id: string
  out_parent_name: string | null
  out_name: string
  out_galaxy: number
  out_system: number
  out_position: number
  out_diameter_km: number
  out_fields_total: number
  out_fields_used: number
  out_cooldown_until: string | null
  out_metal: number
  out_crystal: number
  out_deuterium: number
  out_buildings: unknown
}

type PhalanxRow = {
  out_fleet_id: string
  out_player_id: string
  out_owner_name: string | null
  out_mission_type: string
  out_status: string
  out_destination_galaxy: number
  out_destination_system: number
  out_destination_position: number
  out_arrives_at: string
  out_returns_at: string | null
  out_ships: unknown
}

type MoonShip = { ship_id: string; quantity: number; name: string }

/** OGameX `JumpGateService` no transfiere satélites solares ni crawlers; el servidor los rechaza. */
const JUMP_GATE_BLOCKED_SHIPS = ['solar_satellite', 'crawler']

const numberFormat = (value: number | null | undefined) =>
  value == null ? '—' : Math.floor(Number(value)).toLocaleString('es-ES')

const stamp = (value: string | null | undefined) =>
  !value ? '—' : new Date(value).toLocaleString('es-ES')

function shipMapSummary(value: unknown): string {
  if (!value || typeof value !== 'object') return '—'
  const entries = Object.entries(value as Record<string, number>)
  if (entries.length === 0) return 'sin naves registradas'
  return entries.map(([shipId, quantity]) => `${shipId}×${numberFormat(Number(quantity))}`).join(', ')
}

const errorMessage = (value: unknown, fallback: string): string => {
  if (value instanceof Error) return value.message
  if (typeof value === 'object' && value !== null && 'message' in value) {
    const message = (value as { message?: unknown }).message
    if (typeof message === 'string' && message.length > 0) return message
  }
  return fallback
}

type MoonServicesProps = {
  playerId?: string
  /** Cuerpo activo de la superficie (para preseleccionar la luna sobre la que se opera). */
  activeBodyId?: string
  activeBodyIsMoon?: boolean
  /** Permite que la superficie activa pase a ser una luna desde este panel. */
  onSelectBody?: (bodyId: string) => void
  onChanged?: () => void
}

export function MoonServicesPanel({
  playerId,
  activeBodyId,
  activeBodyIsMoon,
  onSelectBody,
  onChanged,
}: MoonServicesProps) {
  const [moons, setMoons] = useState<MoonRow[]>([])
  const [sourceId, setSourceId] = useState('')
  const [targetId, setTargetId] = useState('')
  const [ships, setShips] = useState<MoonShip[]>([])
  const [jumpSelection, setJumpSelection] = useState<Record<string, number>>({})
  const [galaxy, setGalaxy] = useState('')
  const [system, setSystem] = useState('')
  const [scans, setScans] = useState<PhalanxRow[]>([])
  const [busy, setBusy] = useState<'scan' | 'jump' | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const loadMoons = useCallback(async () => {
    if (!playerId) return
    const { data, error: moonsError } = await supabase.rpc('get_player_moons')
    if (moonsError) {
      setError(moonsError.message)
      return
    }
    setMoons((data ?? []) as MoonRow[])
  }, [playerId])

  useEffect(() => {
    void loadMoons()
  }, [loadMoons])

  useEffect(() => {
    if (moons.length === 0) {
      setSourceId('')
      setTargetId('')
      return
    }
    setSourceId((current) => {
      if (current && moons.some((moon) => moon.out_moon_id === current)) return current
      const preferred = activeBodyIsMoon ? moons.find((moon) => moon.out_moon_id === activeBodyId) : undefined
      return (preferred ?? moons[0]).out_moon_id
    })
    setTargetId((current) => {
      if (current && moons.some((moon) => moon.out_moon_id === current)) return current
      return moons[0].out_moon_id
    })
  }, [moons, activeBodyId, activeBodyIsMoon])

  const source = moons.find((moon) => moon.out_moon_id === sourceId) ?? null
  const targetOptions = moons.filter((moon) => moon.out_moon_id !== sourceId)

  useEffect(() => {
    if (!source) return
    setGalaxy(String(source.out_galaxy))
    setSystem(String(source.out_system))
  }, [source])

  const loadShips = useCallback(async () => {
    if (!sourceId) {
      setShips([])
      return
    }
    const [shipResult, definitionResult] = await Promise.all([
      supabase.from('planet_ships').select('ship_id,quantity').eq('planet_id', sourceId).gt('quantity', 0).order('ship_id'),
      supabase.from('ship_definitions').select('id,name').order('id'),
    ])
    if (shipResult.error) {
      setError(shipResult.error.message)
      return
    }
    if (definitionResult.error) {
      setError(definitionResult.error.message)
      return
    }
    const names = new Map((definitionResult.data ?? []).map((definition) => [definition.id, definition.name]))
    setShips(
      (shipResult.data ?? []).map((row) => ({
        ship_id: row.ship_id,
        quantity: row.quantity,
        name: names.get(row.ship_id) ?? row.ship_id,
      })),
    )
    setJumpSelection({})
  }, [sourceId])

  useEffect(() => {
    void loadShips()
  }, [loadShips])

  const jumpShips = useMemo(
    () => Object.fromEntries(Object.entries(jumpSelection).filter(([, quantity]) => quantity > 0)),
    [jumpSelection],
  )
  const jumpCount = useMemo(
    () => Object.values(jumpSelection).reduce((sum, quantity) => sum + quantity, 0),
    [jumpSelection],
  )

  function setShipAmount(ship: MoonShip, value: number) {
    const amount = Math.max(0, Math.min(Math.floor(value || 0), ship.quantity))
    setJumpSelection((current) => {
      const next = { ...current }
      if (amount > 0) next[ship.ship_id] = amount
      else delete next[ship.ship_id]
      return next
    })
  }

  async function scan() {
    if (!playerId || !sourceId) {
      setError('Selecciona la luna desde la que escanear.')
      return
    }
    const targetGalaxy = Number.parseInt(galaxy, 10)
    const targetSystem = Number.parseInt(system, 10)
    if (!Number.isFinite(targetGalaxy) || !Number.isFinite(targetSystem) || targetGalaxy < 1 || targetSystem < 1) {
      setError('Indica galaxia y sistema objetivo.')
      return
    }
    setBusy('scan')
    setError(null)
    setNotice(null)
    setScans([])
    try {
      const { data, error: scanError } = await supabase.rpc('scan_with_phalanx', {
        p_player_id: playerId,
        p_moon_id: sourceId,
        p_galaxy: targetGalaxy,
        p_system: targetSystem,
      })
      if (scanError) throw scanError
      const rows = (data ?? []) as PhalanxRow[]
      setScans(rows)
      setNotice(
        rows.length > 0
          ? `Falange: ${rows.length} flota(s) en tránsito hacia [${targetGalaxy}:${targetSystem}]. El coste de 5.000 de deuterio lo cargó el servidor a la luna.`
          : `Falange sin contactos en [${targetGalaxy}:${targetSystem}]. El coste de 5.000 de deuterio lo cargó el servidor a la luna.`,
      )
      await loadMoons()
      onChanged?.()
    } catch (scanError) {
      setError(errorMessage(scanError, 'La falange rechazó el escaneo.'))
    } finally {
      setBusy(null)
    }
  }

  async function jump() {
    if (!playerId || !sourceId || !targetId) {
      setError('Selecciona la luna de origen y la de destino.')
      return
    }
    if (sourceId === targetId) {
      setError('El origen y el destino deben ser lunas distintas.')
      return
    }
    if (jumpCount < 1) {
      setError('Selecciona al menos una nave para el salto.')
      return
    }
    setBusy('jump')
    setError(null)
    setNotice(null)
    try {
      const { data, error: jumpError } = await supabase.rpc('execute_jump_gate', {
        p_player_id: playerId,
        p_source_moon_id: sourceId,
        p_target_moon_id: targetId,
        p_ships: jumpShips,
      })
      if (jumpError) throw jumpError
      const row = (data ?? [])[0]
      setNotice(
        row
          ? `Salto aceptado · naves ${shipMapSummary(row.out_ships)} · puerta en enfriamiento hasta ${stamp(row.out_cooldown_until)} (${numberFormat(row.out_cooldown_seconds)} s)`
          : 'Salto aceptado.',
      )
      setJumpSelection({})
      await Promise.all([loadMoons(), loadShips()])
      onChanged?.()
    } catch (jumpError) {
      setError(errorMessage(jumpError, 'La puerta de salto rechazó la operación.'))
    } finally {
      setBusy(null)
    }
  }

  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    const ticker = window.setInterval(() => setNow(Date.now()), 30000)
    return () => window.clearInterval(ticker)
  }, [])

  function buildingLevel(moon: MoonRow, buildingId: string): number {
    if (!moon.out_buildings || typeof moon.out_buildings !== 'object') return 0
    return Number((moon.out_buildings as Record<string, number | string>)[buildingId] ?? 0)
  }

  function cooldownLabel(moon: MoonRow): string {
    if (!moon.out_cooldown_until) return 'LISTA'
    const left = Math.floor((new Date(moon.out_cooldown_until).getTime() - now) / 1000)
    if (left <= 0) return 'LISTA'
    const minutes = Math.floor(left / 60)
    return `ENFRIANDO ${minutes > 0 ? `${minutes} min` : `${left} s`}`
  }

  return (
    <>
      <section className="neo-panel">
        <div className="fleet-group-head">
          <h2>LUNAS EN POSESIÓN</h2>
          <span>{numberFormat(moons.length)} · FALANGE Y PUERTA DE SALTO</span>
        </div>
        {error && <p>ERROR: {error}</p>}
        {notice && <p>{notice}</p>}
        {moons.length === 0 ? (
          <div className="neo-empty">
            No hay lunas: se forman cuando el campo de escombros de una batalla alcanza el tamaño mínimo y la
            tirada de creación acierta.
          </div>
        ) : (
          <div className="neo-list-panel">
            {moons.map((moon) => (
              <article className="neo-list-row" key={moon.out_moon_id}>
                <div>
                  <strong>{moon.out_name} [{moon.out_galaxy}:{moon.out_system}:{moon.out_position}]</strong>
                  <small>
                    Orbita {moon.out_parent_name ?? '—'} · diámetro {numberFormat(moon.out_diameter_km)} km
                  </small>
                </div>
                <div>
                  <small>CAMPOS <b>{numberFormat(moon.out_fields_used)} / {numberFormat(moon.out_fields_total)}</b></small>
                  <small>BASE LUNAR <b>{numberFormat(buildingLevel(moon, 'lunar_base'))}</b></small>
                </div>
                <div>
                  <small>FALANGE <b>{numberFormat(buildingLevel(moon, 'sensor_phalanx'))}</b></small>
                  <small>PUERTA DE SALTO <b>{numberFormat(buildingLevel(moon, 'jump_gate'))}</b></small>
                </div>
                <div>
                  <small>M / C / D <b>{`${numberFormat(moon.out_metal)} / ${numberFormat(moon.out_crystal)} / ${numberFormat(moon.out_deuterium)}`}</b></small>
                  <small>PUERTA <b>{cooldownLabel(moon)}</b></small>
                  <button
                    type="button"
                    className="neo-button secondary"
                    disabled={!onSelectBody || activeBodyId === moon.out_moon_id}
                    onClick={() => onSelectBody?.(moon.out_moon_id)}
                  >
                    {activeBodyId === moon.out_moon_id ? 'LUNA ACTIVA' : 'ACTIVAR LUNA'}
                  </button>
                </div>
              </article>
            ))}
          </div>
        )}
      </section>

      <section className="neo-panel">
        <div className="fleet-group-head">
          <h2>SENSOR FALANGE</h2>
          <span>RANGO Y COSTE VALIDADOS POR EL SERVIDOR</span>
        </div>
        <div className="fleet-controls">
          <label>
            <span>LUNA</span>
            <select value={sourceId} onChange={(event) => setSourceId(event.target.value)}>
              {moons.length === 0 && <option value="">Sin lunas</option>}
              {moons.map((moon) => (
                <option key={moon.out_moon_id} value={moon.out_moon_id}>
                  {moon.out_name} [{moon.out_galaxy}:{moon.out_system}:{moon.out_position}] · falange{' '}
                  {numberFormat(buildingLevel(moon, 'sensor_phalanx'))}
                </option>
              ))}
            </select>
          </label>
          <label>
            <span>GALAXIA</span>
            <input inputMode="numeric" value={galaxy} onChange={(event) => setGalaxy(event.target.value.replace(/[^0-9]/g, ''))} />
          </label>
          <label>
            <span>SISTEMA</span>
            <input inputMode="numeric" value={system} onChange={(event) => setSystem(event.target.value.replace(/[^0-9]/g, ''))} />
          </label>
          <button type="button" className="neo-button" disabled={busy === 'scan' || !sourceId} onClick={() => void scan()}>
            {busy === 'scan' ? 'ESCANEANDO…' : 'ESCANEAR SISTEMA'}
          </button>
        </div>
        <p>
          El alcance (nivel² − 1 sistemas, misma galaxia) y el coste de 5.000 de deuterio tomados de la propia
          luna son autoridad del servidor; aquí no se calcula nada.
        </p>
        {scans.length > 0 && (
          <div className="neo-list-panel">
            {scans.map((row) => (
              <article className="neo-list-row" key={row.out_fleet_id}>
                <div>
                  <strong>{row.out_owner_name ?? 'Jugador'} · {row.out_mission_type}</strong>
                  <small>
                    Destino [{row.out_destination_galaxy}:{row.out_destination_system}:{row.out_destination_position}] · {row.out_status}
                  </small>
                  <small>NAVES: {shipMapSummary(row.out_ships)}</small>
                </div>
                <span className={`status-pill ${row.out_status.toLowerCase()}`}>{row.out_status}</span>
                <div><small>LLEGADA</small><b>{stamp(row.out_arrives_at)}</b></div>
                <div><small>REGRESO</small><b>{stamp(row.out_returns_at)}</b></div>
              </article>
            ))}
          </div>
        )}
      </section>

      <section className="neo-panel">
        <div className="fleet-group-head">
          <h2>PUERTA DE SALTO</h2>
          <span>{numberFormat(jumpCount)} NAVES SELECCIONADAS</span>
        </div>
        <div className="fleet-controls">
          <label>
            <span>LUNA DE ORIGEN</span>
            <select value={sourceId} onChange={(event) => setSourceId(event.target.value)}>
              {moons.length === 0 && <option value="">Sin lunas</option>}
              {moons.map((moon) => (
                <option key={moon.out_moon_id} value={moon.out_moon_id}>
                  {moon.out_name} [{moon.out_galaxy}:{moon.out_system}:{moon.out_position}] · puerta{' '}
                  {numberFormat(buildingLevel(moon, 'jump_gate'))}
                </option>
              ))}
            </select>
          </label>
          <label>
            <span>LUNA DE DESTINO</span>
            <select value={targetId} onChange={(event) => setTargetId(event.target.value)}>
              {targetOptions.length === 0 && <option value="">Se necesitan dos lunas propias</option>}
              {targetOptions.map((moon) => (
                <option key={moon.out_moon_id} value={moon.out_moon_id}>
                  {moon.out_name} [{moon.out_galaxy}:{moon.out_system}:{moon.out_position}] · puerta{' '}
                  {numberFormat(buildingLevel(moon, 'jump_gate'))}
                </option>
              ))}
            </select>
          </label>
          <button
            type="button"
            className="neo-button"
            disabled={busy === 'jump' || !sourceId || !targetId || jumpCount < 1}
            onClick={() => void jump()}
          >
            {busy === 'jump' ? 'SALTANDO…' : 'EJECUTAR SALTO'}
          </button>
        </div>
        <p>
          Ambas lunas deben ser propias y tener puerta de salto; el cooldown (60 min base ajustados por la
          velocidad de flota de guerra y el nivel) y la no transferibilidad de satélites solares y crawlers los
          impone el servidor, que devuelve el enfriamiento resultante.
        </p>
        {ships.length === 0 ? (
          <div className="neo-empty">No hay naves en la luna de origen.</div>
        ) : (
          <div className="neo-card-grid">
            {ships.map((ship) => {
              const blocked = JUMP_GATE_BLOCKED_SHIPS.includes(ship.ship_id)
              return (
                <article className="neo-panel neo-definition" key={ship.ship_id}>
                  <div className="neo-panel-title">
                    <div>
                      <strong>{ship.name}</strong>
                      <small>{numberFormat(ship.quantity)} disponibles</small>
                      {blocked && <small>No transferible por la puerta de salto</small>}
                    </div>
                  </div>
                  <input
                    aria-label={`Cantidad de ${ship.name}`}
                    type="number"
                    min={0}
                    max={ship.quantity}
                    value={jumpSelection[ship.ship_id] ?? 0}
                    disabled={blocked}
                    onChange={(event) => setShipAmount(ship, Number(event.target.value))}
                  />
                  <button
                    type="button"
                    className="neo-button secondary"
                    disabled={blocked}
                    onClick={() => setShipAmount(ship, ship.quantity)}
                  >
                    TODO
                  </button>
                </article>
              )
            })}
          </div>
        )}
      </section>
    </>
  )
}

