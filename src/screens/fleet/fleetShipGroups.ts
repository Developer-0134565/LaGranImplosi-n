import type { OwnedShip } from './fleetContracts'
import type { FleetDispatchModel } from './useFleetDispatch'

/*
  Grupos de naves de la superficie de flotas.

  Vive en su propio módulo (no en `FleetModules.tsx`) por dos razones:
    * `react-refresh/only-export-components`: un archivo de componentes no debe
      exportar constantes ni funciones;
    * el grupo de naves es una decisión de CLASIFICACIÓN, compartida por el
      registry, la pantalla y el layout heredado.
*/

/** Grupos de naves: cada uno es un módulo independiente para el template. */
export const FLEET_SHIP_GROUPS = [
  { id: 'civil', title: 'Naves civiles y de carga' },
  { id: 'support', title: 'Naves de apoyo' },
  { id: 'combat', title: 'Naves de combate' },
  { id: 'other', title: 'Otras naves' },
] as const

export type FleetShipGroupId = (typeof FLEET_SHIP_GROUPS)[number]['id']

/** Id de módulo del registry para un grupo de naves. */
export function fleetShipGroupModuleId(group: FleetShipGroupId): string {
  return `fleet.ships-${group}`
}

/** Naves del origen que pertenecen a un grupo (misma clasificación que antes de la migración). */
export function fleetShipsOfGroup(model: FleetDispatchModel, group: FleetShipGroupId): OwnedShip[] {
  if (group === 'civil') return model.civilShips
  if (group === 'support') return model.supportShips
  if (group === 'combat') return model.combatShips
  return model.unknownShips
}
