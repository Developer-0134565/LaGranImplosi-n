import { MISSIONS, coordinates, numberFormat } from './fleetContracts'
import { FLEET_SHIP_GROUPS, fleetShipsOfGroup, type FleetShipGroupId } from './fleetShipGroups'
import type { FleetDispatchModel } from './useFleetDispatch'

/*
  MÓDULOS DE PRESENTACIÓN DE FLOTA

  Cada módulo es una unidad de UI que NO conoce su posición: sólo declara su
  contenido. El template decide en qué región vive y en qué orden.

  El markup es el mismo que tenía `FleetDispatchPanel` (mismas clases de
  contrato visual), así que el layout heredado se conserva idéntico y el layout
  del engine reutiliza exactamente los mismos componentes.
*/

/** Estadísticas de slots (sin cabecera: la aporta el contenedor). */
export function FleetSlotsStatsModule({ model }: { model: FleetDispatchModel }) {
  const { slots } = model
  return (
    <div className="neo-definition-stats">
      <span>TECNOLOGÍA DE ORDENADORES <b>{slots ? numberFormat(slots.out_computer_technology_level) : '—'}</b></span>
      <span>SLOTS MÁXIMOS <b>{slots ? numberFormat(slots.out_max_slots) : '—'}</b></span>
      <span>EN VUELO <b>{slots ? numberFormat(slots.out_slots_in_use) : '—'}</b></span>
      <span>LIBRES <b>{slots ? numberFormat(slots.out_slots_available) : '—'}</b></span>
    </div>
  )
}

/** Módulo completo de slots (cabecera + estadísticas). */
export function FleetSlotsModule({ model }: { model: FleetDispatchModel }) {
  const { slots } = model
  return (
    <>
      <div className="fleet-group-head">
        <h2>DESPACHO DE FLOTAS</h2>
        <span>
          {slots
            ? `${numberFormat(slots.out_slots_available)} / ${numberFormat(slots.out_max_slots)} SLOTS LIBRES`
            : 'SLOTS —'}
        </span>
      </div>
      <FleetSlotsStatsModule model={model} />
    </>
  )
}

export function FleetSetupModule({ model }: { model: FleetDispatchModel }) {
  const { planets, originId, setOriginId, mission, setMission, lockMission, missionDef, selectedCount, selectedSummary, origin } = model
  return (
    <>
      <div className="fleet-controls">
        <label>
          <span>PLANETA DE ORIGEN</span>
          <select value={originId} onChange={(event) => setOriginId(event.target.value)}>
            {planets.length === 0 && <option value="">Sin planetas en posesión</option>}
            {planets.map((planet) => (
              <option key={planet.id} value={planet.id}>
                {planet.name} [{planet.galaxy}:{planet.system}:{planet.position}]
                {planet.kind === 'MOON' ? ' · LUNA' : ''}
                {planet.is_homeworld ? ' · PRINCIPAL' : ''}
              </option>
            ))}
          </select>
        </label>
        <label>
          <span>MISIÓN</span>
          <select
            value={mission}
            disabled={lockMission === true}
            onChange={(event) => setMission(event.target.value)}
          >
            {MISSIONS.map((definition) => (
              <option key={definition.id} value={definition.id}>
                {definition.label} · {definition.klass}
                {definition.dispatchable ? '' : ' · NO DISPONIBLE'}
              </option>
            ))}
          </select>
        </label>
      </div>

      <div className="neo-definition-stats">
        <span>CLASE <b>{missionDef.klass}</b></span>
        <span>CONTRATO <b>{missionDef.contract}</b></span>
        <span>CARGA <b>{missionDef.cargo ? 'ADMITIDA' : 'NO ADMITIDA'}</b></span>
        <span>
          SELECCIÓN{' '}
          <b>{selectedCount > 0 ? `${numberFormat(selectedCount)} NAVES · ${selectedSummary}` : '—'}</b>
        </span>
        <span>ORIGEN <b>{origin ? `${origin.name} ${coordinates(origin.galaxy, origin.system, origin.position)}` : '—'}</b></span>
      </div>
      <p>{missionDef.note}</p>
    </>
  )
}

export function FleetDestinationModule({ model }: { model: FleetDispatchModel }) {
  const {
    missionDef,
    needsCoordinates,
    destination,
    setDestination,
    holdingUntil,
    setHoldingUntil,
    authorizations,
    selectedAuthorization,
  } = model
  return (
    <>
      {needsCoordinates && (
        <div className="fleet-controls">
          <label>
            <span>GALAXIA</span>
            <input
              inputMode="numeric"
              value={destination.galaxy}
              onChange={(event) => setDestination((current) => ({ ...current, galaxy: event.target.value.replace(/[^0-9]/g, '') }))}
            />
          </label>
          <label>
            <span>SISTEMA</span>
            <input
              inputMode="numeric"
              value={destination.system}
              onChange={(event) => setDestination((current) => ({ ...current, system: event.target.value.replace(/[^0-9]/g, '') }))}
            />
          </label>
          <label>
            <span>POSICIÓN</span>
            <input
              inputMode="numeric"
              value={destination.position}
              onChange={(event) => setDestination((current) => ({ ...current, position: event.target.value.replace(/[^0-9]/g, '') }))}
            />
          </label>
        </div>
      )}

      {missionDef.destination === 'OWN_SYSTEM_16' && (
        <p>
          El motor de flota fija el destino en la posición 16 del propio sistema; no se envían coordenadas.
          Consume un slot de expedición y un slot de flota.
        </p>
      )}
      {missionDef.destination === 'NEAREST_DEBRIS' && (
        <p>
          El motor de flota elige el campo de escombros más cercano al planeta de origen; no se envían
          coordenadas. La composición sólo puede contener recicladores.
        </p>
      )}
      {missionDef.destination === 'FOREIGN_PLANET' && (
        <>
          <div className="fleet-controls">
            <label>
              <span>AUTORIZACIÓN RECIBIDA</span>
              <select
                value={selectedAuthorization?.key ?? ''}
                onChange={(event) => {
                  const chosen = authorizations.find((authorization) => authorization.key === event.target.value)
                  if (!chosen) return
                  setDestination({
                    galaxy: String(chosen.galaxy),
                    system: String(chosen.system),
                    position: String(chosen.position),
                  })
                }}
              >
                <option value="">— elegir o escribir coordenadas —</option>
                {authorizations.map((authorization) => (
                  <option key={authorization.id} value={authorization.key}>
                    {authorization.label}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <p>
            Sólo aparecen las autorizaciones que otros jugadores te han concedido (contrato de descubrimiento
            owner-scoped). Si escribes coordenadas a mano, el servidor seguirá exigiendo la autorización vigente.
          </p>
          <label>
            <span>ESPERAR HASTA (HOLDING_UNTIL)</span>
            <input
              type="datetime-local"
              value={holdingUntil}
              onChange={(event) => setHoldingUntil(event.target.value)}
            />
          </label>
        </>
      )}
      {missionDef.destination === 'FOREIGN_MOON' && (
        <p>
          Indica las coordenadas de la luna objetivo. El contrato valida que sea una luna ajena no destruida y
          exige al menos un deathstar; el desenlace (éxito, pérdida de deathstars, escombros y mensajes) lo
          resuelve el hook de combate del motor certificado al terminar la batalla.
        </p>
      )}
    </>
  )
}

export function FleetCapacityModule({ model }: { model: FleetDispatchModel }) {
  const { missionDef, expeditionSlots, colonyCap, colonyShips } = model
  return (
    <>
      {missionDef.id === 'EXPEDITION' && (
        <div className="neo-definition-stats">
          <span>SLOTS BASE <b>{expeditionSlots ? numberFormat(expeditionSlots.base_slots) : '—'}</b></span>
          <span>AJUSTES DEL UNIVERSO <b>{expeditionSlots ? numberFormat(expeditionSlots.settings_bonus) : '—'}</b></span>
          <span>OBJETOS <b>{expeditionSlots ? numberFormat(expeditionSlots.item_bonus) : '—'}</b></span>
          <span>TOTAL <b>{expeditionSlots ? numberFormat(expeditionSlots.total_slots) : '—'}</b></span>
          <span>EN USO <b>{expeditionSlots ? numberFormat(expeditionSlots.used_slots) : '—'}</b></span>
          <span>LIBRES <b>{expeditionSlots ? numberFormat(expeditionSlots.available_slots) : '—'}</b></span>
        </div>
      )}

      {missionDef.id === 'COLONIZE' && (
        <div className="neo-definition-stats">
          <span>ASTROFÍSICA <b>{colonyCap ? numberFormat(colonyCap.astrophysics_level) : '—'}</b></span>
          <span>
            COLONIAS{' '}
            <b>{colonyCap ? `${numberFormat(colonyCap.current_planets)} / ${numberFormat(colonyCap.max_slots)}` : '—'}</b>
          </span>
          <span>CAP <b>{colonyCap ? (colonyCap.allowed ? 'PERMITIDO' : colonyCap.reason) : '—'}</b></span>
          <span>COLONY SHIPS EN ORIGEN <b>{numberFormat(colonyShips)}</b></span>
        </div>
      )}
    </>
  )
}

export function FleetCargoModule({ model }: { model: FleetDispatchModel }) {
  const { missionDef, cargo, setCargo, originResources, advisoryCapacity, requestedCargo } = model
  if (!missionDef.cargo) return null
  return (
    <>
      <div className="fleet-controls">
        <label>
          <span>METAL</span>
          <input
            inputMode="numeric"
            value={cargo.metal}
            onChange={(event) => setCargo((current) => ({ ...current, metal: event.target.value.replace(/[^0-9]/g, '') }))}
          />
        </label>
        <label>
          <span>CRISTAL</span>
          <input
            inputMode="numeric"
            value={cargo.crystal}
            onChange={(event) => setCargo((current) => ({ ...current, crystal: event.target.value.replace(/[^0-9]/g, '') }))}
          />
        </label>
        <label>
          <span>DEUTERIO</span>
          <input
            inputMode="numeric"
            value={cargo.deuterium}
            onChange={(event) => setCargo((current) => ({ ...current, deuterium: event.target.value.replace(/[^0-9]/g, '') }))}
          />
        </label>
      </div>

      <div className="neo-definition-stats">
        <span>
          DISPONIBLE EN ORIGEN{' '}
          <b>
            {originResources
              ? `${numberFormat(Number(originResources.metal))} M · ${numberFormat(Number(originResources.crystal))} C · ${numberFormat(Number(originResources.deuterium))} D`
              : '—'}
          </b>
        </span>
        <span>CAPACIDAD BASE DE LA SELECCIÓN <b>{numberFormat(advisoryCapacity)}</b></span>
        <span>CARGA SOLICITADA <b>{numberFormat(requestedCargo)}</b></span>
      </div>

      <p>
        La carga se embarca después del despacho con <b>load_fleet_cargo</b> (whitelist del servidor:
        TRANSPORT, ESPIONAGE, ACS_HOLD, DEPLOY, COLONIZE, EXPEDITION). Capacidad base de la selección:{' '}
        <b>{numberFormat(advisoryCapacity)}</b> · el servidor aplica sus bonificaciones y valida la carga real.
      </p>
    </>
  )
}

export function FleetLaunchModule({ model }: { model: FleetDispatchModel }) {
  const { missionDef, launchBlock, busy, playerId, originId, dispatch, notice, error } = model
  return (
    <>
      <div className="fleet-launch-head">
        <button
          type="button"
          className="neo-button"
          disabled={busy || !playerId || !originId || launchBlock !== null}
          onClick={() => void dispatch()}
        >
          {busy ? 'DESPACHANDO…' : `LANZAR ${missionDef.label}`}
        </button>
        {launchBlock && <small>{launchBlock}</small>}
      </div>

      {notice && <p>{notice}</p>}
      {error && <p>ERROR: {error}</p>}
    </>
  )
}

/**
 * Tarjetas de un grupo de naves, sin cabecera: la aporta el contenedor
 * (el `fleet-group-head` heredado o el `Panel` del engine).
 */
export function FleetShipGroupModule({
  model,
  group,
}: {
  model: FleetDispatchModel
  group: FleetShipGroupId
}) {
  const ships = fleetShipsOfGroup(model, group)
  const { selection, setShipAmount, shipBlockReason } = model
  if (model.missionDef.contract === 'start_colonize_fleet' || ships.length === 0) return null
  return (
    <div className="neo-card-grid">
      {ships.map((ship) => {
        const blocked = shipBlockReason(ship)
        const selected = selection[ship.ship_id] ?? 0
        return (
          <article className="neo-panel neo-definition" key={ship.ship_id}>
            <div className="neo-panel-title">
              <div>
                <strong>{ship.definition?.name ?? ship.ship_id}</strong>
                <small>
                  {numberFormat(ship.quantity)} disponibles · carga base {numberFormat(ship.definition?.cargo_capacity ?? 0)} ·
                  velocidad {numberFormat(ship.definition?.speed ?? 0)}
                </small>
                {blocked && <small>{blocked}</small>}
              </div>
            </div>
            <input
              aria-label={`Cantidad de ${ship.definition?.name ?? ship.ship_id}`}
              type="number"
              min={0}
              max={ship.quantity}
              value={selected}
              disabled={blocked !== null}
              onChange={(event) => setShipAmount(ship, Number(event.target.value))}
            />
            <button
              type="button"
              className="neo-button secondary"
              disabled={blocked !== null}
              onClick={() => setShipAmount(ship, ship.quantity)}
            >
              TODO
            </button>
          </article>
        )
      })}
    </div>
  )
}

/** Nota de COLONIZE: el contrato no recibe composición, así que sustituye a los grupos. */
export function FleetCompositionNoteModule({ model }: { model: FleetDispatchModel }) {
  if (model.missionDef.contract !== 'start_colonize_fleet') return null
  return (
    <p>
      COLONIZE no recibe composición: el contrato consume automáticamente 1 colony_ship y siembra la nueva
      colonia con la carga embarcada.
    </p>
  )
}

/** Composición heredada: los cuatro grupos con su cabecera, en secciones `neo-panel`. */
export function FleetCompositionLegacyModule({ model }: { model: FleetDispatchModel }) {
  if (model.missionDef.contract === 'start_colonize_fleet') {
    return <FleetCompositionNoteModule model={model} />
  }
  return (
    <>
      {FLEET_SHIP_GROUPS.map((group) => {
        const ships = fleetShipsOfGroup(model, group.id)
        if (ships.length === 0) return null
        return (
          <section className="neo-panel" key={group.id}>
            <div className="fleet-group-head">
              <h2>{group.title}</h2>
              <span>{numberFormat(ships.reduce((sum, ship) => sum + ship.quantity, 0))} DISPONIBLES</span>
            </div>
            <FleetShipGroupModule model={model} group={group.id} />
          </section>
        )
      })}
    </>
  )
}

/**
 * Composición HEREDADA del panel de despacho.
 *
 * Orden y envoltorio idénticos a los de `FleetDispatchPanel` antes de la
 * migración, para que las superficies no migradas (vista de expediciones)
 * sigan renderizando exactamente el mismo DOM. No es una segunda
 * implementación: son los mismos módulos en otro orden.
 */
export function FleetDispatchLegacyLayout({ model }: { model: FleetDispatchModel }) {
  return (
    <section className="neo-panel">
      <FleetSlotsModule model={model} />
      <FleetSetupModule model={model} />
      <FleetDestinationModule model={model} />
      <FleetCapacityModule model={model} />
      <FleetCargoModule model={model} />
      <FleetLaunchModule model={model} />
      <FleetCompositionLegacyModule model={model} />
    </section>
  )
}
