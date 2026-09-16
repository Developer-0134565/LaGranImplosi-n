import { useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'
import './styles/template-chrome.css'
import './styles/frontend-layer-fix.css'
import './styles/planet-window.css'

type NavTarget = 'OVERVIEW' | 'EDIFICIOS' | 'INVESTIGACIÓN' | 'HANGAR' | 'DEFENSAS' | 'FLOTA' | 'GALAXIA' | 'EXPEDICIONES' | 'MENSAJES'
type PlanetChip = { id: string; name: string; coords: string }

function clickExistingNav(label: string) { const item = Array.from(document.querySelectorAll<HTMLElement>('.neo-nav-item')).find((node) => node.textContent?.toUpperCase().includes(label)); item?.click() }
function showModuleNotice(label: string) { window.dispatchEvent(new CustomEvent('lagranimplosion:notice', { detail: `${label}: módulo pendiente de conexión con el motor.` })) }
function clickSettings() { const button = document.querySelector<HTMLButtonElement>('.settings-button'); if (button) button.click(); else showModuleNotice('Opciones') }
function readResource(index: number) { const top = document.querySelectorAll<HTMLElement>('.neo-resources span b')[index]; if (top?.textContent?.trim()) return top.textContent.trim(); return document.querySelectorAll<HTMLElement>('.neo-resource')[index]?.textContent?.replace(/\s+/g, ' ').trim() || '—' }
function readPlanet() { const bar = document.querySelector<HTMLElement>('.neo-planetbar'); if (bar?.textContent?.trim()) return bar.textContent.replace(/\s+/g, ' ').trim(); const title = document.querySelector<HTMLElement>('.neo-overview-grid section h1'); const coords = document.querySelector<HTMLElement>('.neo-overview-grid section>p'); return title?.textContent?.trim() ? `${title.textContent.trim()} ${coords?.textContent?.trim() || ''}`.trim() : '—' }

const MenuButton = ({ label, target, active = false, gold = false }: { label: string; target?: NavTarget; active?: boolean; gold?: boolean }) => <button type="button" className={`template-menu-link${active ? ' active' : ''}${gold ? ' gold' : ''}`} onClick={() => target ? clickExistingNav(target) : label === 'Opciones' ? clickSettings() : showModuleNotice(label)}>{label}</button>

export default function TemplateChrome() {
  const [resources, setResources] = useState({ metal: '—', crystal: '—', deuterium: '—', energy: '—', population: '—', food: '—', darkMatter: '—' })
  const [planet, setPlanet] = useState('—')
  const [planets, setPlanets] = useState<PlanetChip[]>([])
  const [planetOrder, setPlanetOrder] = useState<'AZ' | 'COORDS'>('COORDS')
  const [planetSettingsOpen, setPlanetSettingsOpen] = useState(false)
  const [activeLabel, setActiveLabel] = useState('OVERVIEW')
  const [now, setNow] = useState(() => new Date())
  const [moduleNotice, setModuleNotice] = useState<string | null>(null)

  useEffect(() => { let cancelled = false; const loadPlanets = async () => { const { data, error } = await supabase.from('planets').select('id,name,galaxy,system,position,is_destroyed,players(id,is_guest)').eq('is_destroyed', false).order('galaxy').order('system').order('position'); if (cancelled) return; if (error) { setPlanets([]); return } const owned = (data ?? []).filter((p: any) => Array.isArray(p.players) && p.players.some((player: any) => player?.is_guest === true)); setPlanets(owned.map((p: any) => ({ id: p.id, name: p.name || 'Planeta', coords: `[${p.galaxy}:${p.system}:${p.position}]` }))) }; void loadPlanets(); return () => { cancelled = true } }, [])
  useEffect(() => { const sync = () => { setResources({ metal: readResource(0), crystal: readResource(1), deuterium: readResource(2), energy: readResource(3), population: '—', food: '—', darkMatter: '—' }); setPlanet(readPlanet()); const active = document.querySelector<HTMLElement>('.neo-nav-item.active')?.textContent?.trim().toUpperCase(); if (active) setActiveLabel(active) }; sync(); const id = window.setInterval(sync, 500); return () => window.clearInterval(id) }, [])
  useEffect(() => { const id = window.setInterval(() => setNow(new Date()), 1000); return () => window.clearInterval(id) }, [])
  useEffect(() => { const handler = (event: Event) => setModuleNotice((event as CustomEvent<string>).detail); window.addEventListener('lagranimplosion:notice', handler); return () => window.removeEventListener('lagranimplosion:notice', handler) }, [])

  const time = useMemo(() => now.toLocaleString('es-ES', { dateStyle: 'short', timeStyle: 'medium' }), [now])
  const isActive = (target: NavTarget) => activeLabel.includes(target)
  const orderedPlanets = useMemo(() => [...planets].sort((a, b) => planetOrder === 'AZ' ? a.name.localeCompare(b.name, 'es') : a.coords.localeCompare(b.coords, undefined, { numeric: true })), [planets, planetOrder])
  const selectPlanet = (entry: PlanetChip) => { const nodes = Array.from(document.querySelectorAll<HTMLElement>('.owned-planet')); nodes.find((candidate) => candidate.textContent?.includes(entry.coords) || candidate.textContent?.includes(entry.name))?.click() }

  return <>
    <header className="template-chrome" aria-label="Interfaz principal">
      <nav className="template-utilnav" aria-label="Utilidades">
        <button type="button" className="template-server" onClick={() => clickExistingNav('OVERVIEW')}>◉ Estadísticas y novedades</button><button type="button" onClick={() => clickExistingNav('MENSAJES')}>🌐 Chat del universo</button><button type="button" onClick={() => clickExistingNav('GALAXIA')}>Clasificación</button><button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Destacados</button><button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Récords</button><button type="button" onClick={() => clickExistingNav('FLOTA')}>Guerras</button><button type="button" onClick={() => clickExistingNav('MENSAJES')}>Encuestas</button><button type="button" onClick={() => showModuleNotice('Wiki')}>Wiki</button><button type="button" onClick={() => clickExistingNav('GALAXIA')}>Simulador</button><button type="button" onClick={() => showModuleNotice('Herramientas')}>Herramientas</button><button type="button" onClick={() => clickExistingNav('GALAXIA')}>Escáner</button><button type="button" onClick={() => clickExistingNav('MENSAJES')}>Amigos</button><button type="button" onClick={clickSettings}>Opciones</button><button type="button" onClick={() => clickExistingNav('OVERVIEW')}>Vestíbulo</button><button type="button" onClick={() => showModuleNotice('Cerrar sesión')}>Cerrar sesión</button><span className="template-clock">{time}</span>
      </nav>
      <div className="template-mainbar">
        <button className="template-burger" type="button" onClick={() => document.body.classList.toggle('neo-menu-open')} aria-label="Menú">☰</button><button className="template-brand" type="button" onClick={() => clickExistingNav('OVERVIEW')}><span className="template-brand-main">LA GRAN IMPLOSIÓN</span><span className="template-brand-sub">UNIVERSO EN EVOLUCIÓN</span></button>
        <div className="template-resources" aria-label="Recursos"><button className="template-resource template-metal" type="button" onClick={() => clickExistingNav('OVERVIEW')}><i>◆</i><span><b>METAL</b><strong>{resources.metal}</strong></span></button><button className="template-resource template-crystal" type="button" onClick={() => clickExistingNav('OVERVIEW')}><i>◇</i><span><b>CRISTAL</b><strong>{resources.crystal}</strong></span></button><button className="template-resource template-deut" type="button" onClick={() => clickExistingNav('OVERVIEW')}><i>◈</i><span><b>DEUTERIO</b><strong>{resources.deuterium}</strong></span></button><button className="template-resource template-energy" type="button" onClick={() => clickExistingNav('OVERVIEW')}><i>ϟ</i><span><b>ENERGÍA</b><strong>{resources.energy}</strong></span></button><button className="template-resource template-population" type="button" onClick={() => showModuleNotice('Población')}><i>♙</i><span><b>POBLACIÓN</b><strong>{resources.population}</strong></span></button><button className="template-resource template-food" type="button" onClick={() => showModuleNotice('Comida')}><i>◆</i><span><b>COMIDA</b><strong>{resources.food}</strong></span></button><button className="template-resource template-dark" type="button" onClick={() => showModuleNotice('Materia oscura')}><i>✦</i><span><b>MATERIA OSCURA</b><strong>{resources.darkMatter}</strong></span></button></div>
        <div className="template-planet"><b>PLANETA</b><span>{planet}</span></div>
      </div>
    </header>

    <section className="template-planetstrip" aria-label="Planetas">
      <div className="template-planet-list">{orderedPlanets.length ? orderedPlanets.map((entry) => <button type="button" key={entry.id} className={`template-planet-chip${planet.includes(entry.name) || planet.includes(entry.coords) ? ' active' : ''}`} onClick={() => selectPlanet(entry)}><span className="template-planet-orb"/><span className="template-planet-name">{entry.name}</span><span className="template-planet-coords">{entry.coords}</span></button>) : <span className="template-planet-empty">Cargando planetas…</span>}</div>
      <div className="template-planet-settings-wrap"><button type="button" className={`template-planet-settings${planetSettingsOpen ? ' open' : ''}`} aria-label="Ordenar planetas" aria-expanded={planetSettingsOpen} onClick={() => setPlanetSettingsOpen((open) => !open)}>⚙</button>{planetSettingsOpen && <div className="template-planet-settings" role="menu"><button type="button" className={planetOrder === 'AZ' ? 'selected' : ''} onClick={() => { setPlanetOrder('AZ'); setPlanetSettingsOpen(false) }}>A-Z</button><button type="button" className={planetOrder === 'COORDS' ? 'selected' : ''} onClick={() => { setPlanetOrder('COORDS'); setPlanetSettingsOpen(false) }}>Coordenadas</button><button type="button" onClick={() => setPlanetSettingsOpen(false)}>Cancelar</button><button type="button" className="save" onClick={() => setPlanetSettingsOpen(false)}>Guardar</button></div>}</div>
    </section>

    <aside className="template-side" aria-label="Navegación del imperio"><section><h3>Imperio</h3><MenuButton label="Vista general" target="OVERVIEW" active={isActive('OVERVIEW')}/><MenuButton label="Recursos" target="OVERVIEW"/><MenuButton label="Instalaciones" target="EDIFICIOS" active={isActive('EDIFICIOS')}/></section><section><h3>Progresión</h3><MenuButton label="Oficiales" gold/><MenuButton label="Academia"/><MenuButton label="Formas de vida" target="EXPEDICIONES"/><MenuButton label="Investigación FV" target="INVESTIGACIÓN"/><MenuButton label="Civilización"/><MenuButton label="Investigación" target="INVESTIGACIÓN" active={isActive('INVESTIGACIÓN')}/></section><section><h3>Espacio</h3><MenuButton label="Flota" target="FLOTA" active={isActive('FLOTA')}/><MenuButton label="Hangar" target="HANGAR" active={isActive('HANGAR')}/><MenuButton label="Defensa" target="DEFENSAS" active={isActive('DEFENSAS')}/><MenuButton label="Galaxia" target="GALAXIA" active={isActive('GALAXIA')}/><MenuButton label="Expediciones" target="EXPEDICIONES" active={isActive('EXPEDICIONES')}/><MenuButton label="Mensajes" target="MENSAJES" active={isActive('MENSAJES')}/></section><section><h3>Comerciar</h3><MenuButton label="Mercader" gold/><MenuButton label="Importación / Exportación" gold/></section><section><h3>Cuenta</h3><MenuButton label="Perfil"/><MenuButton label="Opciones"/></section></aside>
    {moduleNotice && <div className="template-module-notice" role="status" onClick={() => setModuleNotice(null)}>{moduleNotice}</div>}
  </>
}
