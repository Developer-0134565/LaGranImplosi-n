import { createRoot, type Root } from 'react-dom/client'
import GalaxyView from './GalaxyView'
import { supabase } from './lib/supabase'

let root:Root|null=null
let host:HTMLElement|null=null
let mounting=false

async function mountGalaxy(){
  if(mounting)return
  const active=document.querySelector('.neo-nav-item.active b')?.textContent?.trim().toUpperCase()
  if(active!=='GALAXIA')return
  const view=document.querySelector<HTMLElement>('.neo-main-view')
  if(!view||view.dataset.galaxyMounted==='1')return
  mounting=true
  try{
    const {data}=await supabase.from('planets').select('universe_id,galaxy,system,position,players(id)').eq('is_homeworld',true).eq('is_destroyed',false).limit(1).maybeSingle()
    const player=Array.isArray(data?.players)?data?.players[0]:data?.players
    view.replaceChildren()
    view.dataset.galaxyMounted='1'
    host=document.createElement('div')
    host.className='galaxy-react-host'
    view.appendChild(host)
    root?.unmount()
    root=createRoot(host)
    root.render(<GalaxyView homeworld={data??undefined} playerId={(player as {id:string}|null|undefined)?.id} universeId={data?.universe_id as string|undefined}/>)
  }finally{mounting=false}
}

function boot(){
  const observer=new MutationObserver(()=>void mountGalaxy())
  observer.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['class']})
  void mountGalaxy()
}

if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot,{once:true})
else boot()
