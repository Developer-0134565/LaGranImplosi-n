import { supabase } from './lib/supabase'

type LayoutBox = { x:number; y:number; w:number; h:number }
const KEY='lagranimplosion-admin-layout-v2'
const ADMIN_PLAYER_ID='60f1043a-2fa6-416c-80db-2a83215b5404'
const targets=[['CABECERA','.neo-header'],['MENÚ','.neo-sidebar'],['PLANETA','.neo-planetbar'],['CONTENIDO','.neo-main'],['PANEL','.neo-panel'],['BOTÓN','.neo-nav-item']] as const
function read():Record<string,LayoutBox>{try{return JSON.parse(localStorage.getItem(KEY)||'{}') as Record<string,LayoutBox>}catch{return{}}}
function save(v:Record<string,LayoutBox>){localStorage.setItem(KEY,JSON.stringify(v))}

async function checkAdmin(){const{data,error}=await supabase.from('planets').select('player_id').eq('player_id',ADMIN_PLAYER_ID).eq('is_destroyed',false).limit(1);return!error&&!!data?.length}

function installAdminUi(){
 if(document.body.dataset.adminInstalled)return
 document.body.dataset.adminInstalled='1'
 const store=read();const bar=document.createElement('div');bar.id='admin-design-toolbar';bar.innerHTML='<strong>DISEÑO ADMIN</strong><span>Editor seguro · no rompe la estructura</span><button data-action="edit">EDITAR INTERFAZ</button><button data-action="reset">RESTABLECER</button>';document.body.appendChild(bar)
 const canvas=document.createElement('div');canvas.id='admin-layout-overlay';document.body.appendChild(canvas);let editing=false
 const apply=()=>{targets.forEach(([,selector])=>{document.querySelectorAll(selector).forEach((node,index)=>{const el=node as HTMLElement;el.style.removeProperty('transform');el.style.removeProperty('transform-origin');const key=`${selector}#${index}`;const saved=store[key];if(!saved)return;const base=el.getBoundingClientRect();if(base.width<1||base.height<1)return;const sx=saved.w/base.width;const sy=saved.h/base.height;el.style.transformOrigin='top left';el.style.transform=`translate(${saved.x-base.left}px,${saved.y-base.top}px) scale(${sx},${sy})`})})}
 const clear=()=>{canvas.replaceChildren()}
 const draw=()=>{clear();if(!editing)return;apply();targets.forEach(([label,selector])=>{document.querySelectorAll(selector).forEach((node,index)=>{const el=node as HTMLElement;const r=el.getBoundingClientRect();if(r.width<4||r.height<4)return;const key=`${selector}#${index}`;const box=document.createElement('button');box.type='button';box.className='admin-layout-box';box.dataset.key=key;box.style.left=`${r.left}px`;box.style.top=`${r.top}px`;box.style.width=`${r.width}px`;box.style.height=`${r.height}px`;box.innerHTML=`<span>${label}</span><i class="admin-resize-handle" aria-hidden="true"></i>`;canvas.appendChild(box);let mode:'move'|'resize'|null=null;let sx=0,sy=0,sl=0,st=0,sw=0,sh=0;const move=(e:PointerEvent)=>{if(!mode)return;if(mode==='move'){box.style.left=`${Math.max(0,sl+e.clientX-sx)}px`;box.style.top=`${Math.max(0,st+e.clientY-sy)}px`}else{box.style.width=`${Math.max(80,sw+e.clientX-sx)}px`;box.style.height=`${Math.max(28,sh+e.clientY-sy)}px`}};const up=()=>{if(!mode)return;const rr=box.getBoundingClientRect();store[key]={x:Math.round(rr.left),y:Math.round(rr.top),w:Math.round(rr.width),h:Math.round(rr.height)};save(store);mode=null;window.removeEventListener('pointermove',move);apply();draw()};box.addEventListener('pointerdown',e=>{e.preventDefault();e.stopPropagation();mode=(e.target as HTMLElement).closest('.admin-resize-handle')?'resize':'move';sx=e.clientX;sy=e.clientY;const rr=box.getBoundingClientRect();sl=rr.left;st=rr.top;sw=rr.width;sh=rr.height;window.addEventListener('pointermove',move);window.addEventListener('pointerup',up,{once:true})})})})}
 const toggle=()=>{editing=!editing;document.body.classList.toggle('admin-editing',editing);bar.querySelector('[data-action="edit"]')!.textContent=editing?'SALIR DISEÑO':'EDITAR INTERFAZ';if(editing)draw();else{clear();apply()}}
 bar.addEventListener('click',e=>{const b=(e.target as HTMLElement).closest('button') as HTMLButtonElement|null;if(!b)return;if(b.dataset.action==='edit')toggle();if(b.dataset.action==='reset'){localStorage.removeItem(KEY);location.reload()}})
 window.addEventListener('resize',()=>{apply();if(editing)draw()});const root=document.getElementById('root');if(root)new MutationObserver(()=>{apply();if(editing)draw()}).observe(root,{childList:true,subtree:true});apply()
}
async function install(){if(document.body.dataset.adminInstalled)return;for(let attempt=0;attempt<8;attempt++){if(await checkAdmin()){document.body.classList.add('admin-mode');installAdminUi();return}await new Promise(r=>window.setTimeout(r,500))}}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',()=>{void install()});else void install()
