const STORAGE_KEY='lagranimplosion-ui-scale-v5'
const DEFAULT_SCALE=1.75
const MIN_SCALE=0.75
const MAX_SCALE=1.75

function clampScale(value:number){return Math.min(MAX_SCALE,Math.max(MIN_SCALE,Math.round(value*20)/20))}
function readScale(){try{const raw=localStorage.getItem(STORAGE_KEY);if(raw===null)return DEFAULT_SCALE;const n=Number(raw);return Number.isFinite(n)?clampScale(n):DEFAULT_SCALE}catch{return DEFAULT_SCALE}}
function persistScale(value:number){try{localStorage.setItem(STORAGE_KEY,String(value))}catch{}}
function applyScale(scale:number){const value=clampScale(scale);document.documentElement.style.setProperty('--lgi-ui-scale',String(value));const game=document.querySelector<HTMLElement>('.game');if(game)game.style.zoom=String(value);const layer=document.getElementById('lagranimplosion-widget-layer') as HTMLElement|null;if(layer)layer.style.zoom=String(value);persistScale(value);return value}

function boot(){
 const value=readScale()
 applyScale(value)
 const applyWhenReady=()=>{
   const game=document.querySelector<HTMLElement>('.game')
   if(!game)return false
   game.style.zoom=String(value)
   return true
 }
 if(applyWhenReady())return
 const observer=new MutationObserver(()=>{if(applyWhenReady())observer.disconnect()})
 observer.observe(document.getElementById('root')||document.body,{childList:true,subtree:true})
}

if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot,{once:true});else boot()
