/*
  UI ENGINE — TYPOGRAPHY REGISTRY

  Registro de familias seleccionables desde el UI Designer.

  PROCEDENCIA (importante):

    * `origin: 'project'`  → la familia ya estaba cargada por el proyecto antes
      de esta misión (`index.html` y `src/styles/fonts.css` cargan Google Fonts
      por CDN). Esta misión NO añade ninguna dependencia de red nueva: el UI
      Engine sólo *selecciona* entre familias que el proyecto ya descargaba.
    * `origin: 'system'`   → pila del sistema: disponible sin red, sin licencia
      de terceros que distribuir.

  LICENCIA: todas las familias de Google Fonts listadas aquí se publican bajo
  SIL Open Font License 1.1 según su ficha pública, y se consumen desde el CDN
  del proveedor (no se redistribuyen archivos dentro del repositorio). Antes de
  un empaquetado definitivo hay que re-verificar cada ficha y valorar el
  alojamiento local; ver `docs/systems/README_UI_ENGINE.md`.

  Cada opción declara la pila COMPLETA con fallbacks, así que si el CDN no
  responde el texto sigue renderizando con la fuente de reserva.
*/

export type UIFontKind = 'system' | 'sans' | 'display' | 'techno' | 'condensed' | 'mono'

export type UIFontOption = {
  id: string
  label: string
  /** Pila CSS completa, con fallbacks. Cadena vacía = pipeline heredado. */
  stack: string
  kind: UIFontKind
  origin: 'project' | 'system'
  license: string
  source: string
  note?: string
}

const SYSTEM_SANS =
  'system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif'
const SYSTEM_MONO =
  'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace'
const SANS_FALLBACK = '"Inter", ' + SYSTEM_SANS
const MONO_FALLBACK = '"JetBrains Mono", ' + SYSTEM_MONO

function family(name: string, fallback: string): string {
  return `"${name}", ${fallback}`
}

const CDN = 'Google Fonts (CDN ya cargado por el proyecto antes de esta misión)'
const CDN_BOTH = 'Google Fonts (CDN ya cargado por index.html y src/styles/fonts.css)'
const SYSTEM_LICENSE = 'No aplica (fuentes del sistema operativo)'

export const UI_FONT_OPTIONS: readonly UIFontOption[] = [
  {
    id: 'project',
    label: 'Proyecto (heredada)',
    stack: '',
    kind: 'system',
    origin: 'system',
    license: 'No aplica (pipeline de fuentes del proyecto)',
    source: 'src/styles/fonts.css',
    note: 'Deja la tipografía al pipeline heredado del proyecto.',
  },
  {
    id: 'system',
    label: 'System UI',
    stack: SYSTEM_SANS,
    kind: 'system',
    origin: 'system',
    license: SYSTEM_LICENSE,
    source: 'Pila del sistema',
  },
  {
    id: 'inter',
    label: 'Inter',
    stack: SANS_FALLBACK,
    kind: 'sans',
    origin: 'project',
    license: 'OFL-1.1',
    source: CDN,
  },
  {
    id: 'space-grotesk',
    label: 'Space Grotesk',
    stack: family('Space Grotesk', SANS_FALLBACK),
    kind: 'sans',
    origin: 'project',
    license: 'OFL-1.1',
    source: CDN,
  },
  {
    id: 'exo-2',
    label: 'Exo 2',
    stack: family('Exo 2', SANS_FALLBACK),
    kind: 'techno',
    origin: 'project',
    license: 'OFL-1.1',
    source: CDN_BOTH,
  },
  {
    id: 'rajdhani',
    label: 'Rajdhani',
    stack: family('Rajdhani', SANS_FALLBACK),
    kind: 'condensed',
    origin: 'project',
    license: 'OFL-1.1',
    source: CDN_BOTH,
  },
  {
    id: 'oxanium',
    label: 'Oxanium',
    stack: family('Oxanium', SANS_FALLBACK),
    kind: 'techno',
    origin: 'project',
    license: 'OFL-1.1',
    source: CDN_BOTH,
  },
  {
    id: 'orbitron',
    label: 'Orbitron',
    stack: family('Orbitron', SANS_FALLBACK),
    kind: 'display',
    origin: 'project',
    license: 'OFL-1.1',
    source: CDN,
    note: 'Ancha: en densidades apretadas puede forzar saltos de línea.',
  },
  {
    id: 'chakra-petch',
    label: 'Chakra Petch',
    stack: family('Chakra Petch', SANS_FALLBACK),
    kind: 'techno',
    origin: 'project',
    license: 'OFL-1.1',
    source: CDN_BOTH,
  },
  {
    id: 'titillium-web',
    label: 'Titillium Web',
    stack: family('Titillium Web', SANS_FALLBACK),
    kind: 'sans',
    origin: 'project',
    license: 'OFL-1.1',
    source: CDN_BOTH,
  },
  {
    id: 'teko',
    label: 'Teko',
    stack: family('Teko', SANS_FALLBACK),
    kind: 'condensed',
    origin: 'project',
    license: 'OFL-1.1',
    source: CDN_BOTH,
    note: 'Muy condensada: útil en paneles densos, floja en párrafos largos.',
  },
  {
    id: 'audiowide',
    label: 'Audiowide',
    stack: family('Audiowide', SANS_FALLBACK),
    kind: 'display',
    origin: 'project',
    license: 'OFL-1.1',
    source: CDN_BOTH,
  },
  {
    id: 'michroma',
    label: 'Michroma',
    stack: family('Michroma', SANS_FALLBACK),
    kind: 'display',
    origin: 'project',
    license: 'OFL-1.1',
    source: CDN_BOTH,
  },
  {
    id: 'russo-one',
    label: 'Russo One',
    stack: family('Russo One', SANS_FALLBACK),
    kind: 'display',
    origin: 'project',
    license: 'OFL-1.1',
    source: CDN_BOTH,
  },
  {
    id: 'electrolize',
    label: 'Electrolize',
    stack: family('Electrolize', SANS_FALLBACK),
    kind: 'techno',
    origin: 'project',
    license: 'OFL-1.1',
    source: CDN_BOTH,
  },
  {
    id: 'unica-one',
    label: 'Unica One',
    stack: family('Unica One', SANS_FALLBACK),
    kind: 'display',
    origin: 'project',
    license: 'OFL-1.1',
    source: CDN_BOTH,
  },
  {
    id: 'zen-dots',
    label: 'Zen Dots',
    stack: family('Zen Dots', SANS_FALLBACK),
    kind: 'display',
    origin: 'project',
    license: 'OFL-1.1',
    source: CDN_BOTH,
  },
  {
    id: 'jetbrains-mono',
    label: 'JetBrains Mono',
    stack: MONO_FALLBACK,
    kind: 'mono',
    origin: 'project',
    license: 'OFL-1.1',
    source: CDN_BOTH,
  },
  {
    id: 'share-tech-mono',
    label: 'Share Tech Mono',
    stack: family('Share Tech Mono', MONO_FALLBACK),
    kind: 'mono',
    origin: 'project',
    license: 'OFL-1.1',
    source: CDN_BOTH,
  },
  {
    id: 'space-mono',
    label: 'Space Mono',
    stack: family('Space Mono', MONO_FALLBACK),
    kind: 'mono',
    origin: 'project',
    license: 'OFL-1.1',
    source: CDN_BOTH,
  },
]

export const DEFAULT_UI_FONT_ID = 'project'

export function getUIFontOption(id: string | null | undefined): UIFontOption | null {
  if (!id) return null
  return UI_FONT_OPTIONS.find((option) => option.id === id) ?? null
}

/** Pasos de la escala tipográfica (independiente de la escala de UI). */
export const UI_FONT_SCALE_STEPS: readonly number[] = [0.8, 0.9, 1, 1.1, 1.2, 1.3]

export const UI_FONT_SCALE_MIN = 0.8
export const UI_FONT_SCALE_MAX = 1.3
export const UI_FONT_SCALE_STEP = 0.05

/** Pasos de la escala de UI (espaciado y cajas; no altera la tipografía). */
export const UI_UI_SCALE_MIN = 0.8
export const UI_UI_SCALE_MAX = 1.3
export const UI_UI_SCALE_STEP = 0.05

