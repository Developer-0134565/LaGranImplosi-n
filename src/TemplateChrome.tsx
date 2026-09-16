import { useEffect, useMemo, useState } from 'react'
import './styles/template-chrome.css'

type NavTarget = 'OVERVIEW' | 'EDIFICIOS' | 'INVESTIGACIÓN' | 'HANGAR' | 'DEFENSAS' | 'FLOTA' | 'GALAXIA' | 'EXPEDICIONES' | 'MENSAJES'

function clickExistingNav(label: string) {
  const item = Array.from(document.querySelectorAll<HTMLElement>('.neo-nav-item')).find((node) => node.textContent?.toUpperCase().includes(label))
  item?.click()
}

function readResource(index: number) {
  const node = document.querySelectorAll<HTMLElement>('.neo-resource')[index]
  return node?.textContent?.replace(/\s+/g, ' ').trim() || '—'
}

function readPlanet() {
  const node = document.querySelector<HTMLElement>('.neo-planetbar')
  return node?.textContent?.replace(/\s+/g, ' ').trim() || '—'
}

export default function TemplateChrome() {
  const [resources, setResources] = useState({ metal: '—', crystal: '—', deuterium: '—', energy: '—', population: '—', food: '—', darkMatter: '—' })
  const [planet, setPlanet] = useState('—')
  const [now, setNow] = useState(() => new Date())

  useEffect(() => {
    const sync = () => {
      setResources({
        metal: readResource(0),
        crystal: readResource(1),
        deuterium: readResource(2),
        energy: readResource(3),
        population: readResource(4),
        food: readResource(5),
        darkMatter: readResource(6),
      })
      setPlanet(readPlanet())
    }
    sync()
    const id = window.setInterval(sync, 1000)
    return () => window.clearInterval(id)
  }, [])

  useEffect(() => {
    const id = window.setInterval(() => setNow(new Date()), 1000)
    return () => window.clearInterval(id)
  }, [])

  const time = useMemo(() => now.toLocaleString('es-ES', { dateStyle: 'short', timeStyle: 'medium' }), [now])

  return (
    <header className="template-chrome" aria-label="Interfaz principal">
      <nav className="template-utilnav" aria-label="Utilidades">
        <button type="button" className="template-server" onClick={() => clickExistingNav('OVERVIEW')}>◉ Estadísticas y novedades</button>
        <button type="button" onClick={() => clickExistingNav('MENSAJES')}>🌐 Chat del universo</button>
        <button type="button" onClick={() => clickExistingNav('GALAXIA')}>Clasificación</button>
        <button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Destacados</button>
        <button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Récords</button>
        <button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Guerras</button>
        <button type="button" onClick={() => clickExistingNav('MENSAJES')}>Encuestas</button>
        <button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Wiki</button>
        <button type="button" onClick={() => clickExistingNav('GALAXIA')}>Simulador</button>
        <button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Herramientas</button>
        <button type="button" onClick={() => clickExistingNav('GALAXIA')}>Escáner</button>
        <button type="button" onClick={() => clickExistingNav('MENSAJES')}>Amigos</button>
        <button type="button" onClick={() => document.querySelector<HTMLButtonElement>('.style-toggle, .settings-toggle, [aria-label*="config" i]')?.click()}>Opciones</button>
        <button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Vestíbulo</button>
        <button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Cerrar sesión</button>
        <span className="template-clock">{time}</span>
      </nav>
      <div className="template-mainbar">
        <button className="template-burger" type="button" onClick={() => document.body.classList.toggle('neo-menu-open')} aria-label="Menú">☰</button>
        <button className="template-brand" type="button" onClick={() => clickExistingNav('OVERVIEW')}>
          <span className="template-brand-main">LA GRAN IMPLOSIÓN</span>
          <span className="template-brand-sub">UNIVERSO EN EVOLUCIÓN</span>
        </button>
        <div className="template-resources" aria-label="Recursos">
          <button className="template-resource template-metal" type="button" onClick={() => clickExistingNav('EDIFICIOS')}><i>◆</i><span><b>METAL</b><strong>{resources.metal}</strong></span></button>
          <button className="template-resource template-crystal" type="button" onClick={() => clickExistingNav('EDIFICIOS')}><i>◇</i><span><b>CRISTAL</b><strong>{resources.crystal}</strong></span></button>
          <button className="template-resource template-deut" type="button" onClick={() => clickExistingNav('EDIFICIOS')}><i>◈</i><span><b>DEUTERIO</b><strong>{resources.deuterium}</strong></span></button>
          <button className="template-resource template-energy" type="button" onClick={() => clickExistingNav('OVERVIEW')}><i>ϟ</i><span><b>ENERGÍA</b><strong>{resources.energy}</strong></span></button>
          <button className="template-resource template-population" type="button" onClick={() => clickExistingNav('EXPEDICIONES')}><i>♙</i><span><b>POBLACIÓN</b><strong>{resources.population}</strong></span></button>
          <button className="template-resource template-food" type="button" onClick={() => clickExistingNav('EXPEDICIONES')}><i>◆</i><span><b>COMIDA</b><strong>{resources.food}</strong></span></button>
          <button className="template-resource template-dark" type="button" onClick={() => clickExistingNav('OVERVIEW')}><i>✦</i><span><b>MATERIA OSCURA</b><strong>{resources.darkMatter}</strong></span></button>
        </div>
        <div className="template-planet"><b>PLANETA</b><span>{planet}</span></div>
      </div>
    </header>
  )
}
