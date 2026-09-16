import { useEffect, useMemo, useState } from 'react'
import './styles/template-chrome.css'

type NavTarget = 'OVERVIEW' | 'EDIFICIOS' | 'INVESTIGACIÓN' | 'HANGAR' | 'DEFENSAS' | 'FLOTA' | 'GALAXIA' | 'EXPEDICIONES' | 'MENSAJES'
type PlanetChip = { name: string; coords: string }

function clickExistingNav(label: string) {
  const item = Array.from(document.querySelectorAll<HTMLElement>('.neo-nav-item')).find((node) => node.textContent?.toUpperCase().includes(label))
  item?.click()
}
function readResource(index: number) { const node = document.querySelectorAll<HTMLElement>('.neo-resource')[index]; return node?.textContent?.replace(/\s+/g, ' ').trim() || '—' }
function readPlanet() { const node = document.querySelector<HTMLElement>('.neo-planetbar'); return node?.textContent?.replace(/\s+/g, ' ').trim() || '—' }
function readOwnedPlanets(): PlanetChip[] { return Array.from(document.querySelectorAll<HTMLElement>('.owned-planet')).map((node) => { const text = node.textContent?.replace(/\s+/g, ' ').trim() || 'Planeta'; const coords = text.match(/\[[0-9]+:[0-9]+:[0-9]+\]/)?.[0] || '[—]'; const name = text.replace(coords, '').trim().replace(/\s+/g, ' ') || 'Planeta'; return { name, coords } }).slice(0, 28) }

const MenuButton = ({ label, target, active = false, gold = false }: { label: string; target?: NavTarget; active?: boolean; gold?: boolean }) => <button type="button" className={`template-menu-link${active ? ' active' : ''}${gold ? ' gold' : ''}`} onClick={() => target && clickExistingNav(target)}>{label}</button>

export default function TemplateChrome() {
  const [resources, setResources] = useState({ metal: '—', crystal: '—', deuterium: '—', energy: '—', population: '—', food: '—', darkMatter: '—' })
  const [planet, setPlanet] = useState('—'); const [planets, setPlanets] = useState<PlanetChip[]>([]); const [activeLabel, setActiveLabel] = useState('OVERVIEW'); const [now, setNow] = useState(() => new Date())
  useEffect(() => { const sync = () => { setResources({ metal: readResource(0), crystal: readResource(1), deuterium: readResource(2), energy: readResource(3), population: readResource(4), food: readResource(5), darkMatter: readResource(6) }); setPlanet(readPlanet()); setPlanets(readOwnedPlanets()); const active = document.querySelector<HTMLElement>('.neo-nav-item.active')?.textContent?.trim().toUpperCase(); if (active) setActiveLabel(active) }; sync(); const id = window.setInterval(sync, 500); return () => window.clearInterval(id) }, [])
  useEffect(() => { const id = window.setInterval(() => setNow(new Date()), 1000); return () => window.clearInterval(id) }, [])
  const time = useMemo(() => now.toLocaleString('es-ES', { dateStyle: 'short', timeStyle: 'medium' }), [now]); const isActive = (target: NavTarget) => activeLabel.includes(target)
  const selectPlanet = (index: number) => document.querySelectorAll<HTMLElement>('.owned-planet')[index]?.click()

  return <>
    <header className="template-chrome" aria-label="Interfaz principal">
      <nav className="template-utilnav" aria-label="Utilidades">
        <button type="button" className="template-server" onClick={() => clickExistingNav('OVERVIEW')}>◉ Estadísticas y novedades</button><button type="button" onClick={() => clickExistingNav('MENSAJES')}>🌐 Chat del universo</button><button type="button" onClick={() => clickExistingNav('GALAXIA')}>Clasificación</button><button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Destacados</button><button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Récords</button><button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Guerras</button><button type="button" onClick={() => clickExistingNav('MENSAJES')}>Encuestas</button><button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Wiki</button><button type="button" onClick={() => clickExistingNav('GALAXIA')}>Simulador</button><button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Herramientas</button><button type="button" onClick={() => clickExistingNav('GALAXIA')}>Escáner</button><button type="button" onClick={() => clickExistingNav('MENSAJES')}>Amigos</button><button type="button" onClick={() => document.querySelector<HTMLButtonElement>('.style-toggle, .settings-toggle, [aria-label*="config" i]')?.click()}>Opciones</button><button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Vestíbulo</button><button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Cerrar sesión</button><span className="template-clock">{time}</span>
      </nav>
      <div className="template-mainbar">
        <button className="template-burger" type="button" onClick={() => document.body.classList.toggle('neo-menu-open')} aria-label="Menú">☰</button>
        <button className="template-brand" type="button" onClick={() => clickExistingNav('OVERVIEW')}><span className="template-brand-main">LA GRAN IMPLOSIÓN</span><span className="template-brand-sub">UNIVERSO EN EVOLUCIÓN</span></button>
        <div className="template-resources" aria-label="Recursos">
          <button className="template-resource template-metal" type="button" onClick={() => clickExistingNav('EDIFICIOS')}><i>◆</i><span><b>METAL</b><strong>{resources.metal}</strong></span></button><button className="template-resource template-crystal" type="button" onClick={() => clickExistingNav('EDIFICIOS')}><i>◇</i><span><b>CRISTAL</b><strong>{resources.crystal}</strong></span></button><button className="template-resource template-deut" type="button" onClick={() => clickExistingNav('EDIFICIOS')}><i>◈</i><span><b>DEUTERIO</b><strong>{resources.deuterium}</strong></span></button><button className="template-resource template-energy" type="button" onClick={() => clickExistingNav('OVERVIEW')}><i>ϟ</i><span><b>ENERGÍA</b><strong>{resources.energy}</strong></span></button><button className="template-resource template-population" type="button" onClick={() => clickExistingNav('EXPEDICIONES')}><i>♙</i><span><b>POBLACIÓN</b><strong>{resources.population}</strong></span></button><button className="template-resource template-food" type="button" onClick={() => clickExistingNav('EXPEDICIONES')}><i>◆</i><span><b>COMIDA</b><strong>{resources.food}</strong></span></button><button className="template-resource template-dark" type="button" onClick={() => clickExistingNav('OVERVIEW')}><i>✦</i><span><b>MATERIA OSCURA</b><strong>{resources.darkMatter}</strong></span></button>
        </div><div className="template-planet"><b>PLANETA</b><span>{planet}</span></div>
      </div>
    </header>

    <div className="template-planetstrip" aria-label="Planetas">{planets.length ? planets.map((entry, index) => <button type="button" key={`${entry.name}-${index}`} className={`template-planet-chip${planet.includes(entry.name) ? ' active' : ''}`} onClick={() => selectPlanet(index)}><span className="template-planet-orb"/><span className="template-planet-name">{entry.name}</span><span className="template-planet-coords">{entry.coords}</span></button>) : <span className="template-planet-empty">Cargando planetas…</span>}</div>

    <div className="template-eventbar" aria-label="Eventos de flota"><button type="button" onClick={() => clickExistingNav('MENSAJES')}>✉ MENSAJES</button><span className="template-event-sep"/><span className="template-event-friendly">PROPIAS <b>—</b></span><span className="template-event-neutral">AMIGAS <b>—</b></span><span className="template-event-hostile">HOSTILES <b>—</b></span><span className="template-event-next">SIGUIENTE EVENTO <b>—</b></span><button type="button" onClick={() => clickExistingNav('FLOTA')}>▾ MOVIMIENTOS</button></div>

    <aside className="template-side" aria-label="Navegación del imperio">
      <div className="template-side-event">🗳️ Encuesta abierta <span>VOTADO</span></div><div className="template-side-event amber">🛠 Restos <span>6</span></div>
      <section><h3>Imperio</h3><MenuButton label="Vista general" target="OVERVIEW" active={isActive('OVERVIEW')}/><MenuButton label="Recursos" target="OVERVIEW"/><MenuButton label="Instalaciones" target="EDIFICIOS" active={isActive('EDIFICIOS')}/></section>
      <section><h3>Progresión</h3><MenuButton label="Oficiales" gold/><MenuButton label="Academia"/><MenuButton label="Formas de vida" target="EXPEDICIONES"/><MenuButton label="Investigación FV" target="INVESTIGACIÓN"/><MenuButton label="Civilización"/><MenuButton label="Investigación" target="INVESTIGACIÓN" active={isActive('INVESTIGACIÓN')}/></section>
      <section><h3>Espacio</h3><MenuButton label="Flota" target="FLOTA" active={isActive('FLOTA')}/><MenuButton label="Hangar" target="HANGAR" active={isActive('HANGAR')}/><MenuButton label="Defensa" target="DEFENSAS" active={isActive('DEFENSAS')}/><MenuButton label="Galaxia" target="GALAXIA" active={isActive('GALAXIA')}/><MenuButton label="Expediciones" target="EXPEDICIONES" active={isActive('EXPEDICIONES')}/><MenuButton label="Mensajes" target="MENSAJES" active={isActive('MENSAJES')}/></section>
      <section><h3>Comerciar</h3><MenuButton label="Mercader" gold/><MenuButton label="Importación / Exportación" gold/></section><section><h3>Cuenta</h3><MenuButton label="Perfil"/><MenuButton label="Opciones"/></section>
    </aside>
  </>
}
