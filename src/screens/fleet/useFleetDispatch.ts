import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../../lib/supabase'
import {
  IMMOBILE_SPEED,
  MISSION_BY_ID,
  MISSIONS,
  errorMessage,
  numberFormat,
  parseAmount,
  parseCoordinate,
  type ColonyCapRow,
  type ExpeditionSlotRow,
  type FleetSlotRow,
  type OwnedPlanet,
  type OwnedShip,
} from './fleetContracts'

/*
  LÓGICA DE DESPACHO — hook del engine.

  Este archivo contiene EXACTAMENTE la misma máquina de estados, efectos y
  llamadas a contratos que tenía `FleetDispatchPanel`: sólo se movió de lugar
  para que dos composiciones distintas (template del engine y layout heredado)
  compartan una única implementación. Ninguna regla de negocio cambió aquí.
*/

export type DispatchProps = {
  playerId?: string
  activePlanetId?: string
  universeId?: string
  /** Misión preseleccionada (la vista de expediciones monta el panel con EXPEDITION). */
  initialMission?: string
  /** Bloquea el selector de misión: la superficie sólo sirve a esa misión. */
  lockMission?: boolean
  onDispatched?: () => void
}

export type SupportAuthorization = {
  id: string
  label: string
  key: string
  galaxy: number
  system: number
  position: number
}

export function useFleetDispatch({
  playerId,
  activePlanetId,
  universeId,
  initialMission,
  lockMission,
  onDispatched,
}: DispatchProps) {
  const [planets, setPlanets] = useState<OwnedPlanet[]>([])
  const [originId, setOriginId] = useState('')
  const [mission, setMission] = useState<string>(initialMission ?? 'TRANSPORT')
  const [fleet, setFleet] = useState<OwnedShip[]>([])
  const [selection, setSelection] = useState<Record<string, number>>({})
  const [destination, setDestination] = useState({ galaxy: '', system: '', position: '' })
  const [cargo, setCargo] = useState({ metal: '0', crystal: '0', deuterium: '0' })
  const [holdingUntil, setHoldingUntil] = useState('')
  const [slots, setSlots] = useState<FleetSlotRow | null>(null)
  const [expeditionSlots, setExpeditionSlots] = useState<ExpeditionSlotRow | null>(null)
  const [colonyCap, setColonyCap] = useState<ColonyCapRow | null>(null)
  /** RECYCLE: does a recyclable debris field exist in my universe right now? Read-only hint from
   *  `get_recyclable_debris_status()`. It is EXISTENCE ONLY: the target selection stays inside
   *  `start_fleet_mixed`, so this never becomes a second source of truth. `null` = not loaded yet. */
  const [recyclableDebris, setRecyclableDebris] = useState<{ available: boolean; fields: number } | null>(null)
  /** Recursos del cuerpo de origen (lectura RLS del propio planeta): sólo informa la carga transportable.
   *  La autoridad sigue siendo `load_fleet_cargo` en el servidor. */
  const [originResources, setOriginResources] = useState<{ metal: number; crystal: number; deuterium: number } | null>(null)
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const [authorizations, setAuthorizations] = useState<SupportAuthorization[]>([])
  const missionDef = MISSION_BY_ID.get(mission) ?? MISSIONS[0]
  const origin = planets.find((planet) => planet.id === originId) ?? null
  const colonyShips = fleet.find((ship) => ship.ship_id === 'colony_ship')?.quantity ?? 0

  const loadSlots = useCallback(async () => {
    if (!playerId) return
    const { data, error: slotError } = await supabase.rpc('get_player_fleet_slots')
    if (slotError) {
      setError(slotError.message)
      return
    }
    setSlots((data ?? [])[0] ?? null)
  }, [playerId])

  const loadPlanets = useCallback(async () => {
    if (!playerId) return
    const { data, error: planetError } = await supabase
      .from('planets')
      .select('id,name,galaxy,system,position,kind,is_homeworld')
      .eq('player_id', playerId)
      .eq('is_destroyed', false)
      .order('is_homeworld', { ascending: false })
      .order('galaxy')
      .order('system')
      .order('position')
    if (planetError) {
      setError(planetError.message)
      return
    }
    setPlanets(data ?? [])
  }, [playerId])

  const loadOriginFleet = useCallback(async () => {
    if (!originId) {
      setFleet([])
      setOriginResources(null)
      return
    }
    const [shipResult, definitionResult, resourceResult] = await Promise.all([
      supabase.from('planet_ships').select('ship_id,quantity').eq('planet_id', originId).gt('quantity', 0).order('ship_id'),
      supabase.from('ship_definitions').select('id,name,ship_type,speed,cargo_capacity').order('id'),
      supabase.from('planet_resources').select('metal,crystal,deuterium').eq('planet_id', originId).maybeSingle(),
    ])
    if (shipResult.error) {
      setError(shipResult.error.message)
      return
    }
    if (definitionResult.error) {
      setError(definitionResult.error.message)
      return
    }
    /* La lectura de recursos sólo alimenta una línea informativa; si falla no se bloquea nada. */
    setOriginResources(resourceResult.error ? null : (resourceResult.data ?? null))
    const definitionsById = new Map((definitionResult.data ?? []).map((definition) => [definition.id, definition]))
    setFleet(
      (shipResult.data ?? []).map((row) => ({
        ship_id: row.ship_id,
        quantity: row.quantity,
        definition: definitionsById.get(row.ship_id) ?? null,
      })),
    )
    setSelection({})
  }, [originId])

  useEffect(() => {
    void loadSlots()
  }, [loadSlots])

  useEffect(() => {
    void loadPlanets()
  }, [loadPlanets])

  useEffect(() => {
    if (planets.length === 0) {
      setOriginId('')
      return
    }
    setOriginId((current) => {
      if (current && planets.some((planet) => planet.id === current)) return current
      const preferred = planets.find((planet) => planet.id === activePlanetId)
        ?? planets.find((planet) => planet.is_homeworld)
        ?? planets[0]
      return preferred.id
    })
  }, [planets, activePlanetId])

  useEffect(() => {
    void loadOriginFleet()
  }, [loadOriginFleet])

  useEffect(() => {
    if (missionDef.id !== 'EXPEDITION') {
      setExpeditionSlots(null)
      return
    }
    let cancelled = false
    void (async () => {
      const { data, error: slotError } = await supabase.rpc('get_player_expedition_slot_status')
      if (cancelled) return
      if (slotError) {
        setError(slotError.message)
        return
      }
      setExpeditionSlots((data ?? [])[0] ?? null)
    })()
    return () => {
      cancelled = true
    }
  }, [missionDef.id])

  useEffect(() => {
    if (missionDef.id !== 'COLONIZE' || !playerId) {
      setColonyCap(null)
      return
    }
    let cancelled = false
    void (async () => {
      const { data, error: capError } = await supabase.rpc('check_colony_cap', { p_player_id: playerId })
      if (cancelled) return
      if (capError) {
        setError(capError.message)
        return
      }
      setColonyCap((data ?? [])[0] ?? null)
    })()
    return () => {
      cancelled = true
    }
  }, [missionDef.id, playerId])

  /** RECYCLE: existence check only, so the player is told BEFORE pressing launch instead of learning
   *  it from 'No debris field available for RECYCLE' afterwards. The server remains the authority: if
   *  this says available, the dispatch is still validated by `start_fleet_mixed` as always. */
  useEffect(() => {
    if (missionDef.id !== 'RECYCLE') {
      setRecyclableDebris(null)
      return
    }
    let cancelled = false
    void (async () => {
      const { data, error: debrisError } = await supabase.rpc('get_recyclable_debris_status')
      if (cancelled) return
      // A failed read must not masquerade as "no debris": leave the hint unloaded and surface the reason.
      if (debrisError) { setError(debrisError.message); setRecyclableDebris(null); return }
      const row = (data as { out_available: boolean; out_field_count: number }[] | null)?.[0]
      setRecyclableDebris(row ? { available: row.out_available, fields: Number(row.out_field_count) } : null)
    })()
    return () => {
      cancelled = true
    }
  }, [missionDef.id])

  /** ACS_HOLD: autorizaciones RECIBIDAS y utilizables, para elegir destino sin teclear coordenadas a ciegas.
   *  La autoridad sigue siendo el servidor: si la autorización caduca o se revoca, el despacho la rechaza. */
  useEffect(() => {
    if (missionDef.destination !== 'FOREIGN_PLANET' || !playerId) {
      setAuthorizations([])
      return
    }
    let cancelled = false
    void (async () => {
      const { data, error: authError } = await supabase.rpc('get_player_support_authorizations')
      if (cancelled) return
      if (authError) {
        setError(authError.message)
        return
      }
      setAuthorizations(
        (data ?? [])
          .filter((row) => row.out_direction === 'RECEIVED')
          .map((row) => ({
            id: row.out_authorization_id,
            label: `${row.out_owner_username}${row.out_is_usable ? '' : ' (CADUCADA)'} · ${row.out_destination_name} [${row.out_galaxy}:${row.out_system}:${row.out_position}]`,
            key: `${row.out_galaxy}:${row.out_system}:${row.out_position}`,
            galaxy: row.out_galaxy,
            system: row.out_system,
            position: row.out_position,
          })),
      )
    })()
    return () => {
      cancelled = true
    }
  }, [missionDef.destination, playerId])

  const selectedShips = useMemo(
    () => Object.fromEntries(Object.entries(selection).filter(([, quantity]) => quantity > 0)),
    [selection],
  )
  const selectedCount = useMemo(
    () => Object.values(selection).reduce((sum, quantity) => sum + quantity, 0),
    [selection],
  )
  /** Cota inferior informativa: capacidad base declarada en `ship_definitions`. El servidor aplica sus
   *  propias bonificaciones y es quien valida la carga real. */
  const advisoryCapacity = useMemo(
    () =>
      fleet.reduce(
        (sum, ship) => sum + (selection[ship.ship_id] ?? 0) * Number(ship.definition?.cargo_capacity ?? 0),
        0,
      ),
    [fleet, selection],
  )

  function shipBlockReason(ship: OwnedShip): string | null {
    if (!ship.definition) return 'Sin definición de nave'
    if (Number(ship.definition.speed) <= IMMOBILE_SPEED) return 'Velocidad 0: el motor de flota la rechaza'
    if (missionDef.id === 'RECYCLE' && ship.ship_id !== 'recycler') return 'RECYCLE sólo admite recicladores'
    return null
  }

  function setShipAmount(ship: OwnedShip, value: number) {
    const amount = Math.max(0, Math.min(Math.floor(value || 0), ship.quantity))
    setSelection((current) => {
      const next = { ...current }
      if (amount > 0) next[ship.ship_id] = amount
      else delete next[ship.ship_id]
      return next
    })
  }

  /** Resuelve coordenadas → planeta/luna tal como lo necesitan los contratos (reciben el id, no coordenadas). */
  async function resolveDestinationPlanet(): Promise<{ id: string; owner: string | null; kind: string; label: string }> {
    if (!universeId) throw new Error('No se pudo identificar el universo activo.')
    const galaxy = parseCoordinate(destination.galaxy)
    const system = parseCoordinate(destination.system)
    const position = parseCoordinate(destination.position)
    if (galaxy == null || system == null || position == null) {
      throw new Error('Destino inválido: usa coordenadas [galaxia:sistema:posición].')
    }
    const { data, error: lookupError } = await supabase
      .from('planets')
      .select('id,name,galaxy,system,position,kind,player_id')
      .eq('universe_id', universeId)
      .eq('galaxy', galaxy)
      .eq('system', system)
      .eq('position', position)
      .eq('is_destroyed', false)
      .maybeSingle()
    if (lookupError) throw lookupError
    if (!data) throw new Error(`No existe ningún planeta ni luna en [${galaxy}:${system}:${position}].`)
    return {
      id: data.id,
      owner: data.player_id,
      kind: data.kind,
      label: `${data.name} [${data.galaxy}:${data.system}:${data.position}]${data.kind === 'MOON' ? ' · LUNA' : ''}`,
    }
  }

  async function dispatch() {
    if (!playerId || !originId) {
      setError('Selecciona el planeta de origen.')
      return
    }
    if (!missionDef.dispatchable) {
      setError(missionDef.note)
      return
    }
    if (busy) return
    setBusy(true)
    setError(null)
    setNotice(null)
    try {
      let fleetId: string | null = null
      if (missionDef.contract === 'start_colonize_fleet') {
        const galaxy = parseCoordinate(destination.galaxy)
        const system = parseCoordinate(destination.system)
        const position = parseCoordinate(destination.position)
        if (galaxy == null || system == null || position == null) {
          throw new Error('Indica las coordenadas de la nueva colonia [galaxia:sistema:posición].')
        }
        const { data, error: dispatchError } = await supabase.rpc('start_colonize_fleet', {
          p_player_id: playerId,
          p_origin_planet_id: originId,
          p_galaxy: galaxy,
          p_system: system,
          p_position: position,
        })
        if (dispatchError) throw dispatchError
        fleetId = (data ?? [])[0]?.fleet_id ?? null
      } else if (missionDef.contract === 'start_fleet_mixed') {
        if (selectedCount < 1) throw new Error('Selecciona al menos una nave.')
        let destinationId: string | null = null
        if (missionDef.destination === 'PLANET') {
          const target = await resolveDestinationPlanet()
          destinationId = target.id
          if (destinationId === originId) throw new Error('El destino debe ser distinto del planeta de origen.')
        }
        const { data, error: dispatchError } = await supabase.rpc('start_fleet_mixed', {
          p_player_id: playerId,
          p_origin_planet_id: originId,
          p_destination_planet_id: destinationId,
          p_ships: selectedShips,
          p_mission_type: missionDef.id,
        })
        if (dispatchError) throw dispatchError
        fleetId = (data ?? [])[0]?.fleet_id ?? null
      } else if (missionDef.contract === 'start_support_fleet') {
        if (selectedCount < 1) throw new Error('Selecciona al menos una nave.')
        if (!holdingUntil) throw new Error('Indica hasta cuándo debe esperar la flota (holding_until).')
        const target = await resolveDestinationPlanet()
        if (target.id === originId) throw new Error('El apoyo ACS exige un planeta extranjero.')
        const { data, error: dispatchError } = await supabase.rpc('start_support_fleet', {
          p_player_id: playerId,
          p_origin_planet_id: originId,
          p_destination_planet_id: target.id,
          p_ships: selectedShips,
          p_support_mission: missionDef.id,
          p_holding_until: new Date(holdingUntil).toISOString(),
          p_idempotency_key: crypto.randomUUID(),
        })
        if (dispatchError) throw dispatchError
        fleetId = (data ?? [])[0]?.fleet_id ?? null
      } else {
        if (selectedCount < 1) throw new Error('Selecciona al menos una nave.')
        if (!('deathstar' in selectedShips)) {
          throw new Error('La destrucción lunar exige al menos 1 deathstar en la composición.')
        }
        const target = await resolveDestinationPlanet()
        if (target.kind !== 'MOON') throw new Error('El destino de la destrucción lunar debe ser una luna.')
        if (target.owner === playerId) throw new Error('No se puede lanzar la destrucción contra una luna propia.')
        const { data: destroyedFleetId, error: dispatchError } = await supabase.rpc('start_moon_destruction', {
          p_player_id: playerId,
          p_origin_planet_id: originId,
          p_destination_planet_id: target.id,
          p_ships: selectedShips,
        })
        if (dispatchError) throw dispatchError
        fleetId = destroyedFleetId ?? null
      }

      let cargoMessage = ''
      const metal = parseAmount(cargo.metal)
      const crystal = parseAmount(cargo.crystal)
      const deuterium = parseAmount(cargo.deuterium)
      if (fleetId && missionDef.cargo && metal + crystal + deuterium > 0) {
        const { data: cargoData, error: cargoError } = await supabase.rpc('load_fleet_cargo', {
          p_fleet_id: fleetId,
          p_metal: metal,
          p_crystal: crystal,
          p_deuterium: deuterium,
        })
        if (cargoError) {
          cargoMessage = ` · la carga no se embarcó: ${errorMessage(cargoError, 'rechazada por el servidor')}`
        } else {
          const row = (cargoData ?? [])[0]
          if (row) {
            cargoMessage = ` · carga validada por el servidor ${numberFormat(row.total_cargo)} / ${numberFormat(row.cargo_capacity)}`
          }
        }
      }

      setNotice(
        `Despacho aceptado · ${missionDef.label} · ${missionDef.contract}`
          + `${fleetId ? ` · flota ${fleetId.slice(0, 8)}…` : ''}${cargoMessage}`,
      )
      setSelection({})
      setCargo({ metal: '0', crystal: '0', deuterium: '0' })
      await Promise.all([loadSlots(), loadOriginFleet()])
      onDispatched?.()
    } catch (dispatchError) {
      setError(errorMessage(dispatchError, 'No se pudo despachar la flota.'))
    } finally {
      setBusy(false)
    }
  }

  const civilShips = fleet.filter((ship) => ['civil', 'transport'].includes(ship.definition?.ship_type ?? ''))
  const supportShips = fleet.filter((ship) => (ship.definition?.ship_type ?? '') === 'support')
  const combatShips = fleet.filter((ship) => (ship.definition?.ship_type ?? '') === 'combat')
  const unknownShips = fleet.filter(
    (ship) => !['civil', 'transport', 'support', 'combat'].includes(ship.definition?.ship_type ?? ''),
  )
  const needsCoordinates = missionDef.destination !== 'OWN_SYSTEM_16' && missionDef.destination !== 'NEAREST_DEBRIS'
  const selectedSummary = Object.entries(selectedShips)
    .map(([shipId, quantity]) => `${shipId}×${quantity}`)
    .join(', ')
  const destinationKey = `${destination.galaxy}:${destination.system}:${destination.position}`
  const selectedAuthorization = authorizations.find((authorization) => authorization.key === destinationKey) ?? null
  /** Carga solicitada en la bodega (sólo informativa: `load_fleet_cargo` es quien valida y embarca). */
  const requestedCargo = useMemo(
    () => parseAmount(cargo.metal) + parseAmount(cargo.crystal) + parseAmount(cargo.deuterium),
    [cargo],
  )

  /** Bloqueo de lanzamiento derivado SÓLO de valores que devuelven los contratos del servidor: son los mismos
   *  estados con los que el backend rechaza el despacho (`FLEET_SLOTS_FULL`, `EXPEDITION_SLOTS_FULL`,
   *  `COLONY_CAP_REACHED`). Si un contrato aún no se ha cargado no se bloquea nada: el servidor decide. */
  const launchBlock = useMemo(() => {
    if (!missionDef.dispatchable) return missionDef.note
    if (slots && Number(slots.out_slots_available) <= 0) {
      return `Sin slots de flota libres (${numberFormat(slots.out_slots_in_use)} / ${numberFormat(slots.out_max_slots)} en uso): el servidor rechazará el despacho con FLEET_SLOTS_FULL.`
    }
    if (missionDef.id === 'EXPEDITION' && expeditionSlots && Number(expeditionSlots.available_slots) <= 0) {
      return `Sin slots de expedición libres (${numberFormat(expeditionSlots.used_slots)} / ${numberFormat(expeditionSlots.total_slots)} en uso): el servidor rechazará el despacho con EXPEDITION_SLOTS_FULL.`
    }
    if (missionDef.id === 'COLONIZE' && colonyCap && !colonyCap.allowed) {
      return `Colonización no permitida (${colonyCap.reason}): ${numberFormat(colonyCap.current_planets)} / ${numberFormat(colonyCap.max_slots)} colonias.`
    }
    /* RECYCLE: `start_fleet_mixed` raises 'No debris field available for RECYCLE' when no non-empty
       field exists, so this is the same precondition reported up front. Existence only — which field
       is chosen, and the recycler capacity, remain the engine's decision. */
    if (missionDef.id === 'RECYCLE' && recyclableDebris && !recyclableDebris.available) {
      return 'No hay campos de escombros reciclables en tu universo: el servidor rechazará el despacho con "No debris field available for RECYCLE".'
    }
    return null
  }, [missionDef, slots, expeditionSlots, colonyCap, recyclableDebris])

  return {
    /* contexto */
    playerId,
    universeId,
    lockMission,
    /* estado */
    planets,
    originId,
    setOriginId,
    mission,
    setMission,
    fleet,
    selection,
    destination,
    setDestination,
    cargo,
    setCargo,
    holdingUntil,
    setHoldingUntil,
    slots,
    expeditionSlots,
    colonyCap,
    recyclableDebris,
    originResources,
    busy,
    notice,
    error,
    authorizations,
    /* derivados */
    missionDef,
    origin,
    colonyShips,
    selectedShips,
    selectedCount,
    advisoryCapacity,
    civilShips,
    supportShips,
    combatShips,
    unknownShips,
    needsCoordinates,
    selectedSummary,
    selectedAuthorization,
    requestedCargo,
    launchBlock,
    /* acciones */
    dispatch,
    shipBlockReason,
    setShipAmount,
  }
}

/** Modelo que consumen las superficies de presentación (módulos del engine y layout heredado). */
export type FleetDispatchModel = ReturnType<typeof useFleetDispatch>
