/*
  UI ENGINE — REGISTRO DE ASSETS DE REFERENCIA

  Los assets de `src/ui-engine/assets/reference/**` se descubren solos: basta con
  añadir un SVG a la carpeta del dominio y queda registrado como
  `<dominio>.<nombre-de-archivo>`. No hay ninguna lista que mantener a mano, así
  que añadir un dominio visual nuevo no obliga a tocar el engine.

  PROCEDENCIA: los assets incluidos son placeholders generados por
  `scripts/generate-reference-assets.mjs` (geometría propia, sin material de
  terceros). El campo `provenance` viaja con cada asset y se muestra en la
  propia tarjeta: si en el futuro se incorpora arte definitivo o licenciado,
  tiene que declararse aquí. Ver `assets/reference/README.md`.
*/

export type UIAssetOrigin = 'generated-placeholder' | 'project' | 'licensed-third-party'

export type UIAssetProvenance = {
  /** De dónde sale el archivo. */
  source: string
  /** Licencia o estado legal del archivo. */
  license: string
  /** Para qué se puede usar HOY. */
  intendedUse: string
  /** true ⇒ hay que sustituirlo antes de publicar. */
  replaceRequired: boolean
}

export type UIAssetDefinition = {
  /** `dominio.nombre` (mismo formato que los ids de módulo). */
  id: string
  domain: string
  /** Slug del archivo (`metal-mine`). */
  name: string
  /** Etiqueta legible derivada del slug (`Metal Mine`). */
  label: string
  /** URL del asset (Vite lo resuelve en build). */
  src: string
  origin: UIAssetOrigin
  provenance: UIAssetProvenance
}

const PLACEHOLDER_PROVENANCE: UIAssetProvenance = {
  source: 'scripts/generate-reference-assets.mjs (geometría generada en este repositorio)',
  license: 'Interno del proyecto — sin material de terceros',
  intendedUse: 'Prueba de composición en el UI Designer y en los grids DEV',
  replaceRequired: true,
}

/** Etiqueta visual del origen de un asset (se muestra en la propia tarjeta). */
export const ASSET_ORIGIN_LABEL: Record<UIAssetOrigin, string> = {
  'generated-placeholder': 'REFERENCE',
  project: 'PROYECTO',
  'licensed-third-party': 'LICENCIA',
}

/** Assets ya existentes en el repositorio (carpeta `IMAGENES/`), no versionados aquí. */
export const LGI_LOCAL_IMAGE_CANDIDATES: readonly { file: string; note: string }[] = [
  {
    file: 'IMAGENES/minametal.jpg',
    note: 'Imagen del proyecto para mina de metal. Origen/licencia no documentados en el repositorio: no se ha copiado a los assets de referencia.',
  },
  {
    file: 'IMAGENES/mina cristal.jpg',
    note: 'Imagen del proyecto para mina de cristal. Origen/licencia no documentados: no copiada.',
  },
  {
    file: 'IMAGENES/sintetizadordeuterio.jpg',
    note: 'Imagen del proyecto para sintetizador de deuterio. Origen/licencia no documentados: no copiada.',
  },
]

const assetModules = import.meta.glob('../assets/reference/**/*.svg', {
  eager: true,
  query: '?url',
  import: 'default',
}) as Record<string, string>

function humanize(slug: string): string {
  return slug
    .split('-')
    .map((part) => (part.length > 0 ? part[0].toUpperCase() + part.slice(1) : part))
    .join(' ')
}

export const UI_REFERENCE_ASSETS: readonly UIAssetDefinition[] = Object.entries(assetModules)
  .map(([path, src]) => {
    const match = /reference\/([^/]+)\/([^/]+)\.svg$/.exec(path)
    const domain = match?.[1] ?? 'otros'
    const name = match?.[2] ?? path
    return {
      id: `${domain}.${name}`,
      domain,
      name,
      src,
      origin: 'generated-placeholder' as const,
      provenance: PLACEHOLDER_PROVENANCE,
    }
  })
  .map((asset) => ({ ...asset, label: humanize(asset.name) }))
  .sort((a, b) => a.id.localeCompare(b.id))

export function getUIReferenceAsset(id: string): UIAssetDefinition | null {
  return UI_REFERENCE_ASSETS.find((asset) => asset.id === id) ?? null
}

export function referenceAssetsOfDomain(domain: string): readonly UIAssetDefinition[] {
  return UI_REFERENCE_ASSETS.filter((asset) => asset.domain === domain)
}

/** Nunca se inventa un asset: si falta, el grid dibuja el hueco declarado. */
export const MISSING_REFERENCE_ASSET: UIAssetDefinition = {
  id: 'reference.missing',
  domain: 'reference',
  name: 'missing',
  label: 'ASSET NOT FOUND',
  src: '',
  origin: 'generated-placeholder',
  provenance: {
    source: '—',
    license: '—',
    intendedUse: 'Hueco declarado: el asset todavía no existe',
    replaceRequired: true,
  },
}
