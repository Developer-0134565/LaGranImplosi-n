export type DefinitionCostSource = {
  base_metal?: number | string | null
  base_crystal?: number | string | null
  base_deuterium?: number | string | null
  metal_cost?: number | string | null
  crystal_cost?: number | string | null
  deuterium_cost?: number | string | null
  base_research_time_seconds?: number | string | null
  base_build_time_seconds?: number | string | null
  base_build_time?: number | string | null
}

export type DefinitionKind = 'building' | 'research' | 'ship' | 'defense'

export function getDefinitionCost(
  definition: DefinitionCostSource,
  kind: DefinitionKind,
) {
  return {
    metal: kind === 'defense' ? definition.metal_cost : definition.base_metal,
    crystal: kind === 'defense' ? definition.crystal_cost : definition.base_crystal,
    deuterium: kind === 'defense' ? definition.deuterium_cost : definition.base_deuterium,
  }
}

export function getDefinitionBuildTime(
  definition: DefinitionCostSource,
  kind: DefinitionKind,
) {
  return kind === 'research'
    ? definition.base_research_time_seconds
    : kind === 'defense'
      ? definition.base_build_time
      : definition.base_build_time_seconds
}
