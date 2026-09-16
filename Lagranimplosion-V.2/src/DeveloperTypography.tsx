import { useEffect, useMemo, useState } from 'react'

type Role = 'title' | 'heading' | 'body' | 'number' | 'button'
type RoleSettings = { font: string; size: number; weight: number; italic: boolean; spacing: number }
type Settings = Record<Role, RoleSettings>

const KEY = 'lagranimplosion-typography-v2'
const roles: Array<[Role, string]> = [
  ['title', 'Títulos'],
  ['heading', 'Encabezados'],
  ['body', 'Texto'],
  ['number', 'Números'],
  ['button', 'Botones'],
]
const fonts = ['Audiowide','Chakra Petch','Electrolize','Exo 2','Inter','JetBrains Mono','Michroma','Orbitron','Oxanium','Rajdhani','Russo One','Share Tech Mono','Space Grotesk','Space Mono','Teko','Titillium Web','Unica One','Zen Dots']

// These values are the official frontend defaults. localStorage is only the
// developer's working copy while designing; it is never the public source.
const defaults: Settings = {
  title: { font: 'Orbitron', size: 100, weight: 700, italic: false, spacing: 0 },
  heading: { font: 'Rajdhani', size: 100, weight: 600, italic: false, spacing: 0 },
  body: { font: 'Inter', size: 100, weight: 400, italic: false, spacing: 0 },
  number: { font: 'JetBrains Mono', size: 100, weight: 500, italic: false, spacing: 0 },
  button: { font: 'Chakra Petch', size: 100, weight: 600, italic: false, spacing: 0 },
}

function load(): Settings {
  try {
    const saved = JSON.parse(localStorage.getItem(KEY) || 'null') as Partial<Settings> | null
    if (!saved) return defaults
    return roles.reduce((acc, [role]) => ({ ...acc, [role]: { ...defaults[role], ...(saved[role] || {}) } }), {} as Settings)
  } catch { return defaults }
}

function apply(settings: Settings) {
  const root = document.documentElement
  roles.forEach(([role]) => {
    const value = settings[role]
    root.style.setProperty(`--dev-font-${role}`, value.font)
    root.style.setProperty(`--dev-size-${role}`, `${value.size / 100}`)
    root.style.setProperty(`--dev-weight-${role}`, String(value.weight))
    root.style.setProperty(`--dev-italic-${role}`, value.italic ? 'italic' : 'normal')
    root.style.setProperty(`--dev-spacing-${role}`, `${value.spacing}px`)
  })
}

function buildOfficialCss(settings: Settings) {
  return roles.map(([role]) => {
    const value = settings[role]
    return `--font-${role}: '${value.font}'; --text-${role}-scale: ${value.size / 100}; --font-${role}-weight: ${value.weight}; --font-${role}-style: ${value.italic ? 'italic' : 'normal'}; --font-${role}-spacing: ${value.spacing}px;`
  }).join('\n')
}

export default function DeveloperTypography() {
  if (!import.meta.env.DEV) return null
  const [open, setOpen] = useState(false)
  const [role, setRole] = useState<Role>('title')
  const [settings, setSettings] = useState<Settings>(() => load())
  const current = settings[role]

  useEffect(() => { apply(settings); localStorage.setItem(KEY, JSON.stringify(settings)) }, [settings])
  const previewStyle = useMemo(() => ({ fontFamily: current.font, fontSize: `${Math.max(12, 22 * current.size / 100)}px`, fontWeight: current.weight, fontStyle: current.italic ? 'italic' : 'normal', letterSpacing: `${current.spacing}px` }), [current])
  const update = (patch: Partial<RoleSettings>) => setSettings(prev => ({ ...prev, [role]: { ...prev[role], ...patch } }))
  const exportOfficial = async () => {
    const payload = JSON.stringify(settings, null, 2)
    const css = `:root {\n${buildOfficialCss(settings)}\n}`
    try {
      await navigator.clipboard.writeText(`${payload}\n\n/* Official CSS variables */\n${css}`)
      window.dispatchEvent(new CustomEvent('lagranimplosion:notice', { detail: 'Configuración tipográfica copiada. Esta es la configuración que debe publicarse en el frontend.' }))
    } catch {
      window.prompt('Copia esta configuración para publicarla en el frontend:', `${payload}\n\n/* Official CSS variables */\n${css}`)
    }
  }

  return <>
    <button type="button" className="typography-launcher" onClick={() => setOpen(v => !v)} aria-label="Tipografía del desarrollador">Aa</button>
    {open && <section className="typography-controls open" aria-label="Controles de tipografía del desarrollador">
      <div className="typography-head"><strong>TIPOGRAFÍA · DEV</strong><button type="button" onClick={() => setOpen(false)} aria-label="Cerrar">×</button></div>
      <p>Diseña aquí. Los cambios se guardan localmente mientras trabajas. Al terminar, copia la configuración oficial y se publica en el código del frontend para todos los jugadores.</p>
      <div className="typography-roles">{roles.map(([id, label]) => <button key={id} type="button" className={role === id ? 'active' : ''} onClick={() => setRole(id)}>{label}</button>)}</div>
      <label className="type-font-single"><span>Fuente</span><select value={current.font} onChange={e => update({ font: e.target.value })}>{fonts.map(font => <option key={font}>{font}</option>)}</select></label>
      <div className="type-row"><span>Tamaño</span><input type="range" min="70" max="160" value={current.size} onChange={e => update({ size: Number(e.target.value) })}/><output>{current.size}%</output></div>
      <div className="type-row"><span>Peso</span><input type="range" min="300" max="900" step="100" value={current.weight} onChange={e => update({ weight: Number(e.target.value) })}/><output>{current.weight}</output></div>
      <div className="type-row"><span>Espaciado</span><input type="range" min="-1" max="5" step="0.5" value={current.spacing} onChange={e => update({ spacing: Number(e.target.value) })}/><output>{current.spacing}px</output></div>
      <button type="button" className={`typography-style-toggle${current.italic ? ' active' : ''}`} onClick={() => update({ italic: !current.italic })}>Cursiva</button>
      <div className="typography-preview" style={previewStyle}>La Gran Implosión 123</div>
      <button type="button" className="typography-publish" onClick={exportOfficial}>Copiar configuración oficial</button>
      <button type="button" className="typography-reset" onClick={() => setSettings(defaults)}>Restablecer todo</button>
    </section>}
  </>
}
