const STORAGE_KEY = 'lagranimplosion-typography-v2'

type Settings = {
  global:number; title:number; heading:number; body:number; number:number; button:number
  titleFont:string; headingFont:string; bodyFont:string; numberFont:string; buttonFont:string
}

const fonts = ['Orbitron','Audiowide','Michroma','Oxanium','Rajdhani','Exo 2','Space Grotesk','Inter','Share Tech Mono','JetBrains Mono','Chakra Petch','Electrolize','Russo One','Teko','Titillium Web','Unica One','Zen Dots','Space Mono']
const defaults:Settings = {global:1,title:1,heading:1,body:1,number:1,button:1,titleFont:'Orbitron',headingFont:'Rajdhani',bodyFont:'Exo 2',numberFont:'Share Tech Mono',buttonFont:'Oxanium'}
const clamp=(n:number)=>Math.min(1.45,Math.max(.75,Math.round(n*20)/20))
function read():Settings { try { const x=JSON.parse(localStorage.getItem(STORAGE_KEY)||'null'); return {...defaults,...x} } catch { return {...defaults} } }
function save(s:Settings){try{localStorage.setItem(STORAGE_KEY,JSON.stringify(s))}catch{}}
function apply(s:Settings){
 const r=document.documentElement
 r.style.setProperty('--text-scale',String(clamp(s.global)))
 r.style.setProperty('--text-title-scale',String(clamp(s.title)))
 r.style.setProperty('--text-heading-scale',String(clamp(s.heading)))
 r.style.setProperty('--text-body-scale',String(clamp(s.body)))
 r.style.setProperty('--text-number-scale',String(clamp(s.number)))
 r.style.setProperty('--text-button-scale',String(clamp(s.button)))
 r.style.setProperty('--font-title',`"${s.titleFont}",sans-serif`)
 r.style.setProperty('--font-heading',`"${s.headingFont}",sans-serif`)
 r.style.setProperty('--font-body',`"${s.bodyFont}",sans-serif`)
 r.style.setProperty('--font-number',`"${s.numberFont}",monospace`)
 r.style.setProperty('--font-button',`"${s.buttonFont}",sans-serif`)
 save(s)
}
function install(){
 if(document.getElementById('typography-controls'))return
 let s=read(); apply(s)
 const panel=document.createElement('aside'); panel.id='typography-controls'; panel.className='typography-controls'
 const roles:[keyof Pick<Settings,'title'|'heading'|'body'|'number'|'button'>,string][]=[['title','TÍTULO'],['heading','ENCABEZADOS'],['body','TEXTO'],['number','NÚMEROS'],['button','BOTONES']]
 panel.innerHTML=`<div class="typography-head"><strong>TIPOGRAFÍA / ESCALA</strong><button type="button" data-close>×</button></div><p>Escala independiente por tipo. Se aplica al shell actual sin romper las plantillas.</p><label class="type-row"><span>GLOBAL</span><input data-size="global" type="range" min="0.75" max="1.45" step="0.05" value="${s.global}"><output data-out="global">${Math.round(s.global*100)}%</output></label>${roles.map(([key,label])=>`<label class="type-row"><span>${label}</span><input data-size="${key}" type="range" min="0.75" max="1.45" step="0.05" value="${s[key]}"><output data-out="${key}">${Math.round(s[key]*100)}%</output></label>`).join('')}<div class="type-fonts">${roles.map(([key,label])=>`<label><span>${label}</span><select data-font="${key}">${fonts.map(f=>`<option ${s[key+'Font' as keyof Settings]===f?'selected':''}>${f}</option>`).join('')}</select></label>`).join('')}</div><button type="button" class="typography-reset" data-reset>RESTABLECER</button>`
 document.body.appendChild(panel)
 const launcher=document.createElement('button'); launcher.id='typography-launcher'; launcher.className='typography-launcher'; launcher.type='button'; launcher.textContent='Aa'; launcher.title='Tamaño y fuentes'; document.body.appendChild(launcher)
 launcher.onclick=()=>panel.classList.toggle('open'); panel.querySelector('[data-close]')!.addEventListener('click',()=>panel.classList.remove('open'))
 panel.querySelectorAll<HTMLInputElement>('input[data-size]').forEach(i=>i.addEventListener('input',()=>{const k=i.dataset.size as keyof Settings;s={...s,[k]:Number(i.value)};const out=panel.querySelector<HTMLOutput>(`[data-out="${k}"]`);if(out)out.value=`${Math.round(Number(i.value)*100)}%`;apply(s)}))
 panel.querySelectorAll<HTMLSelectElement>('select[data-font]').forEach(i=>i.addEventListener('change',()=>{const k=i.dataset.font as string;s={...s,[`${k}Font`]:i.value};apply(s)}))
 panel.querySelector('[data-reset]')!.addEventListener('click',()=>{s={...defaults};apply(s);panel.remove();launcher.remove();install()})
}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',install);else install()
