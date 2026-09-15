import { useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'
import './styles/galaxy-view.css'

type GalaxyMeta = {
  galaxy:number
  system_count:number
  is_special:boolean
  next_system_expansion_at:string|null
}

type GalaxyPlanet = {
  id:string
  name:string
  galaxy:number
  system:number
  position:number
  is_homeworld:boolean
  is_destroyed:boolean
  player_id:string
  players?:{id:string;username:string;is_guest:boolean}|{id:string;username:string;is_guest:boolean}[]|null
}

type Props = {
  homeworld?: { galaxy:number; system:number; position:number }
  playerId?: string
}

const POSITIONS=15
const FALLBACK_GALAXIES=100

function ownerOf(planet:GalaxyPlanet){
  const owner=Array.isArray(planet.players)?planet.players[0]:planet.players
  return owner?.username??'Jugador desconocido'
}

function clamp(value:number,min:number,max:number){return Math.min(max,Math.max(min,value))}

function formatDate(value:string|null){
  if(!value)return '—'
  const date=new Date(value)
  if(Number.isNaN(date.getTime()))return '—'
  return date.toLocaleString('es-ES',{day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit'})
}

export default function GalaxyView({homeworld,playerId}:Props){
  const [galaxy,setGalaxy]=useState(Math.max(1,homeworld?.galaxy??1))
  const [system,setSystem]=useState(Math.max(1,homeworld?.system??1))
  const [galaxyInput,setGalaxyInput]=useState(String(Math.max(1,homeworld?.galaxy??1)))
  const [systemInput,setSystemInput]=useState(String(Math.max(1,homeworld?.system??1)))
  const [meta,setMeta]=useState<GalaxyMeta|null>(null)
  const [planets,setPlanets]=useState<GalaxyPlanet[]>([])
  const [loading,setLoading]=useState(false)
  const [error,setError]=useState<string|null>(null)
  const [selected,setSelected]=useState<GalaxyPlanet|null>(null)

  useEffect(()=>{
    if(!homeworld)return
    setGalaxy(Math.max(1,homeworld.galaxy))
    setSystem(Math.max(1,homeworld.system))
    setGalaxyInput(String(Math.max(1,homeworld.galaxy)))
    setSystemInput(String(Math.max(1,homeworld.system)))
  },[homeworld?.galaxy,homeworld?.system])

  useEffect(()=>{
    let active=true
    async function load(){
      setLoading(true)
      setError(null)
      setSelected(null)
      const [{data:galaxyRow,error:ge},{data:planetRows,error:pe}]=await Promise.all([
        supabase.from('universe_galaxies').select('galaxy,system_count,is_special,next_system_expansion_at').eq('galaxy',galaxy).maybeSingle(),
        supabase.from('planets').select('id,name,galaxy,system,position,is_homeworld,is_destroyed,player_id,players(id,username,is_guest)').eq('galaxy',galaxy).eq('system',system).eq('is_destroyed',false).order('position')
      ])
      if(!active)return
      if(ge){setError(ge.message);setMeta(null)}
      else setMeta((galaxyRow as GalaxyMeta|null)??null)
      if(pe){setError(pe.message);setPlanets([])}
      else setPlanets((planetRows??[]) as GalaxyPlanet[])
      setLoading(false)
    }
    void load()
    return()=>{active=false}
  },[galaxy,system])

  const maxSystem=meta?.system_count??(galaxy===1?Math.max(1,homeworld?.system??1):0)
  const rows=useMemo(()=>Array.from({length:POSITIONS},(_,i)=>i+1).map(position=>({position,planet:planets.find(p=>p.position===position)??null})),[planets])
  const occupied=planets.length

  function go(nextGalaxy:number,nextSystem:number){
    const g=Math.max(1,nextGalaxy)
    const knownMax=meta?.system_count
    const s=knownMax&&knownMax>0?clamp(nextSystem,1,knownMax):Math.max(1,nextSystem)
    setGalaxy(g);setSystem(s);setGalaxyInput(String(g));setSystemInput(String(s))
  }

  function submitCoordinates(e:React.FormEvent){
    e.preventDefault()
    const g=Number.parseInt(galaxyInput,10)
    const s=Number.parseInt(systemInput,10)
    if(!Number.isInteger(g)||g<1||g>FALLBACK_GALAXIES){setError(`Galaxia válida: 1-${FALLBACK_GALAXIES}.`);return}
    if(!Number.isInteger(s)||s<1){setError('El sistema debe ser un número positivo.');return}
    go(g,s)
  }

  const ownPlanet=planets.find(p=>p.player_id===playerId)

  return <div className="neo-main-view galaxy-view">
    <div className="neo-section-head">
      <div>
        <span className="neo-eyebrow">UNIVERSO · CARTOGRAFÍA</span>
        <h1>Galaxia</h1>
        <p>Explora una galaxia y un sistema sin inventar posiciones que todavía no existen.</p>
      </div>
      <span className="neo-counter">{occupied}/{POSITIONS} OCUPADAS</span>
    </div>

    <section className="neo-panel galaxy-controls">
      <form onSubmit={submitCoordinates} className="galaxy-coordinate-form">
        <label><span>GALAXIA</span><input inputMode="numeric" value={galaxyInput} onChange={e=>setGalaxyInput(e.target.value.replace(/[^0-9]/g,''))}/></label>
        <label><span>SISTEMA</span><input inputMode="numeric" value={systemInput} onChange={e=>setSystemInput(e.target.value.replace(/[^0-9]/g,''))}/></label>
        <button className="neo-button" type="submit">IR A COORDENADAS</button>
      </form>
      <div className="galaxy-stepper">
        <button type="button" className="neo-button secondary" onClick={()=>go(galaxy-1,1)} disabled={galaxy<=1}>◀ GALAXIA</button>
        <button type="button" className="neo-button secondary" onClick={()=>go(galaxy,system-1)} disabled={system<=1}>◀ SISTEMA</button>
        <strong>[{galaxy}:{system}]</strong>
        <button type="button" className="neo-button secondary" onClick={()=>go(galaxy,system+1)} disabled={maxSystem>0&&system>=maxSystem}>SISTEMA ▶</button>
        <button type="button" className="neo-button secondary" onClick={()=>go(galaxy+1,1)} disabled={galaxy>=FALLBACK_GALAXIES}>GALAXIA ▶</button>
      </div>
    </section>

    <section className="neo-panel galaxy-system-head">
      <div><strong>GALAXIA {galaxy} · SISTEMA {system}</strong><span>{meta?.is_special?'GALAXIA ESPECIAL':'GALAXIA NORMAL'} · {meta?.system_count??'—'} SISTEMAS GENERADOS</span></div>
      <small>{meta?.next_system_expansion_at?`PRÓXIMA EXPANSIÓN · ${formatDate(meta.next_system_expansion_at)}`:'SIN PRÓXIMA EXPANSIÓN PROGRAMADA'}</small>
    </section>

    {error&&<div className="global-notice error">{error}<button type="button" onClick={()=>setError(null)}>×</button></div>}
    {loading?<div className="loading-line">ESCANEANDO SISTEMA {galaxy}:{system}…</div>:<section className="neo-panel galaxy-table-panel">
      <div className="galaxy-table-head"><span>POS.</span><span>PLANETA</span><span>JUGADOR</span><span>ESTADO</span><span>ACCIÓN</span></div>
      <div className="galaxy-rows">
        {rows.map(({position,planet})=>{
          const isOwn=Boolean(planet&&planet.player_id===playerId)
          return <button type="button" key={position} className={`galaxy-row${isOwn?' own':''}${selected?.id===planet?.id?' selected':''}`} onClick={()=>planet&&setSelected(planet)} disabled={!planet}>
            <span className="galaxy-position">{position}</span>
            <span className="galaxy-planet">{planet?<><strong>{planet.name}</strong>{planet.is_homeworld&&<small>PLANETA PRINCIPAL</small>}</>:<em>Espacio vacío</em>}</span>
            <span>{planet?ownerOf(planet):'—'}</span>
            <span>{planet?(isOwn?'TU PLANETA':'OCUPADO'):'LIBRE'}</span>
            <span>{planet?'VER':'—'}</span>
          </button>
        })}
      </div>
    </section>}

    {selected&&<aside className="neo-panel galaxy-target-panel">
      <div><span className="neo-eyebrow">OBJETIVO SELECCIONADO</span><h2>{selected.name}</h2><p>[{selected.galaxy}:{selected.system}:{selected.position}] · {ownerOf(selected)}</p></div>
      <div className="galaxy-target-actions">
        {selected.player_id===playerId&&ownPlanet?<span className="galaxy-info">Este planeta pertenece a tu imperio.</span>:<>
          <button type="button" className="neo-button" onClick={()=>setError('El espionaje se ejecutará desde el módulo de flota cuando esté disponible para esta vista.')}>ESPIONAJE</button>
          <button type="button" className="neo-button" onClick={()=>setError('Las misiones de flota se mantienen en su módulo operativo; aquí solo se selecciona el objetivo.')}>FLOTA</button>
        </>}
      </div>
    </aside>}
  </div>
}
