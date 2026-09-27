/*
  GENERADOR DE ASSETS DE REFERENCIA (DEV)

  Crea placeholders SVG LOCALES para comprobar cómo encajan imagen + nombre +
  nivel + estado en los grids del UI Engine (edificios, investigación, hangar,
  defensa, recursos, flota, planetas, galaxia).

  DECISIONES DE PROPIEDAD INTELECTUAL:

    * Este script NO descarga ni copia ningún asset de terceros. Todo lo que
      escribe es geometría generada aquí (rectángulos, círculos, texto) a partir
      de este archivo, así que se puede versionar sin arrastrar licencias
      ajenas.
    * Los assets de referencia visual de terceros (por ejemplo los de OGameX:
      su código es MIT, pero su README declara que los derechos del arte y del
      frontend pertenecen a GameForge GmbH) NO se incorporan al repositorio. Esa
      investigación se documenta en
      `src/ui-engine/assets/reference/README.md`.
    * El resultado se marca explícitamente como REFERENCE / PLACEHOLDER dentro
      del propio SVG: nunca se puede confundir con arte definitivo.

  Uso:  node scripts/generate-reference-assets.mjs
*/

import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const outputRoot = resolve(here, '..', 'src', 'ui-engine', 'assets', 'reference')

const palette = {
  bg: '#0a0f18',
  grid: 'rgba(126, 180, 255, 0.10)',
  frame: 'rgba(126, 180, 255, 0.38)',
  ink: '#7fb8ff',
  accent: '#35d0ff',
  warn: '#ffd75e',
  label: '#5c6f88',
}

/** Glifos: formas simples y legibles a tamaño de tarjeta. */
const glyphs = {
  factory: `
    <rect x="44" y="50" width="72" height="28" fill="none" stroke="${palette.ink}" stroke-width="3"/>
    <rect x="52" y="36" width="14" height="14" fill="none" stroke="${palette.accent}" stroke-width="3"/>
    <rect x="76" y="28" width="14" height="22" fill="none" stroke="${palette.accent}" stroke-width="3"/>`,
  lab: `
    <path d="M70 32 L90 32 L90 50 L104 78 L56 78 L70 50 Z" fill="none" stroke="${palette.ink}" stroke-width="3"/>
    <path d="M62 66 L98 66" stroke="${palette.accent}" stroke-width="3"/>`,
  ship: `
    <path d="M40 68 L80 34 L120 68 L80 60 Z" fill="none" stroke="${palette.ink}" stroke-width="3"/>
    <path d="M80 60 L80 78" stroke="${palette.accent}" stroke-width="3"/>`,
  shield: `
    <path d="M80 30 L112 44 L112 62 C112 74 96 82 80 88 C64 82 48 74 48 62 L48 44 Z" fill="none" stroke="${palette.ink}" stroke-width="3"/>
    <path d="M66 60 L76 70 L96 48" fill="none" stroke="${palette.accent}" stroke-width="3"/>`,
  resource: `
    <path d="M80 28 L112 58 L80 90 L48 58 Z" fill="none" stroke="${palette.ink}" stroke-width="3"/>
    <path d="M48 58 L112 58" stroke="${palette.accent}" stroke-width="3"/>`,
  fleet: `
    <path d="M34 60 L108 60" stroke="${palette.ink}" stroke-width="3"/>
    <path d="M96 48 L118 60 L96 72 Z" fill="none" stroke="${palette.accent}" stroke-width="3"/>
    <path d="M40 48 L40 72" stroke="${palette.ink}" stroke-width="3"/>`,
  planet: `
    <circle cx="80" cy="58" r="24" fill="none" stroke="${palette.ink}" stroke-width="3"/>
    <ellipse cx="80" cy="58" rx="42" ry="12" fill="none" stroke="${palette.accent}" stroke-width="2"/>`,
  galaxy: `
    <circle cx="80" cy="58" r="6" fill="${palette.accent}"/>
    <circle cx="46" cy="42" r="3" fill="${palette.ink}"/>
    <circle cx="114" cy="74" r="3" fill="${palette.ink}"/>
    <circle cx="60" cy="82" r="3" fill="${palette.ink}"/>
    <circle cx="110" cy="40" r="3" fill="${palette.ink}"/>`,
  message: `
    <rect x="42" y="38" width="76" height="44" fill="none" stroke="${palette.ink}" stroke-width="3"/>
    <path d="M42 38 L80 64 L118 38" fill="none" stroke="${palette.accent}" stroke-width="3"/>`,
}


/** Catálogo: dominio → glyph + entradas `[id, label]`. */
const catalog = {
  buildings: {
    glyph: 'factory',
    entries: [
      ['metal-mine', 'Metal mine'],
      ['crystal-mine', 'Crystal mine'],
      ['deuterium-synthesizer', 'Deuterium synthesizer'],
      ['solar-plant', 'Solar plant'],
      ['fusion-reactor', 'Fusion reactor'],
      ['robotics-factory', 'Robotics factory'],
      ['shipyard', 'Shipyard'],
      ['research-lab', 'Research lab'],
      ['metal-storage', 'Metal storage'],
      ['crystal-storage', 'Crystal storage'],
      ['deuterium-tank', 'Deuterium tank'],
      ['nanite-factory', 'Nanite factory'],
    ],
  },
  research: {
    glyph: 'lab',
    entries: [
      ['energy-technology', 'Energy technology'],
      ['combustion-drive', 'Combustion drive'],
      ['impulse-drive', 'Impulse drive'],
      ['hyperspace-drive', 'Hyperspace drive'],
      ['espionage-technology', 'Espionage technology'],
      ['computer-technology', 'Computer technology'],
      ['weapons-technology', 'Weapons technology'],
      ['shielding-technology', 'Shielding technology'],
      ['armour-technology', 'Armour technology'],
      ['laser-technology', 'Laser technology'],
      ['astrophysics', 'Astrophysics'],
    ],
  },
  shipyard: {
    glyph: 'ship',
    entries: [
      ['small-cargo', 'Small cargo'],
      ['large-cargo', 'Large cargo'],
      ['light-fighter', 'Light fighter'],
      ['heavy-fighter', 'Heavy fighter'],
      ['cruiser', 'Cruiser'],
      ['battleship', 'Battleship'],
      ['colony-ship', 'Colony ship'],
      ['recycler', 'Recycler'],
      ['espionage-probe', 'Espionage probe'],
      ['solar-satellite', 'Solar satellite'],
    ],
  },
  defense: {
    glyph: 'shield',
    entries: [
      ['rocket-launcher', 'Rocket launcher'],
      ['light-laser', 'Light laser'],
      ['heavy-laser', 'Heavy laser'],
      ['gauss-cannon', 'Gauss cannon'],
      ['ion-cannon', 'Ion cannon'],
      ['plasma-turret', 'Plasma turret'],
      ['small-shield-dome', 'Small shield dome'],
      ['large-shield-dome', 'Large shield dome'],
    ],
  },
  resources: {
    glyph: 'resource',
    entries: [
      ['metal', 'Metal'],
      ['crystal', 'Crystal'],
      ['deuterium', 'Deuterium'],
      ['energy', 'Energy'],
      ['storage', 'Storage'],
    ],
  },
  fleet: {
    glyph: 'fleet',
    entries: [
      ['expedition', 'Expedition'],
      ['recycle', 'Recycle'],
      ['colonize', 'Colonize'],
      ['transport', 'Transport'],
      ['attack', 'Attack'],
      ['hold', 'Hold'],
    ],
  },
  planets: {
    glyph: 'planet',
    entries: [
      ['homeworld', 'Homeworld'],
      ['colony', 'Colony'],
      ['moon', 'Moon'],
      ['debris-field', 'Debris field'],
    ],
  },
  galaxy: {
    glyph: 'galaxy',
    entries: [
      ['system-view', 'System view'],
      ['position-empty', 'Empty position'],
      ['position-occupied', 'Occupied position'],
      ['position-moon', 'Position with moon'],
    ],
  },
  messages: {
    glyph: 'message',
    entries: [
      ['queue-event', 'Queue event'],
      ['combat-report', 'Combat report'],
      ['espionage-report', 'Espionage report'],
      ['expedition-report', 'Expedition report'],
      ['system-notice', 'System notice'],
    ],
  },
}

function renderAsset({ label, domain, id, glyph }) {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 120" width="160" height="120" role="img" aria-label="REFERENCE PLACEHOLDER — ${label} (${domain})">
  <title>REFERENCE PLACEHOLDER — ${label}</title>
  <desc>Placeholder generado por scripts/generate-reference-assets.mjs. No es arte definitivo ni material de terceros.</desc>
  <defs>
    <pattern id="lgi-grid-${domain}-${id}" width="10" height="10" patternUnits="userSpaceOnUse">
      <path d="M0 10 L10 0" stroke="${palette.grid}" stroke-width="1"/>
    </pattern>
  </defs>
  <rect width="160" height="120" fill="${palette.bg}"/>
  <rect width="160" height="120" fill="url(#lgi-grid-${domain}-${id})"/>
  <rect x="0.5" y="0.5" width="159" height="119" fill="none" stroke="${palette.frame}" stroke-width="1" stroke-dasharray="5 4"/>
  <text x="8" y="16" font-family="monospace" font-size="7" letter-spacing="1" fill="${palette.accent}">REFERENCE</text>
  <text x="8" y="26" font-family="monospace" font-size="7" letter-spacing="1" fill="${palette.warn}">PLACEHOLDER</text>
  ${glyphs[glyph].trim()}
  <text x="8" y="103" font-family="monospace" font-size="8" fill="${palette.ink}">${label.toUpperCase()}</text>
  <text x="8" y="114" font-family="monospace" font-size="7" fill="${palette.label}">${domain}.${id}</text>
</svg>
`
}

let written = 0
for (const [domain, definition] of Object.entries(catalog)) {
  const directory = join(outputRoot, domain)
  mkdirSync(directory, { recursive: true })
  for (const [id, label] of definition.entries) {
    writeFileSync(
      join(directory, `${id}.svg`),
      renderAsset({ label, domain, id, glyph: definition.glyph }),
      'utf8',
    )
    written += 1
  }
}

console.log(`LGI reference assets: ${written} placeholders escritos en ${outputRoot}`)
