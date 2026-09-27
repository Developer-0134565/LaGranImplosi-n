import type { ReactNode } from 'react'
import { Panel, ScreenHeader, UIEngineScreen, type UIModuleMap } from '../../ui-engine'
import { ActiveFleetsPanel } from '../../FleetCommandPanel'
import { FleetSlotsPanel } from '../../GameplayEnginePanel'
import { SupportAuthorizationPanel } from '../../SupportAuthorizationPanel'
import {
  FleetCargoModule,
  FleetCapacityModule,
  FleetCompositionNoteModule,
  FleetDestinationModule,
  FleetLaunchModule,
  FleetSetupModule,
  FleetShipGroupModule,
  FleetSlotsStatsModule,
} from './FleetModules'
import { FLEET_SHIP_GROUPS, fleetShipGroupModuleId, fleetShipsOfGroup } from './fleetShipGroups'
import { fleetModuleIds } from './fleetRegistry'
import { numberFormat } from './fleetContracts'
import { useFleetDispatch } from './useFleetDispatch'

/*
  PANTALLA DE FLOTAS (primer proof-of-concept del UI Engine)

  La pantalla declara sus módulos y el template decide dónde vive cada uno. La
  lógica de despacho vive en `useFleetDispatch`: exactamente la misma que tenía
  `FleetDispatchPanel`, sin cambios de contrato ni de mecánica.
*/

export type FleetScreenProps = {
  playerId?: string
  activePlanetId?: string
  universeId?: string
  onChanged?: () => void
}

export function FleetScreen({ playerId, activePlanetId, universeId, onChanged }: FleetScreenProps) {
  const model = useFleetDispatch({ playerId, activePlanetId, universeId, onDispatched: onChanged })
  const slotsMeta = model.slots
    ? `${numberFormat(model.slots.out_slots_available)} / ${numberFormat(model.slots.out_max_slots)} SLOTS LIBRES`
    : 'SLOTS —'
  const colonizing = model.missionDef.contract === 'start_colonize_fleet'
  const hasCapacity = model.missionDef.id === 'EXPEDITION' || model.missionDef.id === 'COLONIZE'

  const modules: Record<string, ReactNode> = {
    [fleetModuleIds.command]: (
      <ScreenHeader
        eyebrow="OPERACIONES · ESPACIO PROFUNDO"
        title="Flotas"
        description="Despacho, carga y ciclo de vida de los movimientos. Cada número proviene de un contrato del servidor."
        meta={slotsMeta}
      />
    ),

    [fleetModuleIds.slots]: (
      <Panel title="Slots de despacho" meta={slotsMeta} tone="accent">
        <FleetSlotsStatsModule model={model} />
      </Panel>
    ),

    [fleetModuleIds.setup]: (
      <Panel title="Origen y misión" meta={model.origin ? model.origin.name : 'SIN CUERPO'}>
        <FleetSetupModule model={model} />
      </Panel>
    ),

    [fleetModuleIds.destination]: (
      <Panel title="Destino" meta={model.missionDef.destination}>
        <FleetDestinationModule model={model} />
      </Panel>
    ),

    [fleetModuleIds.capacity]: (
      <Panel title="Capacidad operativa" tone="quiet">
        <FleetCapacityModule model={model} />
      </Panel>
    ),

    [fleetModuleIds.cargo]: (
      <Panel title="Bodega" meta={model.missionDef.cargo ? 'ADMITIDA' : 'NO ADMITIDA'}>
        <FleetCargoModule model={model} />
      </Panel>
    ),

    [fleetModuleIds.compositionNote]: <FleetCompositionNoteModule model={model} />,

    [fleetModuleIds.launch]: (
      <Panel title="Lanzamiento" tone="accent">
        <FleetLaunchModule model={model} />
      </Panel>
    ),

    [fleetModuleIds.slotSummary]: (
      <Panel tone="quiet">
        <FleetSlotsPanel playerId={playerId} />
      </Panel>
    ),

    [fleetModuleIds.supportAuthorizations]: (
      <Panel tone="quiet">
        <SupportAuthorizationPanel
          playerId={playerId}
          universeId={universeId}
          onChanged={onChanged}
        />
      </Panel>
    ),

    [fleetModuleIds.active]: (
      <Panel tone="quiet">
        <ActiveFleetsPanel playerId={playerId} onChanged={onChanged} />
      </Panel>
    ),
  }

  /** Un módulo por grupo de naves: el template decide dónde va cada grupo. */
  for (const group of FLEET_SHIP_GROUPS) {
    const ships = fleetShipsOfGroup(model, group.id)
    if (colonizing || ships.length === 0) continue
    modules[fleetShipGroupModuleId(group.id)] = (
      <Panel
        title={group.title}
        meta={`${numberFormat(ships.reduce((total, ship) => total + ship.quantity, 0))} DISPONIBLES`}
      >
        <FleetShipGroupModule model={model} group={group.id} />
      </Panel>
    )
  }

  /** `fleet.capacity` sólo existe cuando la misión tiene capacidad que mostrar
   *  (expedición o colonización): así ningún template deja un panel vacío. */
  if (!hasCapacity) delete modules[fleetModuleIds.capacity]

  return <UIEngineScreen id="fleet" modules={modules as UIModuleMap} />
}
