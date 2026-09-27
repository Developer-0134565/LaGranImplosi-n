import type { ReactNode } from 'react'
import { UIEngineScreen } from '../UIEngineScreen'
import { CardGrid } from '../components/CardGrid'
import { Panel } from '../components/Panel'
import { Pill } from '../components/ActionBar'
import type { UIModuleMap } from '../types'
import {
  ASSET_ORIGIN_LABEL,
  MISSING_REFERENCE_ASSET,
  getUIReferenceAsset,
} from './referenceAssets'
import {
  UI_REFERENCE_DECKS,
  getUIReferenceDeck,
  type UIReferenceDeck,
  type UIReferenceItem,
} from './referenceData'

/*
  UI ENGINE — GRIDS DE REFERENCIA (DEV)

  Estos grids existen para comprobar cómo encajan los assets y la composición
  ANTES de que exista gameplay de esos dominios:

      BUILDINGS · RESEARCH · SHIPYARD · DEFENSE · RESOURCES · FLEET · PLANETS ·
      GALAXY · MESSAGES

  Es presentación pura sobre el UI Engine: no consultan Supabase, no escriben
  nada y no definen reglas. Cada deck es un módulo del registry con id
  `dominio.nombre`, así que cualquier template puede colocarlo donde quiera.
*/

const numberFormat = new Intl.NumberFormat('es-ES', { maximumFractionDigits: 0 })

/** Tarjeta de asset de referencia: imagen + nombre + nivel/unidades + estado. */
export function ReferenceAssetCard({ item }: { item: UIReferenceItem }) {
  const asset = getUIReferenceAsset(item.assetId) ?? MISSING_REFERENCE_ASSET
  const metric =
    item.level !== undefined
      ? `NIVEL ${item.level}`
      : item.quantity !== undefined
        ? numberFormat.format(item.quantity)
        : ''

  return (
    <article className="lgi-ref-card" data-asset={asset.id} data-exists={asset.src ? 'yes' : 'no'}>
      <div className="lgi-ref-card__media">
        {asset.src ? (
          <img className="lgi-ref-card__img" src={asset.src} alt="" loading="lazy" decoding="async" />
        ) : (
          <span className="lgi-ref-card__state">SIN ASSET</span>
        )}
        <span className="lgi-ref-card__tag">{ASSET_ORIGIN_LABEL[asset.origin]}</span>
      </div>
      <div className="lgi-ref-card__head">
        <h3 className="lgi-ref-card__title">{item.label}</h3>
        <span className="lgi-ref-card__level">{metric}</span>
      </div>
      <div className="lgi-ref-card__foot">
        <span className="lgi-ref-card__state">{item.detail}</span>
        <Pill tone={item.tone}>{item.status}</Pill>
      </div>
    </article>
  )
}

/** Grid adaptativo de un deck (mismo componente para los nueve dominios). */
export function ReferenceGrid({ deck, minCard = 190 }: { deck: UIReferenceDeck; minCard?: number }) {
  return (
    <>
      <p className="lgi-ref-note">
        <b>REFERENCE DATA</b> · {deck.note}
      </p>
      <CardGrid minCard={minCard}>
        {deck.items.map((item) => (
          <ReferenceAssetCard key={item.assetId} item={item} />
        ))}
      </CardGrid>
      <p className="lgi-ref-note">
        Los assets son placeholders generados por el propio repositorio
        (<b>scripts/generate-reference-assets.mjs</b>); no contienen material de terceros. El
        arte definitivo se sustituye archivo a archivo y se declara en
        <b> assets/reference/README.md</b>.
      </p>
    </>
  )
}

export function ReferenceDeckPanel({ deck }: { deck: UIReferenceDeck }) {
  return (
    <Panel title={deck.title} meta={`${deck.items.length} · ${deck.metric}`}>
      <ReferenceGrid deck={deck} />
    </Panel>
  )
}

/* ============================================================================
   PANTALLAS DEV — un deck, o todos los dominios a la vez
   ========================================================================= */

/** Pantalla DEV de un deck: compone sus módulos en el template activo. */
export function UIReferenceDeckScreen({ deckId, className }: { deckId: string; className?: string }) {
  const deck = getUIReferenceDeck(deckId)
  const modules: Record<string, ReactNode> = {
    [deck.moduleId]: <ReferenceDeckPanel deck={deck} />,
  }
  return (
    <UIEngineScreen
      id={`reference-${deck.id}`}
      className={className}
      modules={modules as UIModuleMap}
    />
  )
}

/**
 * Pantalla DEV "ALL": todos los dominios de referencia a la vez, para ver cómo
 * reparte cada template nueve módulos distintos sin tocar sus plantillas.
 */
export function UIAllReferenceDecksScreen({ className }: { className?: string }) {
  const modules: Record<string, ReactNode> = {}
  for (const deck of UI_REFERENCE_DECKS) {
    modules[deck.moduleId] = <ReferenceDeckPanel deck={deck} />
  }
  return <UIEngineScreen id="reference-all" className={className} modules={modules as UIModuleMap} />
}
