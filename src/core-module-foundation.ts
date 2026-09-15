const CORE_MODULES:Record<string,string>={
  OVERVIEW:'homeworld',
  PLANETAS:'planets',
  EDIFICIOS:'buildings',
  INVESTIGACIÓN:'research',
  HANGAR:'shipyard',
  DEFENSAS:'defense',
  FLOTA:'fleet',
  GALAXIA:'galaxy',
  EXPEDICIONES:'expedition',
}

const STYLE_ID='lgi-core-module-foundation-style'

function installStyle(){
  if(document.getElementById(STYLE_ID))return
  const style=document.createElement('style')
  style.id=STYLE_ID
  style.textContent=`
    .neo-main-view[data-core-module]{min-width:0}
    .neo-main-view[data-core-module] .neo-section-head{position:relative}
    .neo-main-view[data-core-module] .neo-section-head:after{content:'MÓDULO ACTIVO';position:absolute;right:12px;bottom:7px;font:600 6px var(--font-number,monospace);letter-spacing:.12em;color:var(--neo-faint,#5c6f88);opacity:.8}
    .neo-main-view[data-core-module='homeworld'] .neo-actions button,
    .neo-main-view[data-core-module='buildings'] .neo-definition .neo-button,
    .neo-main-view[data-core-module='research'] .neo-definition .neo-button,
    .neo-main-view[data-core-module='shipyard'] .neo-definition .neo-button,
    .neo-main-view[data-core-module='defense'] .neo-definition .neo-button{min-height:30px}
    .neo-main-view[data-core-module='buildings'] .neo-definition,
    .neo-main-view[data-core-module='research'] .neo-definition,
    .neo-main-view[data-core-module='shipyard'] .neo-definition,
    .neo-main-view[data-core-module='defense'] .neo-definition{display:flex;flex-direction:column;min-height:150px}
    .neo-main-view[data-core-module='buildings'] .neo-definition p,
    .neo-main-view[data-core-module='research'] .neo-definition p,
    .neo-main-view[data-core-module='shipyard'] .neo-definition p,
    .neo-main-view[data-core-module='defense'] .neo-definition p{flex:1}
    .neo-main-view[data-core-module='fleet'] .neo-movement-list{min-height:120px}
    .neo-main-view[data-core-module='planets'] .neo-planet-card{display:flex;flex-direction:column}
    .neo-main-view[data-core-module='planets'] .neo-planet-card .neo-button{margin-top:auto}
    .neo-main-view[data-core-module='homeworld'] .neo-actions button:focus-visible,
    .neo-main-view[data-core-module='buildings'] button:focus-visible,
    .neo-main-view[data-core-module='research'] button:focus-visible,
    .neo-main-view[data-core-module='shipyard'] button:focus-visible,
    .neo-main-view[data-core-module='defense'] button:focus-visible,
    .neo-main-view[data-core-module='fleet'] button:focus-visible{outline:2px solid var(--neo-accent,#35d0ff);outline-offset:2px}
    @media(max-width:760px){.neo-main-view[data-core-module] .neo-section-head:after{position:static;display:block;margin-top:5px}.neo-main-view[data-core-module='fleet'] .neo-movement-list{overflow:auto}}
  `
  document.head.appendChild(style)
}

function annotate(){
  const active=document.querySelector<HTMLElement>('.neo-nav-item.active:not(.neo-nav-extra)')
  const label=active?.querySelector('b')?.textContent?.trim().toUpperCase()
  const module=label?CORE_MODULES[label]:undefined
  const view=document.querySelector<HTMLElement>('.neo-main-view:not(.galaxy-view)')
  if(view){
    if(module)view.dataset.coreModule=module
    else delete view.dataset.coreModule
  }
  document.querySelectorAll<HTMLElement>('.neo-nav-item:not(.neo-nav-extra)').forEach(button=>{
    const text=button.querySelector('b')?.textContent?.trim()
    if(text)button.setAttribute('aria-label',text)
  })
}

function boot(){
  installStyle()
  annotate()
  const observer=new MutationObserver(annotate)
  observer.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['class']})
}

if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot,{once:true})
else boot()
