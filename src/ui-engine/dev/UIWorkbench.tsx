import { useState } from 'react'
import type { CSSProperties } from 'react'
import { UIEngine } from '../UIEngine'
import { UIDesigner } from '../designer/UIDesigner'
import { getUIDeviceProfile } from '../designer/deviceProfiles'
import { useUIDesignerConfig } from '../designer/designerStore'
import { UI_REFERENCE_DECKS } from '../reference/referenceData'
import { UIAllReferenceDecksScreen, UIReferenceDeckScreen } from '../reference/ReferenceGrids'
import './workbench.css'

/*
  UI ENGINE — BANCO DE PRUEBAS (DEV)

  Superficie de previsualización que monta el MISMO engine y el MISMO Designer
  que la aplicación, sin sesión y sin tocar gameplay:

      EngineProvider → UIWorkbench → UIEngine → grids de referencia
                                        ↑
                                  UIDesigner (panel DEV)

  Se activa con el hash `#ui-designer` (ver `dev/workbenchEntry.ts`) y se puede
  alternar sin recargar. Sirve para decidir la capa visual (composición,
  tipografía, densidades, breakpoints) antes de que existan las pantallas
  definitivas de edificios, investigación, hangar, defensa, recursos, flota,
  galaxia e informes.
*/

export function UIWorkbench() {
  const config = useUIDesignerConfig()
  const device = getUIDeviceProfile(config.deviceProfile)
  const [deckId, setDeckId] = useState<string>(UI_REFERENCE_DECKS[0].id)
  const screenId = deckId === 'all' ? 'all' : deckId

  const frameStyle = {
    '--lgi-device-width': device.width > 0 ? `${device.width}px` : '100%',
    '--lgi-device-height': device.height > 0 ? `${device.height}px` : '0px',
  } as CSSProperties

  return (
    <div className="lgi-workbench">
      <header className="lgi-workbench__bar">
        <div className="lgi-workbench__title">
          <strong>LGI UI ENGINE · BANCO DE PRUEBAS</strong>
          <span>
            Assets de referencia + composición de templates. Sin sesión, sin Supabase y sin
            lógica de juego: sólo presentación.
          </span>
        </div>

        <div className="lgi-workbench__decks" role="group" aria-label="Deck de referencia">
          {UI_REFERENCE_DECKS.map((deck) => (
            <button
              key={deck.id}
              type="button"
              className={`lgi-workbench__deck${deckId === deck.id ? ' active' : ''}`}
              aria-pressed={deckId === deck.id}
              onClick={() => setDeckId(deck.id)}
            >
              {deck.label}
            </button>
          ))}
          <button
            type="button"
            className={`lgi-workbench__deck${deckId === 'all' ? ' active' : ''}`}
            aria-pressed={deckId === 'all'}
            onClick={() => setDeckId('all')}
          >
            ALL
          </button>
        </div>

        <p className="lgi-workbench__meta">
          <b>deck</b> {screenId} · <b>device</b> {device.label}
          {device.width > 0 ? ` (${device.width}px)` : ' (ancho real)'} · <b>template</b>{' '}
          {config.template} · <b>font</b> {config.fontId} · <b>font scale</b>{' '}
          {Math.round(config.fontScale * 100)}% · <b>ui scale</b> {Math.round(config.uiScale * 100)}
          %
        </p>

        <div className="lgi-workbench__decks">
          <button
            type="button"
            className="lgi-workbench__deck"
            onClick={() => {
              window.location.hash = ''
            }}
          >
            VOLVER AL JUEGO
          </button>
        </div>
      </header>

      <div className="lgi-workbench__stage">
        <div
          className={`lgi-device-frame${device.width > 0 ? '' : ' lgi-device-frame--native'}`}
          data-lgi-device={device.id}
          style={frameStyle}
        >
          {device.family === 'mobile' && <span className="lgi-device-frame__notch" aria-hidden="true" />}
          <div className="lgi-device-frame__screen">
            <UIEngine>
              {deckId === 'all' ? <UIAllReferenceDecksScreen /> : <UIReferenceDeckScreen deckId={deckId} />}
            </UIEngine>
            {device.family === 'mobile' && (
              <nav className="lgi-device-frame__nav" aria-label="Ejemplo de navegación inferior (no interactiva)">
                <span>PERFIL</span>
                <span>EDIFICIOS</span>
                <b>FLOTA</b>
                <span>GALAXIA</span>
                <span>MÁS</span>
              </nav>
            )}
          </div>
        </div>
      </div>

      <UIDesigner />
    </div>
  )
}
