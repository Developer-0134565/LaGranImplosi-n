/**
 * Emblemas de comandante.
 *
 * NOTA HONESTA SOBRE "IA": no se han generado imágenes con un modelo de IA. No
 * dispongo de esa capacidad. Lo que hay es un set **SVG procedural y
 * determinista**, con la misma logica del setting (espacio profundo,
 * órbitas, estrellas, reactores): en vez de rasterizar fotos, cada emblema es una
 * composición geométrica generada en código.
 *
 * Ventajas frente a un set de PNG generados: escala sin pérdida, pesa ~0 bytes de
 * red (se pinta en el DOM), se puede tematizar con los tokens del engine y un
 * emblema retirado no rompe nada (el servidor guarda una clave opaca).
 *
 * Si más adelante se quieren imágenes rasterizadas con IA, este mismo módulo es el
 * punto de sustitución: se cambia `renderAvatar()` y el resto no se toca.
 */

export type AvatarId = string

export interface AvatarDef {
  id: AvatarId
  /** Símbolo corto para mostrar en listas. */
  glyph: string
  /** Colores del emblema: [primario, secundario, acento]. */
  colors: readonly [string, string, string]
  /** Nombre legible; la UI lo muestra como etiqueta. */
  name: string
}

/**
 * `XX` es un valor centinela INTENCIONAL: no es un avatar, marca "sin elegir".
 * No debe usarse como `DEFAULT_AVATAR_ID`.
 */
export const NO_AVATAR: AvatarId = 'XX'

export const DEFAULT_AVATAR_ID: AvatarId = 'orbita'

export const AVATARS: readonly AvatarDef[] = [
  { id: 'orbita',      glyph: '◉', colors: ['#3fa9f5', '#0b3c63', '#8ef0ff'], name: 'Órbita' },
  { id: 'supernova',   glyph: '✷', colors: ['#ff8a3d', '#5a1a00', '#ffd9a0'], name: 'Supernova' },
  { id: 'lanzador',    glyph: '➤', colors: ['#8ef07a', '#123d0a', '#e6ffe0'], name: 'Lanzador' },
  { id: 'corona',      glyph: '♛', colors: ['#ffd45e', '#5c4200', '#fff6d6'], name: 'Corona' },
  { id: 'esfera',      glyph: '◍', colors: ['#b98cf5', '#2d0f52', '#eadcff'], name: 'Esfera' },
  { id: 'engranaje',   glyph: '⚙', colors: ['#c9d1d9', '#33393f', '#eef2f6'], name: 'Engranaje' },
  { id: 'ancla',       glyph: '⚓', colors: ['#f55f7a', '#4a0a1c', '#ffd6de'], name: 'Ancla' },
  { id: 'cometa',      glyph: '☄', colors: ['#7ce8ff', '#0a3d4a', '#dffaff'], name: 'Cometa' },
  { id: 'diamante',    glyph: '◈', colors: ['#6fe0c8', '#0a4038', '#d8fff7'], name: 'Diamante' },
  { id: 'rayo',        glyph: '⚡', colors: ['#ffe066', '#4a3b00', '#fffbd6'], name: 'Rayo' },
  { id: 'eclipse',     glyph: '◐', colors: ['#8f7ae8', '#1a1338', '#ded5ff'], name: 'Eclipse' },
  { id: 'estrella',    glyph: '★', colors: ['#ffd166', '#4a3500', '#fff2cc'], name: 'Estrella' },
] as const

/** Resuelve un id a su definición; si no existe, cae al default (nunca lanza). */
export function getAvatar(id: AvatarId | null | undefined): AvatarDef {
  if (!id || id === NO_AVATAR) return avatarById(DEFAULT_AVATAR_ID)
  return avatarById(id)
}

function avatarById(id: AvatarId): AvatarDef {
  return AVATARS.find((a) => a.id === id) ?? AVATARS[0]
}

/**
 * Dibuja el emblema. `size` en px. Es SVG inline: sin peticiones de red.
 */
export function renderAvatar(id: AvatarId | null | undefined, size = 40): string {
  const a = getAvatar(id)
  const [c1, c2, c3] = a.colors
  const r = size / 2
  const stroke = Math.max(1, size * 0.06)
  return [
    `<svg viewBox="0 0 ${size} ${size}" width="${size}" height="${size}" role="img" aria-label="${a.name}">`,
    `<defs><radialGradient id="av-${a.id}"><stop offset="0%" stop-color="${c3}"/>`,
    `<stop offset="100%" stop-color="${c2}"/></radialGradient></defs>`,
    `<circle cx="${r}" cy="${r}" r="${r}" fill="url(#av-${a.id})" stroke="${c1}" stroke-width="${stroke}"/>`,
    `<circle cx="${r}" cy="${r}" r="${r * 0.62}" fill="none" stroke="${c3}" stroke-width="${stroke * 0.6}" opacity="0.75"/>`,
    `<text x="50%" y="50%" text-anchor="middle" dominant-baseline="central" `,
    `font-size="${size * 0.5}" fill="${c3}">${a.glyph}</text>`,
    `</svg>`,
  ].join('')
}