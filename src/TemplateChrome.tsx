import { useEffect, useMemo, useState } from 'react'
import './styles/template-chrome.css'

type NavTarget = 'OVERVIEW' | 'EDIFICIOS' | 'INVESTIGACIÓN' | 'HANGAR' | 'DEFENSAS' | 'FLOTA' | 'GALAXIA' | 'EXPEDICIONES' | 'MENSAJES'

const navTargets: Array<{ label: NavTarget; short: string }> = [
  { label: 'OVERVIEW', short: 'INICIO' },
  { label: 'EDIFICIOS', short: 'EDIFICIOS' },
  { label: 'INVESTIGACIÓN', short: 'INVESTIGACIÓN' },
  { label: 'HANGAR', short: 'HANGAR' },
  { label: 'DEFENSAS', short: 'DEFENSAS' },
  { label: 'FLOTA', short: 'FLOTA' },
  { label: 'GALAXIA', short: 'GALAXIA' },
  { label: 'EXPEDICIONES', short: 'EXPEDICIONES' },
  { label: 'MENSAJES', short: 'MENSAJES' },
]

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
  const [resources, setResources] = useState({ metal: '—', crystal: '—', deuterium: '—', energy: '—' })
  const [planet, setPlanet] = useState('—')
  const [now, setNow] = useState(() => new Date())

  useEffect(() => {
    const sync = () => {
      setResources({ metal: readResource(0), crystal: readResource(1), deuterium: readResource(2), energy: readResource(3) })
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

  const time = useMemo(() => now.toLocaleTimeString('es-ES', { hour: '2-digit', minute: '2-digit', second: '2-digit' }), [now])

  return (
    <header className="template-chrome" aria-label="Interfaz principal">
      <div className="template-topline">
        <div className="template-brand">
          <span className="template-brand-main">LA GRAN IMPLOSIÓN</span>
          <span className="template-brand-sub">UNIVERSO EN EVOLUCIÓN</span>
        </div>
        <nav className="template-global-nav" aria-label="Controles superiores">
          <button type="button" onClick={() => clickExistingNav('OVERVIEW')}>◈ IMPERIO</button>
          <button type="button" onClick={() => clickExistingNav('GALAXIA')}>⌘ CLASIFICACIÓN</button>
          <button type="button" onClick={() => clickExistingNav('MENSAJES')}>✉ MENSAJES</button>
          <button type="button" onClick={() => document.querySelector<HTMLButtonElement>('.style-toggle, .settings-toggle, [aria-label*="config" i]')?.click()}>⚙ CONFIG</button>
          <span className="template-clock">{time}</span>
        </nav>
      </div>
      <div className="template-resourcebar">
        <button className="template-resource template-metal" type="button" onClick={() => clickExistingNav('EDIFICIOS')}><i>◆</i><span><b>METAL</b><strong>{resources.metal}</strong></span></button>
        <button className="template-resource template-crystal" type="button" onClick={() => clickExistingNav('EDIFICIOS')}><i>◇</i><span><b>CRISTAL</b><strong>{resources.crystal}</strong></span></button>
        <button className="template-resource template-deut" type="button" onClick={() => clickExistingNav('EDIFICIOS')}><i>◈</i><span><b>DEUTERIO</b><strong>{resources.deuterium}</strong></span></button>
        <div className="template-resource template-energy"><i>ϟ</i><span><b>ENERGÍA</b><strong>{resources.energy}</strong></span></div>
        <div className="template-resource template-dark"><i>✦</i><span><b>MATERIA OSCURA</b><strong>—</strong></span></div>
        <div className="template-resource template-planet"><i>◎</i><span><b>PLANETA ACTUAL</b><strong>{planet}</strong></span></div>
      </div>
      <div className="template-actionbar">
        <div className="template-action-group">
          {navTargets.slice(0, 5).map((item) => (
            <button key={item.label} type="button" onClick={() => clickExistingNav(item.label)}>{item.short}</button>
          ))}
        </div>
        <div className="template-action-group template-action-right">
          <button type="button" onClick={() => clickExistingNav('FLOTA')}>◀ FLOTA</button>
          <button type="button" onClick={() => clickExistingNav('EXPEDICIONES')}>✧ EXPEDICIONES</button>
          <button type="button" onClick={() => clickExistingNav('MENSAJES')}>▣ REGISTROS</button>
        </div>
      </div>
    </header>
  )
}
