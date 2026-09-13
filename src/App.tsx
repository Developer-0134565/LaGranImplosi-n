import { useEffect, useMemo, useState } from 'react'
import type { CSSProperties } from 'react'
import './App.css'
import './styles/fonts.css'
import { supabase } from './lib/supabase'

type FontRole = 'title' | 'heading' | 'body' | 'number' | 'button'
type FontSettings = Record<FontRole, string>

type Planet = {
  id: string
  name: string
  galaxy: number
  system: number
  position: number
  is_homeworld: boolean
  is_destroyed: boolean
  planet_resources: Array<{
    metal: number | string
    crystal: number | string
    deuterium: number | string
    energy: number | string
  }>
}

const FONT_STORAGE_KEY = 'lagranimplosion-fonts'

const fonts: Record<FontRole, string[]> = {
  title: ['Orbitron', 'Audiowide', 'Michroma', 'Oxanium'],
  heading: ['Rajdhani', 'Oxanium', 'Exo 2', 'Space Grotesk'],
  body: ['Exo 2', 'Inter', 'Space Grotesk', 'Rajdhani'],
  number: ['Share Tech Mono', 'JetBrains Mono', 'Orbitron'],
  button: ['Oxanium', 'Rajdhani', 'Orbitron', 'Exo 2'],
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

const defaultFonts: FontSettings = { ...presets.Deuteria }
const allFonts = Array.from(new Set(Object.values(fonts).flat()))

function isValidFont(role: FontRole, value: unknown): value is string {
  return typeof value === 'string' && fonts[role].includes(value)
}

function sanitizeFontSettings(value: unknown): FontSettings {
  if (!value || typeof value !== 'object') return { ...defaultFonts }

  const parsed = value as Partial<FontSettings>

  return {
    title: isValidFont('title', parsed.title) ? parsed.title : defaultFonts.title,
    heading: isValidFont('heading', parsed.heading) ? parsed.heading : defaultFonts.heading,
    body: isValidFont('body', parsed.body) ? parsed.body : defaultFonts.body,
    number: isValidFont('number', parsed.number) ? parsed.number : defaultFonts.number,
    button: isValidFont('button', parsed.button) ? parsed.button : defaultFonts.button,
  }
}

function loadSavedFonts(): FontSettings {
  try {
    const saved = localStorage.getItem(FONT_STORAGE_KEY)
    return saved ? sanitizeFontSettings(JSON.parse(saved)) : { ...defaultFonts }
  } catch {
    return { ...defaultFonts }
  }
}

function saveFontSettings(settings: FontSettings) {
  try {
    localStorage.setItem(FONT_STORAGE_KEY, JSON.stringify(settings))
  } catch {
    // La aplicación sigue funcionando aunque el navegador bloquee el almacenamiento.
  }
}

function clearSavedFonts() {
  try {
    localStorage.removeItem(FONT_STORAGE_KEY)
  } catch {
    // No impedir el cambio visual si el almacenamiento no está disponible.
  }
}

function fontStack(font: string, fallback: string) {
  return `"${font}", ${fallback}`
}

function getFontVariables(settings: FontSettings): CSSProperties {
  return {
    '--font-title': fontStack(settings.title, 'sans-serif'),
    '--font-heading': fontStack(settings.heading, 'sans-serif'),
    '--font-body': fontStack(settings.body, 'sans-serif'),
    '--font-number': fontStack(settings.number, 'monospace'),
    '--font-button': fontStack(settings.button, 'sans-serif'),
  } as CSSProperties
}

function applyFonts(settings: FontSettings) {
  const variables = getFontVariables(settings) as Record<string, string>
  const targets: HTMLElement[] = [document.documentElement]
  const game = document.querySelector<HTMLElement>('.game')

  if (game) targets.push(game)

  targets.forEach((target) => {
    Object.entries(variables).forEach(([name, value]) => {
      target.style.setProperty(name, value)
    })
  })
}

async function preloadFont(font: string) {
  try {
    await Promise.all([
      document.fonts.load(`400 16px "${font}"`),
      document.fonts.load(`600 16px "${font}"`),
      document.fonts.load(`700 16px "${font}"`),
    ])
  } catch {
    // El fallback CSS sigue disponible si una fuente no carga.
  }
}

async function preloadAllFonts() {
  await document.fonts.ready
  await Promise.all(allFonts.map(preloadFont))
}

function formatNumber(value: number | string | undefined) {
  if (value === undefined) return '—'
  const number = Number(value)
  if (!Number.isFinite(number)) return '—'
  return new Intl.NumberFormat('es-ES', { maximumFractionDigits: 0 }).format(number)
}

function coordinates(planet: Pick<Planet, 'galaxy' | 'system' | 'position'>) {
  return `[${planet.galaxy}:${planet.system}:${planet.position}]`
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
      <select value={value} onChange={(event) => onChange(event.target.value)}>
        {fonts[role].map((font) => (
          <option key={font} value={font}>{font}</option>
        ))}
      </select>
      <strong className="font-preview" style={{ fontFamily: `"${value}", sans-serif` }}>
        {value}
      </strong>
    </label>
  )
}

function App() {
  const [fontSettings, setFontSettings] = useState<FontSettings>(() => loadSavedFonts())
  const [panelOpen, setPanelOpen] = useState(false)
  const [planets, setPlanets] = useState<Planet[]>([])
  const [gameDataLoading, setGameDataLoading] = useState(true)
  const [gameDataError, setGameDataError] = useState<string | null>(null)

  const fontVariables = useMemo(() => getFontVariables(fontSettings), [fontSettings])
  const homeworld = planets.find((planet) => planet.is_homeworld) ?? planets[0]
  const homeworldResources = homeworld?.planet_resources[0]

  useEffect(() => {
    const safeSettings = sanitizeFontSettings(fontSettings)
    applyFonts(safeSettings)
    saveFontSettings(safeSettings)
  }, [fontSettings])

  useEffect(() => {
    void preloadAllFonts()
  }, [])

  useEffect(() => {
    if (!panelOpen) return

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === 'Escape') setPanelOpen(false)
    }

    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [panelOpen])

  useEffect(() => {
    let active = true

    async function loadGameData() {
      setGameDataLoading(true)
      setGameDataError(null)

      const { data, error } = await supabase
        .from('planets')
        .select('id,name,galaxy,system,position,is_homeworld,is_destroyed,planet_resources(metal,crystal,deuterium,energy)')
        .eq('is_destroyed', false)
        .order('galaxy', { ascending: true })
        .order('system', { ascending: true })
        .order('position', { ascending: true })

      if (!active) return

      if (error) {
        setGameDataError('No se han podido cargar los datos del imperio.')
        setPlanets([])
      } else {
        setPlanets((data ?? []) as Planet[])
      }

      setGameDataLoading(false)
    }

    void loadGameData()

    return () => {
      active = false
    }
  }, [])

  function changeFont(role: FontRole, value: string) {
    if (!isValidFont(role, value)) return
    setFontSettings((current) => ({ ...current, [role]: value }))
  }

  function applyPreset(name: string) {
    const preset = presets[name]
    if (preset) setFontSettings({ ...preset })
  }

  function resetFonts() {
    setFontSettings({ ...defaultFonts })
    clearSavedFonts()
  }

  return (
    <main className="game" style={fontVariables}>
      <header className="topbar">
        <div className="logo">
          <span>LA GRAN</span>
          <strong>IMPLOSIÓN</strong>
        </div>
        <div className="top-resources">
          <div className="resource"><span>METAL</span><strong className="number">{formatNumber(homeworldResources?.metal)}</strong></div>
          <div className="resource"><span>CRISTAL</span><strong className="number">{formatNumber(homeworldResources?.crystal)}</strong></div>
          <div className="resource"><span>DEUTERIO</span><strong className="number">{formatNumber(homeworldResources?.deuterium)}</strong></div>
          <div className="resource"><span>ENERGÍA</span><strong className="number">{formatNumber(homeworldResources?.energy)}</strong></div>
        </div>
        <button type="button" className="settings-button" onClick={() => setPanelOpen((current) => !current)} aria-label={panelOpen ? 'Cerrar configuración' : 'Abrir configuración'} aria-expanded={panelOpen} aria-controls="appearance-panel">⚙</button>
      </header>

      <div className="layout">
        <aside className="sidebar">
          <div className="player-card">
            <div className="player-avatar">👤</div>
            <div><small>INVITADO</small><strong>DevPlayer</strong></div>
          </div>
          <nav>
            <button type="button" className="nav-button active">OVERVIEW</button>
            <button type="button" className="nav-button">PLANETAS</button>
            <button type="button" className="nav-button">FLOTA</button>
            <button type="button" className="nav-button">INVESTIGACIÓN</button>
            <button type="button" className="nav-button">CONSTRUCCIÓN</button>
            <button type="button" className="nav-button">GALAXIA</button>
          </nav>
        </aside>

        <section className="content">
          <div className="hero">
            <div><span className="eyebrow">{homeworld ? `SISTEMA ${homeworld.system} · IMPERIO` : 'SISTEMA · IMPERIO'}</span><h1>{homeworld?.name ?? 'DEV HOMEWORLD'}</h1><p>{homeworld ? `${coordinates(homeworld)} · ${homeworld.is_homeworld ? 'Planeta principal' : 'Planeta'}` : 'Cargando planeta principal…'}</p></div>
            <div className="planet-status">{gameDataLoading ? 'CARGANDO' : gameDataError ? 'ERROR' : 'ONLINE'}</div>
          </div>
          <div className="dashboard-grid">
            <article className="panel">
              <div className="panel-header"><span>RECURSOS</span><small>{homeworld ? 'PLANETA ACTUAL' : 'SIN DATOS'}</small></div>
              <div className="resource-row"><span>🪨 Metal</span><strong className="number">{formatNumber(homeworldResources?.metal)}</strong></div>
              <div className="resource-row"><span>💎 Cristal</span><strong className="number">{formatNumber(homeworldResources?.crystal)}</strong></div>
              <div className="resource-row"><span>💧 Deuterio</span><strong className="number">{formatNumber(homeworldResources?.deuterium)}</strong></div>
              <div className="resource-row"><span>⚡ Energía</span><strong className="number">{formatNumber(homeworldResources?.energy)}</strong></div>
              {gameDataError && <small>{gameDataError}</small>}
            </article>
            <article className="panel">
              <div className="panel-header"><span>PLANETAS</span><small>{planets.length} COLONIAS</small></div>
              {planets.map((planet) => (
                <div className="planet-row" key={planet.id}><span>🌍 {planet.name}</span><small>{coordinates(planet)}</small></div>
              ))}
              {!gameDataLoading && planets.length === 0 && <div className="planet-row"><span>No hay planetas visibles</span><small>—</small></div>}
            </article>
            <article className="panel wide">
              <div className="panel-header"><span>SISTEMA</span><small>ACTIVIDAD</small></div>
              <div className="system-message"><span className="pulse" /><div><strong>Sistema operativo</strong><p>La infraestructura de La Gran Implosión está funcionando correctamente.</p></div></div>
              <button type="button" className="action-button">ABRIR CENTRO DE CONTROL</button>
            </article>
          </div>
        </section>
      </div>

      {panelOpen && (
        <aside id="appearance-panel" className="style-panel" role="dialog" aria-modal="true" aria-label="Configuración de apariencia">
          <div className="style-header">
            <div><span>CONFIGURACIÓN</span><h2>APARIENCIA</h2></div>
            <button type="button" className="close-button" onClick={() => setPanelOpen(false)} aria-label="Cerrar configuración">×</button>
          </div>
          <section className="style-section">
            <span className="section-title">PRESETS</span>
            <div className="preset-grid">
              {Object.keys(presets).map((preset) => (
                <button type="button" key={preset} className="preset-button" onClick={() => applyPreset(preset)}>{preset}</button>
              ))}
            </div>
          </section>
          <section className="style-section">
            <span className="section-title">TIPOGRAFÍA</span>
            <FontSelector role="title" label="Títulos" value={fontSettings.title} onChange={(value) => changeFont('title', value)} />
            <FontSelector role="heading" label="Encabezados" value={fontSettings.heading} onChange={(value) => changeFont('heading', value)} />
            <FontSelector role="body" label="Texto" value={fontSettings.body} onChange={(value) => changeFont('body', value)} />
            <FontSelector role="number" label="Números" value={fontSettings.number} onChange={(value) => changeFont('number', value)} />
            <FontSelector role="button" label="Botones" value={fontSettings.button} onChange={(value) => changeFont('button', value)} />
          </section>
          <section className="style-preview">
            <span className="section-title">VISTA PREVIA</span>
            <div className="preview-title">LA GRAN IMPLOSIÓN</div>
            <div className="preview-heading">CENTRO DE CONTROL</div>
            <div className="preview-body">Flota preparada para operaciones.</div>
            <div className="preview-number">1.234.567.890</div>
            <button type="button" className="preview-button">INICIAR OPERACIÓN</button>
          </section>
          <button type="button" className="reset-button" onClick={resetFonts}>RESTAURAR PREDETERMINADO</button>
        </aside>
      )}
    </main>
  )
}

export default App
