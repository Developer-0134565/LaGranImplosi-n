import { supabase } from './lib/supabase'

const ADMIN_PLAYER_ID='60f1043a-2fa6-416c-80db-2a83215b5404'
const STYLE_ID='lgi-widget-toggle-css'

function installStyle(){
 if(document.getElementById(STYLE_ID))return
 const s=document.createElement('style');s.id=STYLE_ID
 s.textContent='.lgi-admin.widget-toggle{right:16px!important;bottom:16px!important;color:#ffd75e!important;border-color:#ffd75e66!important}.lgi-admin.secondary{display:none!important}#lgi-hide,#lgi-show{display:none!important}'
 document.head.appendChild(s)
}
async function isAdmin(){
 const{data,error}=await supabase.from('planets').select('players(id)').eq('is_destroyed',false)
 if(error)return false
 return(data??[]).some((p:any)=>(Array.isArray(p.players)?p.players:[p.players]).some((x:any)=>x?.id===ADMIN_PLAYER_ID))
}
async function readVisible(){
 const{data}=await supabase.from('dashboard_widgets').select('visible').eq('player_id',ADMIN_PLAYER_ID)
 return(data??[]).some((w:any)=>w.visible!==false)
}
async function toggle(button:HTMLButtonElement){
 button.disabled=true
 const currentlyVisible=await readVisible()
 await supabase.from('dashboard_widgets').update({visible:!currentlyVisible,updated_at:new Date().toISOString()}).eq('player_id',ADMIN_PLAYER_ID)
 location.reload()
}
async function boot(){
 installStyle()
 if(!(await isAdmin()))return
 const observer=new MutationObserver(async()=>{
   document.querySelectorAll('.lgi-admin.secondary').forEach(e=>e.remove())
   document.querySelector('#lgi-hide')?.remove()
   document.querySelector('#lgi-show')?.remove()
   let b=document.querySelector('.lgi-admin.widget-toggle') as HTMLButtonElement|null
   if(!b){
     const widgetsButton=document.querySelector('.lgi-admin:not(.secondary)') as HTMLElement|null
     if(!widgetsButton)return
     b=document.createElement('button');b.type='button';b.className='lgi-admin widget-toggle';b.textContent='🙈 OCULTAR / MOSTRAR'
     b.onclick=()=>void toggle(b!)
     document.body.appendChild(b)
   }
 })
 observer.observe(document.body,{childList:true,subtree:true})
 const widgetsButton=document.querySelector('.lgi-admin:not(.secondary)')
 if(widgetsButton){
   const b=document.createElement('button');b.type='button';b.className='lgi-admin widget-toggle';b.textContent='🙈 OCULTAR / MOSTRAR';b.onclick=()=>void toggle(b);document.body.appendChild(b)
 }
}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',()=>void boot(),{once:true});else void boot()
