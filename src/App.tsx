import { useEffect, useState } from 'react'
import './App.css'
import './styles/fonts.css'

type FontRole = 'title' | 'heading' | 'body' | 'number' | 'button'

type FontSettings = Record<FontRole, string>

const fonts: Record<FontRole, string[]> = {
  title: [
    'Orbitron',
    'Audiowide',
    'Michroma',
    'Oxanium',
  ],

  heading: [
    'Rajdhani',
    'Oxanium',
    'Exo 2',
    'Space Grotesk',
  ],

  body: [
    'Exo 2',
    'Inter',
    'Space Grotesk',
    'Rajdhani',
  ],

  number: [
    'Share Tech Mono',
    'JetBrains Mono',
    'Orbitron',
  ],

  button: [
    'Oxanium',
    'Rajdhani',
    'Orbitron',
    'Exo 2',
  ],
}

const presets: Record<string, FontSettings> = {
  Deuteria: {
    title: 'Orbitron',
    heading: 'Rajdhani',
    body: 'Exo 2',
    number: 'Share Tech Mono',
    button: 'Oxanium',
  },

  Militar: {
    title: 'Michroma',
    heading: 'Oxanium',
    body: 'Exo 2',
    number: 'Share Tech Mono',
    button: 'Rajdhani',
  },

  'Sci-Fi moderno': {
    title: 'Audiowide',
    heading: 'Space Grotesk',
    body: 'Inter',
    number: 'JetBrains Mono',
    button: 'Oxanium',
  },
}

const defaultFonts: FontSettings = {
  ...presets.Deuteria,
}

/**
 * Aplica las fuentes directamente al documento.
 *
 * Usamos !important para evitar que alguna regla
 * posterior de App.css o fonts.css sobrescriba
 * accidentalmente las fuentes seleccionadas.
 */
function applyFonts(settings: FontSettings) {
  const root = document.documentElement

  root.style.setProperty(
    '--font-title',
    `"${settings.title}", sans-serif`,
  )

  root.style.setProperty(
    '--font-heading',
    `"${settings.heading}", sans-serif`,
  )

  root.style.setProperty(
    '--font-body',
    `"${settings.body}", sans-serif`,
  )

  root.style.setProperty(
    '--font-number',
    `"${settings.number}", monospace`,
  )

  root.style.setProperty(
    '--font-button',
    `"${settings.button}", sans-serif`,
  )

  /*
   * También dejamos atributos en el HTML.
   * Esto permite inspeccionar fácilmente desde el navegador
   * qué fuentes están actualmente activas.
   */
  root.dataset.fontTitle = settings.title
  root.dataset.fontHeading = settings.heading
  root.dataset.fontBody = settings.body
  root.dataset.fontNumber = settings.number
  root.dataset.fontButton = settings.button
}

/**
 * Fuerza al navegador a cargar la fuente seleccionada.
 *
 * Esto es importante porque cambiar solamente
 * font-family no garantiza que la fuente remota
 * haya terminado de descargarse.
 */
async function preloadFont(font: string) {
  try {
    if ('fonts' in document) {
      await document.fonts.load(`16px "${font}"`)
    }
  } catch {
    // Si la fuente falla, el navegador utilizará el fallback.
  }
}

async function preloadAllFonts(settings: FontSettings) {
  const uniqueFonts = Array.from(
    new Set(Object.values(settings)),
  )

  await Promise.all(
    uniqueFonts.map((font) => preloadFont(font)),
  )
}

function loadSavedFonts(): FontSettings {
  try {
    const saved = localStorage.getItem(
      'lagranimplosion-fonts',
    )

    if (!saved) {
      return { ...defaultFonts }
    }

    const parsed: Partial<FontSettings> =
      JSON.parse(saved)

    return {
      title:
        typeof parsed.title === 'string' &&
        fonts.title.includes(parsed.title)
          ? parsed.title
          : defaultFonts.title,

      heading:
        typeof parsed.heading === 'string' &&
        fonts.heading.includes(parsed.heading)
          ? parsed.heading
          : defaultFonts.heading,

      body:
        typeof parsed.body === 'string' &&
        fonts.body.includes(parsed.body)
          ? parsed.body
          : defaultFonts.body,

      number:
        typeof parsed.number === 'string' &&
        fonts.number.includes(parsed.number)
          ? parsed.number
          : defaultFonts.number,

      button:
        typeof parsed.button === 'string' &&
        fonts.button.includes(parsed.button)
          ? parsed.button
          : defaultFonts.button,
    }
  } catch {
    return { ...defaultFonts }
  }
}

function FontSelector({
  role,
  label,
  value,
  onChange,
}: {
  role: FontRole
  label: string
  value: string
  onChange: (value: string) => void
}) {
  return (
    <label className="font-control">
      <span>{label}</span>

      <select
        value={value}
        onChange={(event) =>
          onChange(event.target.value)
        }
      >
        {fonts[role].map((font) => (
          <option
            key={font}
            value={font}
          >
            {font}
          </option>
        ))}
      </select>

      <strong
        className="font-preview"
        style={{
          fontFamily: `"${value}", sans-serif`,
        }}
      >
        {value}
      </strong>
    </label>
  )
}

function App() {
  const [fontSettings, setFontSettings] =
    useState<FontSettings>(loadSavedFonts)

  const [panelOpen, setPanelOpen] =
    useState(false)

  /*
   * Aplicamos inmediatamente las fuentes.
   */
  useEffect(() => {
    applyFonts(fontSettings)

    localStorage.setItem(
      'lagranimplosion-fonts',
      JSON.stringify(fontSettings),
    )

    void preloadAllFonts(fontSettings)
  }, [fontSettings])

  /*
   * Carga inicial de las fuentes antes de que el usuario
   * empiece a cambiar configuraciones.
   */
  useEffect(() => {
    void preloadAllFonts(fontSettings)
  }, [])

  function changeFont(
    role: FontRole,
    value: string,
  ) {
    setFontSettings((current) => ({
      ...current,
      [role]: value,
    }))
  }

  function applyPreset(name: string) {
    const preset = presets[name]

    if (!preset) {
      return
    }

    setFontSettings({
      ...preset,
    })
  }

  function resetFonts() {
    const restored = {
      ...defaultFonts,
    }

    setFontSettings(restored)

    localStorage.removeItem(
      'lagranimplosion-fonts',
    )

    applyFonts(restored)
  }

  return (
    <main className="game">

      <header className="topbar">

        <div className="logo">

          <span>
            LA GRAN
          </span>

          <strong>
            IMPLOSIÓN
          </strong>

        </div>

        <div className="top-resources">

          <div className="resource">
            <span>METAL</span>

            <strong className="number">
              100.000
            </strong>
          </div>

          <div className="resource">
            <span>CRISTAL</span>

            <strong className="number">
              86.719
            </strong>
          </div>

          <div className="resource">
            <span>DEUTERIO</span>

            <strong className="number">
              90.518
            </strong>
          </div>

          <div className="resource">
            <span>ENERGÍA</span>

            <strong className="number">
              0
            </strong>
          </div>

        </div>

        <button
          className="settings-button"
          onClick={() =>
            setPanelOpen((current) => !current)
          }
          aria-label="Abrir configuración"
        >
          ⚙
        </button>

      </header>

      <div className="layout">

        <aside className="sidebar">

          <div className="player-card">

            <div className="player-avatar">
              👤
            </div>

            <div>

              <small>
                INVITADO
              </small>

              <strong>
                DevPlayer
              </strong>

            </div>

          </div>

          <nav>

            <button className="nav-button active">
              OVERVIEW
            </button>

            <button className="nav-button">
              PLANETAS
            </button>

            <button className="nav-button">
              FLOTA
            </button>

            <button className="nav-button">
              INVESTIGACIÓN
            </button>

            <button className="nav-button">
              CONSTRUCCIÓN
            </button>

            <button className="nav-button">
              GALAXIA
            </button>

          </nav>

        </aside>

        <section className="content">

          <div className="hero">

            <div>

              <span className="eyebrow">
                SISTEMA 1 · IMPERIO
              </span>

              <h1>
                DEV HOMEWORLD
              </h1>

              <p>
                [1:1:1] · Planeta principal
              </p>

            </div>

            <div className="planet-status">
              ONLINE
            </div>

          </div>

          <div className="dashboard-grid">

            <article className="panel">

              <div className="panel-header">

                <span>
                  RECURSOS
                </span>

                <small>
                  PRODUCCIÓN
                </small>

              </div>

              <div className="resource-row">

                <span>
                  🪨 Metal
                </span>

                <strong className="number">
                  100.000
                </strong>

              </div>

              <div className="resource-row">

                <span>
                  💎 Cristal
                </span>

                <strong className="number">
                  86.719
                </strong>

              </div>

              <div className="resource-row">

                <span>
                  💧 Deuterio
                </span>

                <strong className="number">
                  90.518
                </strong>

              </div>

              <div className="resource-row">

                <span>
                  ⚡ Energía
                </span>

                <strong className="number">
                  0
                </strong>

              </div>

            </article>

            <article className="panel">

              <div className="panel-header">

                <span>
                  PLANETAS
                </span>

                <small>
                  3 COLONIAS
                </small>

              </div>

              <div className="planet-row">

                <span>
                  🌍 Dev Homeworld
                </span>

                <small>
                  [1:1:1]
                </small>

              </div>

              <div className="planet-row">

                <span>
                  🌍 TEST FLEET TARGET
                </span>

                <small>
                  [1:2:1]
                </small>

              </div>

              <div className="planet-row">

                <span>
                  🌍 Colony 1:2:2
                </span>

                <small>
                  [1:2:2]
                </small>

              </div>

            </article>

            <article className="panel wide">

              <div className="panel-header">

                <span>
                  SISTEMA
                </span>

                <small>
                  ACTIVIDAD
                </small>

              </div>

              <div className="system-message">

                <span className="pulse" />

                <div>

                  <strong>
                    Sistema operativo
                  </strong>

                  <p>
                    La infraestructura de La Gran
                    Implosión está funcionando
                    correctamente.
                  </p>

                </div>

              </div>

              <button className="action-button">
                ABRIR CENTRO DE CONTROL
              </button>

            </article>

          </div>

        </section>

      </div>

      {panelOpen && (

        <aside className="style-panel">

          <div className="style-header">

            <div>

              <span>
                CONFIGURACIÓN
              </span>

              <h2>
                APARIENCIA
              </h2>

            </div>

            <button
              className="close-button"
              onClick={() =>
                setPanelOpen(false)
              }
              aria-label="Cerrar configuración"
            >
              ×
            </button>

          </div>

          <section className="style-section">

            <span className="section-title">
              PRESETS
            </span>

            <div className="preset-grid">

              {Object.keys(presets).map(
                (preset) => (

                  <button
                    key={preset}
                    className="preset-button"
                    onClick={() =>
                      applyPreset(preset)
                    }
                  >
                    {preset}
                  </button>

                ),
              )}

            </div>

          </section>

          <section className="style-section">

            <span className="section-title">
              TIPOGRAFÍA
            </span>

            <FontSelector
              role="title"
              label="Títulos"
              value={fontSettings.title}
              onChange={(value) =>
                changeFont(
                  'title',
                  value,
                )
              }
            />

            <FontSelector
              role="heading"
              label="Encabezados"
              value={fontSettings.heading}
              onChange={(value) =>
                changeFont(
                  'heading',
                  value,
                )
              }
            />

            <FontSelector
              role="body"
              label="Texto"
              value={fontSettings.body}
              onChange={(value) =>
                changeFont(
                  'body',
                  value,
                )
              }
            />

            <FontSelector
              role="number"
              label="Números"
              value={fontSettings.number}
              onChange={(value) =>
                changeFont(
                  'number',
                  value,
                )
              }
            />

            <FontSelector
              role="button"
              label="Botones"
              value={fontSettings.button}
              onChange={(value) =>
                changeFont(
                  'button',
                  value,
                )
              }
            />

          </section>

          <section className="style-preview">

            <span className="section-title">
              VISTA PREVIA
            </span>

            <div className="preview-title">
              LA GRAN IMPLOSIÓN
            </div>

            <div className="preview-heading">
              CENTRO DE CONTROL
            </div>

            <div className="preview-body">
              Flota preparada para operaciones.
            </div>

            <div className="preview-number">
              1.234.567.890
            </div>

            <button className="preview-button">
              INICIAR OPERACIÓN
            </button>

          </section>

          <button
            className="reset-button"
            onClick={resetFonts}
          >
            RESTAURAR PREDETERMINADO
          </button>

        </aside>

      )}

    </main>
  )
}

export default App