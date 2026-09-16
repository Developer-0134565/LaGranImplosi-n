import { useEffect, useMemo, useState } from 'react'

type NavTarget = 'OVERVIEW' | 'EDIFICIOS' | 'INVESTIGACIÓN' | 'HANGAR' | 'DEFENSAS' | 'FLOTA' | 'GALAXIA' | 'EXPEDICIONES' | 'MENSAJES'
type PlanetChip = { id: string; name: string; coords: string }

const PLANET_ORDER_PREFIX = 'lagranimplosion:planet-order:'

function clickExistingNav(label: string) {
  const item = Array.from(document.querySelectorAll<HTMLElement>('.neo-nav-item')).find((node) => node.textContent?.toUpperCase().includes(label))
  if (item) item.click()
}

function showModuleNotice(label: string) {
  window.dispatchEvent(new CustomEvent('lagranimplosion:notice', { detail: `${label}: módulo pendiente de conexión con el motor.` }))
}

function clickSettings() {
  const button = document.querySelector<HTMLButtonElement>('.settings-button')
  if (button) button.click()
  else showModuleNotice('Opciones')
}

function readResource(index: number) {
  const node = document.querySelectorAll<HTMLElement>('.neo-resource')[index]
  if (!node) return '—'
  const value = node.querySelector('b')?.textContent?.trim()
  return value || node.textContent?.replace(/\s+/g, ' ').trim() || '—'
}

function readPlanet() {
  const bar = document.querySelector<HTMLElement>('.neo-planetbar')
  if (bar?.textContent?.trim()) return bar.textContent.replace(/\s+/g, ' ').trim()
  const title = document.querySelector<HTMLElement>('.neo-overview-grid h1')
  const coords = document.querySelector<HTMLElement>('.neo-overview-grid p')
  return title?.textContent?.trim() ? `${title.textContent.trim()} ${coords?.textContent?.trim() || ''}`.trim() : '—'
}

function readOwnedPlanets(): PlanetChip[] {
  const nodes = document.querySelectorAll<HTMLElement>('.neo-planet-row, .owned-planet')
  return Array.from(nodes).map((node) => {
    const text = node.textContent?.replace(/\s+/g, ' ').trim() || 'Planeta'
    const coords = text.match(/\[[0-9]+:[0-9]+:[0-9]+\]/)?.[0] || '[—]'
    const id = node.getAttribute('data-planet-id') || node.dataset.planetId || coords
    return { id, name: text.replace(coords, '').trim().replace(/\s+/g, ' ') || 'Planeta', coords }
  }).slice(0, 28)
}

function orderKey(items: PlanetChip[]) {
  return `${PLANET_ORDER_PREFIX}${items.map((item) => item.id).sort().join('|')}`
}

function applyStoredOrder(items: PlanetChip[]) {
  if (!items.length) return items
  try {
    const stored = JSON.parse(localStorage.getItem(orderKey(items)) || 'null')
    if (!Array.isArray(stored)) return items
    const byId = new Map(items.map((item) => [item.id, item]))
    const ordered = stored.map((id: unknown) => byId.get(String(id))).filter(Boolean) as PlanetChip[]
    const known = new Set(ordered.map((item) => item.id))
    return [...ordered, ...items.filter((item) => !known.has(item.id))]
  } catch {
    return items
  }
}

function movePlanet(items: PlanetChip[], sourceId: string, targetId: string) {
  if (sourceId === targetId) return items
  const sourceIndex = items.findIndex((item) => item.id === sourceId)
  const targetIndex = items.findIndex((item) => item.id === targetId)
  if (sourceIndex < 0 || targetIndex < 0) return items
  const next = [...items]
  const [moved] = next.splice(sourceIndex, 1)
  next.splice(targetIndex, 0, moved)
  return next
}

const MenuButton = ({ label, target, active = false, gold = false }: { label: string; target?: NavTarget; active?: boolean; gold?: boolean }) => (
  <button type="button" className={`template-menu-link${active ? ' active' : ''}${gold ? ' gold' : ''}`} onClick={() => target ? clickExistingNav(target) : label === 'Opciones' ? clickSettings() : showModuleNotice(label)}>{label}</button>
)

export default function TemplateChrome() {
  const [resources, setResources] = useState({ metal: '—', crystal: '—', deuterium: '—', energy: '—', population: '—', food: '—', darkMatter: '—' })
  const [planet, setPlanet] = useState('—')
  const [planets, setPlanets] = useState<PlanetChip[]>([])
  const [activeLabel, setActiveLabel] = useState('OVERVIEW')
  const [now, setNow] = useState(() => new Date())
  const [moduleNotice, setModuleNotice] = useState<string | null>(null)
  const [ordering, setOrdering] = useState(false)
  const [draftOrder, setDraftOrder] = useState<PlanetChip[]>([])
  const [dragId, setDragId] = useState<string | null>(null)

  useEffect(() => {
    const sync = () => {
      setResources({ metal: readResource(0), crystal: readResource(1), deuterium: readResource(2), energy: readResource(3), population: readResource(4), food: readResource(5), darkMatter: readResource(6) })
      setPlanet(readPlanet())
      const rawPlanets = readOwnedPlanets()
      if (!ordering) setPlanets((previous) => applyStoredOrder(rawPlanets.length ? rawPlanets : previous))
      const active = document.querySelector<HTMLElement>('.neo-nav-item.active')?.textContent?.trim().toUpperCase()
      if (active) setActiveLabel(active)
    }
    sync()
    const id = window.setInterval(sync, 500)
    return () => window.clearInterval(id)
  }, [ordering])

  useEffect(() => {
    const id = window.setInterval(() => setNow(new Date()), 1000)
    return () => window.clearInterval(id)
  }, [])

  useEffect(() => {
    const handler = (event: Event) => setModuleNotice((event as CustomEvent<string>).detail)
    window.addEventListener('lagranimplosion:notice', handler)
    return () => window.removeEventListener('lagranimplosion:notice', handler)
  }, [])

  const time = useMemo(() => now.toLocaleString('es-ES', { dateStyle: 'short', timeStyle: 'medium' }), [now])
  const isActive = (target: NavTarget) => activeLabel.includes(target)
  const visiblePlanets = ordering ? draftOrder : planets

  const beginOrdering = () => {
    setDraftOrder([...planets])
    setOrdering(true)
  }

  const cancelOrdering = () => {
    setDraftOrder([])
    setDragId(null)
    setOrdering(false)
  }

  const saveOrdering = () => {
    if (!draftOrder.length) return cancelOrdering()
    try {
      localStorage.setItem(orderKey(draftOrder), JSON.stringify(draftOrder.map((item) => item.id)))
    } catch {
      // Keep the current order in memory even if browser storage is unavailable.
    }
    setPlanets(draftOrder)
    setDraftOrder([])
    setDragId(null)
    setOrdering(false)
  }

  const sortAlphabetically = () => {
    setDraftOrder((items) => [...items].sort((a, b) => a.name.localeCompare(b.name, 'es', { sensitivity: 'base' })))
  }

  const sortByCoordinates = () => {
    const coordinate = (value: string) => (value.match(/\d+/g) || []).map(Number)
    setDraftOrder((items) => [...items].sort((a, b) => {
      const ac = coordinate(a.coords)
      const bc = coordinate(b.coords)
      for (let index = 0; index < 3; index += 1) {
        const diff = (ac[index] || 0) - (bc[index] || 0)
        if (diff) return diff
      }
      return a.name.localeCompare(b.name, 'es', { sensitivity: 'base' })
    }))
  }

  const selectPlanet = (id: string) => {
    const row = Array.from(document.querySelectorAll<HTMLElement>('.neo-planet-row, .owned-planet')).find((node) => (node.getAttribute('data-planet-id') || node.dataset.planetId || (node.textContent?.match(/\[[0-9]+:[0-9]+:[0-9]+\]/)?.[0] || '')) === id)
    row?.click()
  }

  return <>
    <header className="template-chrome" aria-label="Interfaz principal">
      <nav className="template-utilnav" aria-label="Utilidades">
        <button type="button" className="template-server" onClick={() => clickExistingNav('OVERVIEW')}>◉ Estadísticas y novedades</button>
        <button type="button" onClick={() => clickExistingNav('MENSAJES')}>🌐 Chat del universo</button>
        <button type="button" onClick={() => clickExistingNav('GALAXIA')}>Clasificación</button>
        <button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Destacados</button>
        <button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Récords</button>
        <button type="button" onClick={() => clickExistingNav('FLOTA')}>Guerras</button>
        <button type="button" onClick={() => clickExistingNav('MENSAJES')}>Encuestas</button>
        <button type="button" onClick={() => showModuleNotice('Wiki')}>Wiki</button>
        <button type="button" onClick={() => clickExistingNav('GALAXIA')}>Simulador</button>
        <button type="button" onClick={() => showModuleNotice('Herramientas')}>Herramientas</button>
        <button type="button" onClick={() => clickExistingNav('GALAXIA')}>Escáner</button>
        <button type="button" onClick={() => clickExistingNav('MENSAJES')}>Amigos</button>
        <button type="button" onClick={clickSettings}>Opciones</button>
        <button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Vestíbulo</button>
        <button type="button" onClick={() => showModuleNotice('Cerrar sesión')}>Cerrar sesión</button>
        <span className="template-clock">{time}</span>
      </nav>
      <div className="template-mainbar">
        <button className="template-burger" type="button" onClick={() => document.body.classList.toggle('neo-menu-open')} aria-label="Menú">☰</button>
        <button className="template-brand" type="button" onClick={() => clickExistingNav('OVERVIEW')}>
          <span className="template-brand-main">LA GRAN IMPLOSIÓN</span>
          <span className="template-brand-sub">UNIVERSO EN EVOLUCIÓN</span>
        </button>
        <div className="template-resources" aria-label="Recursos">
          <button className="template-resource template-metal" type="button"><i>◆</i><span><b>METAL</b><strong>{resources.metal}</strong></span></button>
          <button className="template-resource template-crystal" type="button"><i>◇</i><span><b>CRISTAL</b><strong>{resources.crystal}</strong></span></button>
          <button className="template-resource template-deut" type="button"><i>◈</i><span><b>DEUTERIO</b><strong>{resources.deuterium}</strong></span></button>
          <button className="template-resource template-energy" type="button"><i>ϟ</i><span><b>ENERGÍA</b><strong>{resources.energy}</strong></span></button>
          <button className="template-resource template-population" type="button"><i>♙</i><span><b>POBLACIÓN</b><strong>{resources.population}</strong></span></button>
          <button className="template-resource template-food" type="button"><i>◆</i><span><b>COMIDA</b><strong>{resources.food}</strong></span></button>
          <button className="template-resource template-dark" type="button"><i>✦</i><span><b>MATERIA OSCURA</b><strong>{resources.darkMatter}</strong></span></button>
        </div>
        <div className="template-planet"><b>PLANETA</b><span>{planet}</span></div>
      </div>
    </header>

    <div className={`template-planetstrip${ordering ? ' ordering' : ''}`} aria-label="Planetas">
      <div className="template-planet-list">
        {visiblePlanets.length ? visiblePlanets.map((entry) => <button
          type="button"
          key={entry.id}
          className={`template-planet-chip${planet.includes(entry.name) ? ' active' : ''}${ordering ? ' draggable' : ''}`}
          draggable={ordering}
          onClick={() => !ordering && selectPlanet(entry.id)}
          onDragStart={() => setDragId(entry.id)}
          onDragOver={(event) => {
            if (!ordering || !dragId || dragId === entry.id) return
            event.preventDefault()
            setDraftOrder((items) => movePlanet(items, dragId, entry.id))
            setDragId(entry.id)
          }}
          onDragEnd={() => setDragId(null)}
          aria-label={ordering ? `Reordenar ${entry.name} ${entry.coords}` : `${entry.name} ${entry.coords}`}
        >
          <span className="template-planet-orb"/><span className="template-planet-name">{entry.name}</span><span className="template-planet-coords">{entry.coords}</span>
        </button>) : <span className="template-planet-empty">Cargando planetas…</span>}
      </div>
      <div className="template-planet-order-controls" aria-label="Orden de planetas">
        {!ordering ? <button type="button" onClick={beginOrdering}>Editar</button> : <>
          <button type="button" onClick={sortAlphabetically}>A-Z</button>
          <button type="button" onClick={sortByCoordinates}>Coordenadas</button>
          <button type="button" onClick={cancelOrdering}>Cancelar</button>
          <button type="button" className="save" onClick={saveOrdering}>Guardar</button>
        </>}
      </div>
    </div>

    <aside className="template-side" aria-label="Navegación del imperio">
      <section><h3>Imperio</h3><MenuButton label="Vista general" target="OVERVIEW" active={isActive('OVERVIEW')}/><MenuButton label="Recursos" target="OVERVIEW"/><MenuButton label="Instalaciones" target="EDIFICIOS" active={isActive('EDIFICIOS')}/></section>
      <section><h3>Progresión</h3><MenuButton label="Oficiales" gold/><MenuButton label="Academia"/><MenuButton label="Formas de vida" target="EXPEDICIONES"/><MenuButton label="Investigación FV" target="INVESTIGACIÓN"/><MenuButton label="Civilización"/><MenuButton label="Investigación" target="INVESTIGACIÓN" active={isActive('INVESTIGACIÓN')}/></section>
      <section><h3>Espacio</h3><MenuButton label="Flota" target="FLOTA" active={isActive('FLOTA')}/><MenuButton label="Hangar" target="HANGAR" active={isActive('HANGAR')}/><MenuButton label="Defensa" target="DEFENSAS" active={isActive('DEFENSAS')}/><MenuButton label="Galaxia" target="GALAXIA" active={isActive('GALAXIA')}/><MenuButton label="Expediciones" target="EXPEDICIONES" active={isActive('EXPEDICIONES')}/><MenuButton label="Mensajes" target="MENSAJES" active={isActive('MENSAJES')}/></section>
      <section><h3>Comerciar</h3><MenuButton label="Mercader" gold/><MenuButton label="Importación / Exportación" gold/></section>
      <section><h3>Cuenta</h3><MenuButton label="Perfil"/><MenuButton label="Opciones"/></section>
    </aside>

    {moduleNotice && <div className="template-module-notice" role="status" onClick={() => setModuleNotice(null)}>{moduleNotice}</div>}
  </>
}
