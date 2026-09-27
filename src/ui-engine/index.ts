/*
  LGI UI ENGINE — API pública

  Uso mínimo:
    <UIEngine template="classic">
      <FleetScreen />
    </UIEngine>

  Sin `template` explícito, el engine usa el seleccionado por el switcher DEV
  (React + localStorage). El engine NO conoce Supabase ni el gameplay.
*/

export { UIEngine } from './UIEngine'
export type { UIEngineProps } from './UIEngine'
export { UIEngineProvider } from './UIEngineProvider'
export { UIEngineScreen } from './UIEngineScreen'
export type { UIEngineScreenProps } from './UIEngineScreen'
export { UIDesigner } from './designer/UIDesigner'
export type { UIDesignerProps } from './designer/UIDesigner'
export { UIWorkbench } from './dev/UIWorkbench'
export {
  UI_WORKBENCH_HASH,
  isUIWorkbenchRequested,
  useUIWorkbenchRequested,
} from './dev/workbenchEntry'

export {
  UIResolutionContext,
  UIEngineContext,
  UIRegionContext,
  UI_TEMPLATE_STORAGE_KEY,
  UI_TEMPLATE_SWITCHER_STORAGE_KEY,
  useOptionalUIEngineContext,
  useUIEngineContext,
  useUIRegion,
  useUIResolution,
  useUITemplate,
  useUIDensity,
  useUITheme,
} from './context'
export type {
  UIEngineContextValue,
  UIRegionContextValue,
} from './context'

export {
  DEFAULT_UI_TEMPLATE_ID,
  UI_TEMPLATES,
  classicTemplate,
  commandTemplate,
  industrialTemplate,
  minimalTemplate,
  orbitalTemplate,
  getUITemplate,
  isUITemplateId,
  tacticalTemplate,
} from './templates'

export {
  UI_DESIGNER_STORAGE_KEY,
  UI_DESIGNER_CONFIG_VERSION,
  defaultUIDesignerConfig,
  sanitizeUIDesignerConfig,
  useUIDesignerConfig,
  useUIDesignerSelection,
  useUIDesignerState,
  getUIDesignerState,
  getUIDesignerOverride,
  hasUIDesignerLayout,
  resolveUILayout,
  resolveUIDesignerLayout,
  getUIModuleRegion,
  saveUIDesigner,
  discardUIDesignerChanges,
  resetUIDesigner,
  resetUIDesignerTemplateLayout,
  clearUIDesignerVariant,
  copyUIDesignerLayoutFromDesktop,
  moveUIDesignerModule,
  moveUIDesignerModuleOrder,
  setUIDesignerModuleSpan,
  setUIDesignerRegionColumns,
  setUIDesignerRegionTrack,
  selectUIDesignerModule,
  setUIDesignerBreakpoint,
  setUIDesignerDensity,
  setUIDesignerDeviceProfile,
  setUIDesignerFlag,
  setUIDesignerFont,
  setUIDesignerFontScale,
  setUIDesignerTemplate,
  setUIDesignerTheme,
  setUIDesignerUiScale,
  updateUIDesignerConfig,
} from './designer/designerStore'
export type {
  UIDesignerConfig,
  UIDesignerFlagKey,
  UIDesignerSelection,
  UIDesignerState,
  UILayoutOverrideMap,
} from './designer/designerStore'

export {
  DEFAULT_UI_FONT_ID,
  UI_FONT_OPTIONS,
  UI_FONT_SCALE_MAX,
  UI_FONT_SCALE_MIN,
  UI_FONT_SCALE_STEP,
  UI_FONT_SCALE_STEPS,
  UI_UI_SCALE_MAX,
  UI_UI_SCALE_MIN,
  UI_UI_SCALE_STEP,
  getUIFontOption,
} from './designer/typography'
export type { UIFontKind, UIFontOption } from './designer/typography'

export {
  DEFAULT_UI_DEVICE_PROFILE_ID,
  UI_DEVICE_PROFILES,
  getUIDeviceProfile,
  isUIDeviceProfileId,
} from './designer/deviceProfiles'
export type { UIDeviceFamily, UIDeviceProfile } from './designer/deviceProfiles'

export {
  MISSING_REFERENCE_ASSET,
  LGI_LOCAL_IMAGE_CANDIDATES,
  UI_REFERENCE_ASSETS,
  getUIReferenceAsset,
  referenceAssetsOfDomain,
} from './reference/referenceAssets'
export type { UIAssetDefinition, UIAssetOrigin, UIAssetProvenance } from './reference/referenceAssets'
export { ASSET_ORIGIN_LABEL } from './reference/referenceAssets'

export {
  UI_REFERENCE_DECKS,
  UI_REFERENCE_MODULE_IDS,
  getUIReferenceDeck,
} from './reference/referenceData'
export type { UIReferenceDeck, UIReferenceItem } from './reference/referenceData'

export {
  ReferenceAssetCard,
  ReferenceDeckPanel,
  ReferenceGrid,
  UIAllReferenceDecksScreen,
  UIReferenceDeckScreen,
} from './reference/ReferenceGrids'
export { referenceModuleIds, referenceRegistry } from './reference/referenceRegistry'

export { UI_DOMAINS, createUIRegistry, defineUIModule, mergeUIRegistries, moduleId } from './registry'
export type { UIRegistry } from './registry'

export { useContainerSize } from './adaptive/useContainerSize'
export type { ContainerSize } from './adaptive/useContainerSize'

export {
  ActionBar,
  CardGrid,
  Field,
  FieldRow,
  NoticeBar,
  Panel,
  Pill,
  ScreenHeader,
  StatGrid,
} from './components'
export type {
  ActionBarProps,
  CardGridProps,
  FieldProps,
  FieldRowProps,
  NoticeBarProps,
  PanelProps,
  PanelTone,
  PillTone,
  ScreenHeaderProps,
  StatGridProps,
  StatItem,
  StatTone,
} from './components'

export type {
  UIBreakpointId,
  UIDensity,
  UIDomainId,
  UIEngineResolution,
  UILayoutOverride,
  UIModuleDefinition,
  UIModuleId,
  UIModuleMap,
  UIRegionId,
  UIRegionTrack,
  UIResolvedLayout,
  UITemplate,
  UITemplateId,
  UITemplateLayoutVariants,
  UIThemeId,
} from './types'

export {
  UI_BREAKPOINTS,
  UI_REGION_IDS,
  breakpointForWidth,
  isUIBreakpointId,
  isUIRegionId,
} from './types'
