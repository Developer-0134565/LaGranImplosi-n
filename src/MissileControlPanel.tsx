import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'

/*
  Missile control panel - thin UI layer over the certified Missile System backend.

  Authority rule (this panel decides NOTHING):
    * production goes through `can_build_defense` (read) + `start_defense` (action);
    * the launch goes through `start_missile_attack` (action);
    * every refusal is rendered with the SERVER's own message, never replaced by a
      local guess. A capacity error says "Missile silo capacity exceeded: ..." because
      that is the string the server produced.

  What this panel deliberately does NOT do:
    * it exposes NO priority selector. Product decision D3 fixed the priority to
      `cheapest`, so the launch always sends target_priority = 0 and no control for it
      exists in the DOM. D4 (metal+crystal ordering) is backend-only.
    * it never writes planet_defenses, planet_buildings or fleet_movements.
    * it does not treat the IPM as a ship: it never reads fleet_movement_ships and the
      movement is shown from fleet_movements.missile_count.

  Capacity numbers here are DISPLAY ONLY. The authoritative gate lives in
  can_build_defense / start_defense / start_missile_attack, which re-reads the silo
  level, the inventory and the queue inside the transaction. The read-only helpers
  (calculate_missile_silo_slots, calculate_used_missile_slots, ...) are deliberately
  NOT granted to the client: that would bypass the owner-scoped RLS on
  planet_buildings and expose another empire's silo level.

  Target selection mirrors the existing galaxy convention: the UI resolves
  galaxy/system/position against the same universe the player is in, exactly as the
  galaxy view and the support panel already do. The server still validates that the
  target exists, is not your own body, is in the same galaxy and is in range.
*/

const ABM = 'anti_ballistic_missile'
const IPM = 'interplanetary_missile'

/** D1: certified slot cost. ABM 1, IPM 2. */
const SLOTS: Record<string, number> = { [ABM]: 1, [IPM]: 2 }

/** VERIFIED OGameX: range in systems = impulse_drive * 5 - 1. */
const rangeFor = (impulse: number) => Math.max(impulse * 5 - 1, 0)

const fmt = (value: number | null | undefined) =>
  value == null ? '-' : Math.floor(Number(value)).toLocaleString('es-ES')

type ProductionInfo = {
  allowed: boolean
  reason: string
  metal_cost: number
  crystal_cost: number
  deuterium_cost: number
  build_time_seconds: number
}

type MissileMovement = {
  id: string
  status: string
  missile_count: number
  started_at: string
  arrives_at: string
  destination_galaxy: number | null
  destination_system: number | null
  destination_position: number | null
}

type ResolvedTarget = {
  id: string
  name: string
  galaxy: number
  system: number
  position: number
  isOwn: boolean
}

export default function MissileControlPanel({
  playerId,
  planetId,
  universeId,
  originGalaxy,
  originSystem,
  onChanged,
}: {
  playerId?: string | null
  planetId?: string | null
  universeId?: string | null
  originGalaxy?: number | null
  originSystem?: number | null
  onChanged?: () => void
}) {
  const [siloLevel, setSiloLevel] = useState(0)
  const [owned, setOwned] = useState<Record<string, number>>({})
  const [queued, setQueued] = useState<Record<string, number>>({})
  const [impulse, setImpulse] = useState(0)
  const [production, setProduction] = useState<Record<string, ProductionInfo>>({})
  const [movements, setMovements] = useState<MissileMovement[]>([])
  const [busy, setBusy] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const [galaxy, setGalaxy] = useState('')
  const [system, setSystem] = useState('')
  const [position, setPosition] = useState('')
  const [quantity, setQuantity] = useState('1')
  const [target, setTarget] = useState<ResolvedTarget | null>(null)

  const ready = Boolean(playerId && planetId && universeId)

  const load = useCallback(async () => {
    if (!playerId || !planetId) return
    const [buildings, stock, queue, research, moves] = await Promise.all([
      supabase.from('planet_buildings').select('building_id,level').eq('planet_id', planetId),
      supabase.from('planet_defenses').select('defense_id,quantity').eq('planet_id', planetId),
      supabase
        .from('defense_queue')
        .select('defense_id,quantity')
        .eq('planet_id', planetId)
        .in('status', ['BUILDING', 'QUEUED']),
      supabase.from('player_research').select('level').eq('player_id', playerId).eq('research_id', 'impulse_drive'),
      supabase
        .from('fleet_movements')
        .select(
          'id,status,missile_count,started_at,arrives_at,destination_galaxy,destination_system,destination_position',
        )
        .eq('player_id', playerId)
        .eq('mission_type', 'MISSILE_ATTACK')
        .order('created_at', { ascending: false })
        .limit(10),
    ])

    const firstError = buildings.error ?? stock.error ?? queue.error ?? research.error ?? moves.error
    if (firstError) throw firstError

    setSiloLevel(Number((buildings.data ?? []).find((row) => row.building_id === 'missile_silo')?.level ?? 0))
    setOwned(Object.fromEntries((stock.data ?? []).map((row) => [row.defense_id, Number(row.quantity)])))
    setQueued(
      Object.fromEntries(
        (queue.data ?? [])
          .filter((row) => row.defense_id === ABM || row.defense_id === IPM)
          .map((row) => [row.defense_id, Number(row.quantity)]),
      ),
    )
    setImpulse(Number((research.data ?? [])[0]?.level ?? 0))
    setMovements((moves.data ?? []) as MissileMovement[])

    /* Server-authored feasibility per missile. The refusal text is kept verbatim. */
    const inspected = await Promise.all(
      [ABM, IPM].map(async (id) => {
        const { data, error: inspectionError } = await supabase.rpc('can_build_defense', {
          p_player_id: playerId,
          p_planet_id: planetId,
          p_defense_id: id,
          p_quantity: 1,
        })
        if (inspectionError) throw inspectionError
        return [id, ((data ?? [])[0] ?? null) as ProductionInfo | null] as const
      }),
    )
    setProduction(
      Object.fromEntries(inspected.filter(([, row]) => Boolean(row)).map(([id, row]) => [id, row as ProductionInfo])),
    )
  }, [playerId, planetId])

  useEffect(() => {
    let cancelled = false
    void (async () => {
      try {
        await load()
        if (!cancelled) {
          setError(null)
          setTarget(null)
        }
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : 'No se pudo leer el silo de misiles.')
      }
    })()
    return () => {
      cancelled = true
    }
  }, [load])

  /* Capacity is display only: the server re-derives it inside the transaction. */
  const capacity = siloLevel * 10
  const usedSlots = useMemo(
    () => [ABM, IPM].reduce((total, id) => total + (owned[id] ?? 0) * SLOTS[id], 0),
    [owned],
  )
  const queuedSlots = useMemo(
    () => [ABM, IPM].reduce((total, id) => total + (queued[id] ?? 0) * SLOTS[id], 0),
    [queued],
  )
  const freeSlots = Math.max(capacity - usedSlots - queuedSlots, 0)
  const maxRange = rangeFor(impulse)
  const ipmAvailable = owned[IPM] ?? 0

  const distance = useMemo(() => {
    const g = Number(galaxy)
    const s = Number(system)
    if (!originGalaxy || !originSystem || !Number.isFinite(g) || !Number.isFinite(s)) return null
    return g === originGalaxy ? Math.abs(originSystem - s) : null
  }, [galaxy, system, originGalaxy, originSystem])
  async function produce(id: string) {
    if (!playerId || !planetId) return
    setBusy(id)
    setNotice(null)
    setError(null)
    try {
      const { error: rpcError } = await supabase.rpc('start_defense', {
        p_player_id: playerId,
        p_planet_id: planetId,
        p_defense_id: id,
        p_quantity: 1,
      })
      if (rpcError) throw rpcError
      setNotice(`${id === ABM ? 'Misil antibalistico' : 'Misil interplanetario'}: produccion en cola.`)
      await load()
      onChanged?.()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No se pudo iniciar la produccion.')
    } finally {
      setBusy(null)
    }
  }

  /* Resolve coordinates against the SAME universe the player is in. The server
     re-validates existence, ownership, galaxy and range on the real launch. */
  async function resolveTarget() {
    if (!universeId) return
    setBusy('resolve')
    setError(null)
    setTarget(null)
    try {
      const g = Number(galaxy)
      const s = Number(system)
      const p = Number(position)
      if (![g, s, p].every((v) => Number.isInteger(v) && v >= 0)) {
        throw new Error('Coordenadas incompletas o no numericas.')
      }
      const { data, error: queryError } = await supabase
        .from('planets')
        .select('id,name,galaxy,system,position,kind,player_id')
        .eq('universe_id', universeId)
        .eq('galaxy', g)
        .eq('system', s)
        .eq('position', p)
        .limit(1)
      if (queryError) throw queryError
      const row = (data ?? [])[0]
      if (!row) throw new Error(`No hay ningun cuerpo en [${g}:${s}:${p}].`)
      setTarget({
        id: row.id,
        name: row.name,
        galaxy: row.galaxy,
        system: row.system,
        position: row.position,
        isOwn: row.player_id === playerId,
      })
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No se pudo resolver el objetivo.')
    } finally {
      setBusy(null)
    }
  }

  async function launch() {
    if (!playerId || !planetId || !target) return
    const qty = Number(quantity)
    if (!Number.isInteger(qty) || qty <= 0) {
      setError('La cantidad debe ser un entero mayor que 0.')
      return
    }
    setBusy('launch')
    setNotice(null)
    setError(null)
    try {
      const { error: rpcError } = await supabase.rpc('start_missile_attack', {
        p_player_id: playerId,
        p_origin_planet_id: planetId,
        p_destination_planet_id: target.id,
        p_quantity: qty,
        /* D3: cheapest is a fixed product decision. There is no control to change it. */
        p_target_priority: 0,
      })
      if (rpcError) throw rpcError
      setNotice(`${qty} IPM en vuelo hacia ${target.name}. El resultado llegara por el sistema de mensajes.`)
      setTarget(null)
      setQuantity('1')
      await load()
      onChanged?.()
    } catch (err) {
      /* The server message is shown as-is: it is the authoritative reason. */
      setError(err instanceof Error ? err.message : 'No se pudo lanzar el misil.')
    } finally {
      setBusy(null)
    }
  }

  if (!ready) return null
  return (
    <section className="neo-panel neo-definition">
      <div className="fleet-group-head">
        <h2>SILO DE MISILES</h2>
        <span>
          NIVEL {siloLevel} - {usedSlots} / {capacity} RANURAS OCUPADAS - {freeSlots} LIBRES - 1 RANURA POR ABM, 2
          POR IPM
        </span>
      </div>
      {notice && <div className="neo-empty">{notice}</div>}
      {error && <div className="neo-empty">ERROR: {error}</div>}

      <div className="neo-definition-list">
        {(
          [
            { id: ABM, label: 'MISIL ANTIBALISTICO', slots: SLOTS[ABM] },
            { id: IPM, label: 'MISIL INTERPLANETARIO', slots: SLOTS[IPM] },
          ] as const
        ).map((missile) => {
          const row = production[missile.id]
          return (
            <article className="neo-panel" key={missile.id}>
              <div className="fleet-group-head">
                <h2>{missile.label}</h2>
                <span>{missile.slots} RANURA(S) POR UNIDAD</span>
              </div>
              <div className="neo-definition-stats">
                <span>
                  EN TIENDA <b>{fmt(owned[missile.id] ?? 0)}</b>
                </span>
                <span>
                  EN COLA <b>{fmt(queued[missile.id] ?? 0)}</b>
                </span>
                <span>
                  COSTE{' '}
                  <b>{row ? `${fmt(row.metal_cost)} / ${fmt(row.crystal_cost)} / ${fmt(row.deuterium_cost)}` : '-'}</b>
                </span>
                <span>
                  ESTADO <b>{row ? (row.allowed ? 'LISTO' : row.reason) : '-'}</b>
                </span>
              </div>
              <button
                type="button"
                className="neo-button"
                disabled={busy === missile.id || !row?.allowed}
                onClick={() => void produce(missile.id)}
              >
                {busy === missile.id ? 'ENCOLANDO...' : 'PRODUCIR 1'}
              </button>
            </article>
          )
        })}
      </div>

      <div className="fleet-group-head">
        <h2>LANZAR IPM</h2>
        <span>
          ALCANCE MAXIMO {maxRange} SISTEMAS - IPM DISPONIBLES {ipmAvailable} - DESTINO POR COORDENADAS
        </span>
      </div>

      <div className="neo-definition-stats">
        <span>
          GALAXIA{' '}
          <input
            aria-label="Galaxia objetivo"
            value={galaxy}
            onChange={(e) => setGalaxy(e.target.value)}
            inputMode="numeric"
          />
        </span>
        <span>
          SISTEMA{' '}
          <input
            aria-label="Sistema objetivo"
            value={system}
            onChange={(e) => setSystem(e.target.value)}
            inputMode="numeric"
          />
        </span>
        <span>
          POSICION{' '}
          <input
            aria-label="Posicion objetivo"
            value={position}
            onChange={(e) => setPosition(e.target.value)}
            inputMode="numeric"
          />
        </span>
        <span>
          IPM{' '}
          <input
            aria-label="Cantidad de IPM"
            value={quantity}
            onChange={(e) => setQuantity(e.target.value)}
            inputMode="numeric"
          />
        </span>
        <span>
          DISTANCIA <b>{distance === null ? '-' : `${distance} SISTEMA(S)`}</b>
        </span>
        <span>
          OBJETIVO <b>{target ? `${target.name} [${target.galaxy}:${target.system}:${target.position}]` : '-'}</b>
        </span>
      </div>

      <div className="neo-definition-list">
        <button type="button" className="neo-button" disabled={busy === 'resolve'} onClick={() => void resolveTarget()}>
          {busy === 'resolve' ? 'BUSCANDO...' : 'BUSCAR OBJETIVO'}
        </button>
        <button
          type="button"
          className="neo-button"
          disabled={busy === 'launch' || !target || target.isOwn || ipmAvailable < 1}
          onClick={() => void launch()}
        >
          {busy === 'launch' ? 'LANZANDO...' : 'LANZAR IPM'}
        </button>
        {target?.isOwn && <div className="neo-empty">No puedes lanzar contra tu propio cuerpo.</div>}
        {distance !== null && distance > maxRange && (
          <div className="neo-empty">
            El objetivo esta a {distance} sistemas y tu alcance maximo es {maxRange}.
          </div>
        )}
      </div>

      {movements.length > 0 && (
        <>
          <div className="fleet-group-head">
            <h2>MISILES EN VUELO</h2>
            <span>ULTIMOS LANZAMIENTOS - EL RESULTADO LLEGA POR EL SISTEMA DE MENSAJES</span>
          </div>
          <div className="neo-definition-list">
            {movements.map((move) => (
              <article className="neo-panel" key={move.id}>
                <div className="fleet-group-head">
                  <h2>
                    {move.missile_count} IPM - [G{move.destination_galaxy}:S{move.destination_system}:
                    P{move.destination_position}]
                  </h2>
                  <span>{move.status}</span>
                </div>
                <div className="neo-definition-stats">
                  <span>
                    LLEGADA <b>{new Date(move.arrives_at).toLocaleString('es-ES')}</b>
                  </span>
                </div>
              </article>
            ))}
          </div>
        </>
      )}
    </section>
  )
}