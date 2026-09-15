import { supabase } from './lib/supabase'

const ADMIN_PLAYER_ID = '60f1043a-2fa6-416c-80db-2a83215b5404'
const LAYER_ID = 'lagranimplosion-dashboard-widget-layer'

type WidgetType = 'image' | 'panel' | 'text' | 'button' | 'resource' | 'planet' | 'fleet' | 'galaxy'
type Widget = {
  id: string
  widget_type: WidgetType
  name: string
  x: number
  y: number
  width: number
  height: number
  z_index: number
  opacity: number
  visible: boolean
  config: Record<string, any>
}

const WIDGETS: Array<{ type: WidgetType; icon: string; label: string; description: string }> = [
  { type: 'image', icon: '🖼️', label: 'Imagen', description: 'Wallpaper, ilustración o textura' },
  { type: 'panel', icon: '▣', label: 'Panel', description: 'Contenedor visual configurable' },
  { type: 'text', icon: 'T', label: 'Texto', description: 'Título, texto libre o etiqueta' },
  { type: 'button', icon: '🔘', label: 'Botón', description: 'Botón visual o de navegación' },
  { type: 'resource', icon: '💰', label: 'Recursos', description: 'Metal, cristal, deuterio y energía' },
  { type: 'planet', icon: '🪐', label: 'Planeta', description: 'Planeta y coordenadas actuales' },
  { type: 'fleet', icon: '🚀', label: 'Flota', description: 'Movimientos y misiones' },
  { type: 'galaxy', icon: '🌌', label: 'Galaxia', description: 'Estado y espacio del universo' },
]

async function isAdmin() {
  const { data, error } = await supabase.from('planets').select('players(id)').eq('is_destroyed', false)
  if (error) return false
  return (data ?? []).some((p: any) => (Array.isArray(p.players) ? p.players : [p.players]).some((x: any) => x?.id === ADMIN_PLAYER_ID))
}

function ensureStyles() {
  if (document.getElementById('dashboard-widget-editor-css')) return
  const style = document.createElement('style')
  style.id = 'dashboard-widget-editor-css'
  style.textContent = `
#${LAYER_ID}{position:fixed;inset:0;z-index:0;pointer-events:none;overflow:hidden}
.lgi-widget{position:absolute;box-sizing:border-box;overflow:hidden;pointer-events:none;transform-origin:top left}
.lgi-widget-image img{width:100%;height:100%;display:block;object-fit:cover}
.lgi-widget-panel{width:100%;height:100%;border:1px solid rgba(126,180,255,.25);border-radius:12px;background:rgba(13,19,29,.72);backdrop-filter:blur(10px);box-shadow:0 8px 28px rgba(0,0,0,.45)}
.lgi-widget-text{width:100%;height:100%;padding:12px;color:#d7e3f4;font:700 22px/1.15 system-ui;display:flex;align-items:center;white-space:pre-wrap}
.lgi-widget-button{margin:0;border:1px solid rgba(53,208,255,.4);border-radius:8px;background:rgba(16,35,50,.94);color:#d7e3f4;padding:10px 16px;font:700 13px system-ui;white-space:nowrap}
.lgi-widget-data{width:100%;height:100%;box-sizing:border-box;padding:12px;border:1px solid rgba(126,180,255,.2);border-radius:10px;background:rgba(13,19,29,.78);color:#d7e3f4;font:12px/1.55 system-ui}
.lgi-widget-data strong{display:block;color:#35d0ff;font-size:15px;margin-bottom:5px}
.lgi-widget-admin-button{position:fixed;right:18px;bottom:18px;z-index:99999;padding:10px 14px;border:1px solid rgba(53,208,255,.45);border-radius:8px;background:rgba(10,16,26,.95);color:#35d0ff;cursor:pointer;font:700 12px system-ui;letter-spacing:.08em}
.lgi-widget-toolbar{position:fixed;right:18px;bottom:62px;z-index:100000;width:390px;max-height:calc(100vh - 90px);overflow:auto;padding:16px;border:1px solid rgba(53,208,255,.4);border-radius:12px;background:rgba(10,16,26,.98);color:#d7e3f4;box-shadow:0 14px 40px rgba(0,0,0,.65);font:13px/1.4 system-ui;backdrop-filter:blur(14px)}
.lgi-widget-toolbar h3{margin:0 0 5px;color:#35d0ff}.lgi-widget-toolbar .sub{color:#8fa3bd;margin-bottom:12px}.lgi-widget-toolbar label{display:block;margin:9px 0 4px;color:#8fa3bd;font-size:11px}.lgi-widget-toolbar input,.lgi-widget-toolbar select,.lgi-widget-toolbar textarea{width:100%;box-sizing:border-box;padding:8px;background:#0d131d;color:#d7e3f4;border:1px solid rgba(126,180,255,.2);border-radius:7px}.lgi-widget-toolbar textarea{min-height:65px;resize:vertical}.lgi-widget-toolbar input[type=range]{padding:0}.lgi-widget-toolbar .grid{display:grid;grid-template-columns:1fr 1fr;gap:7px}.lgi-widget-toolbar .row{display:flex;gap:7px;margin-top:10px}.lgi-widget-toolbar button{flex:1;padding:8px;border:1px solid rgba(53,208,255,.35);border-radius:7px;background:#102332;color:#d7e3f4;cursor:pointer;font-weight:700}.lgi-widget-toolbar button:hover{border-color:#35d0ff}.lgi-widget-palette{display:grid;grid-template-columns:1fr 1fr;gap:7px;margin-bottom:14px}.lgi-widget-palette button{text-align:left;min-height:58px}.lgi-widget-list{border-top:1px solid rgba(126,180,255,.12);margin-top:12px;padding-top:10px}.lgi-widget-list button{width:100%;text-align:left;margin:3px 0}.lgi-widget-selected{outline:2px solid #35d0ff!important;outline-offset:-2px}
` 
  document.head.appendChild(style)
}

function layer() {
  let el = document.getElementById(LAYER_ID)
  if (!el) { el = document.createElement('div'); el.id = LAYER_ID; document.body.prepend(el) }
  return el
}

async function loadWidgets(): Promise<Widget[]> {
  const { data } = await supabase.from('dashboard_widgets').select('id,widget_type,name,x,y,width,height,z_index,opacity,visible,config').eq('player_id', ADMIN_PLAYER_ID).order('z_index', { ascending: true })
  return (data ?? []) as Widget[]
}

function defaultWidget(type: WidgetType): Partial<Widget> {
  const defaults: Record<WidgetType, Partial<Widget>> = {
    image: { name: 'Imagen', width: 600, height: 340, config: { url: '', fit: 'cover' } },
    panel: { name: 'Panel', width: 360, height: 180, config: { title: 'PANEL' } },
    text: { name: 'Texto', width: 320, height: 80, config: { text: 'LA GRAN IMPLOSIÓN', fontSize: 22 } },
    button: { name: 'Botón', width: 170, height: 44, config: { text: 'BOTÓN', action: '' } },
    resource: { name: 'Recursos', width: 270, height: 150, config: { title: 'RECURSOS' } },
    planet: { name: 'Planeta', width: 280, height: 120, config: { title: 'PLANETA' } },
    fleet: { name: 'Flota', width: 320, height: 150, config: { title: 'MOVIMIENTOS DE FLOTA' } },
    galaxy: { name: 'Galaxia', width: 320, height: 150, config: { title: 'UNIVERSO' } },
  }
  return { ...defaults[type], x: 40 + Math.random() * 80, y: 100 + Math.random() * 80, z_index: 10, opacity: 1, visible: true }
}

function renderWidget(w: Widget) {
  const root = layer()
  let el = root.querySelector(`[data-widget-id="${w.id}"]`) as HTMLElement | null
  if (!el) { el = document.createElement('div'); root.appendChild(el) }
  el.dataset.widgetId = w.id
  el.className = `lgi-widget lgi-widget-${w.widget_type}`
  el.style.left = `${w.x}px`; el.style.top = `${w.y}px`; el.style.width = `${w.width}px`; el.style.height = `${w.height}px`; el.style.zIndex = String(w.z_index); el.style.opacity = String(w.opacity)
  const c = w.config ?? {}
  if (w.widget_type === 'image') el.innerHTML = c.url ? `<img src="${String(c.url).replaceAll('"','&quot;')}" alt="${w.name}">` : ''
  else if (w.widget_type === 'panel') el.innerHTML = `<div class="lgi-widget-panel"></div>`
  else if (w.widget_type === 'text') { el.textContent = String(c.text ?? 'Texto'); el.style.fontSize = `${Number(c.fontSize ?? 22)}px` }
  else if (w.widget_type === 'button') el.innerHTML = `<button class="lgi-widget-button">${String(c.text ?? 'BOTÓN')}</button>`
  else { el.innerHTML = `<div class="lgi-widget-data"><strong>${String(c.title ?? w.name)}</strong>${w.widget_type === 'resource' ? 'METAL · CRISTAL · DEUTERIO · ENERGÍA' : w.widget_type === 'planet' ? 'Planeta · Coordenadas · Producción' : w.widget_type === 'fleet' ? 'Misiones · Llegadas · Retornos' : 'Galaxias · Sistemas · Espacio disponible'}</div>` }
}

async function createWidget(type: WidgetType) {
  const d = defaultWidget(type)
  const { data, error } = await supabase.from('dashboard_widgets').insert({ player_id: ADMIN_PLAYER_ID, widget_type: type, name: d.name, x: d.x, y: d.y, width: d.width, height: d.height, z_index: d.z_index, opacity: d.opacity, visible: true, config: d.config }).select('id,widget_type,name,x,y,width,height,z_index,opacity,visible,config').single()
  if (error) { alert(error.message); return null }
  return data as Widget
}

function openEditor(initial: Widget[], rerender: (w: Widget[]) => void) {
  if (document.querySelector('.lgi-widget-toolbar')) return
  const panel = document.createElement('section'); panel.className = 'lgi-widget-toolbar'
  panel.innerHTML = `<h3>🧩 CONSTRUCTOR DE INTERFAZ</h3><div class="sub">Widgets independientes · no modifican el layout React</div><div class="lgi-widget-palette"></div><div class="lgi-widget-list"><b>ELEMENTOS ACTUALES</b><div class="widget-list-items"></div></div><div class="row"><button class="widget-close">CERRAR</button></div>`
  document.body.appendChild(panel)
  const palette = panel.querySelector('.lgi-widget-palette') as HTMLElement
  WIDGETS.forEach(item => { const b = document.createElement('button'); b.innerHTML = `${item.icon} <b>${item.label}</b><br><small>${item.description}</small>`; b.onclick = async () => { const created = await createWidget(item.type); if (created) { initial.push(created); renderWidget(created); refreshList() } }; palette.appendChild(b) })
  const list = panel.querySelector('.widget-list-items') as HTMLElement
  function refreshList() { list.innerHTML = ''; initial.forEach(w => { const b = document.createElement('button'); b.textContent = `${w.visible ? '👁' : '🚫'} ${w.name} [${w.widget_type}]`; b.onclick = () => openProperties(w, initial, rerender, refreshList); list.appendChild(b) }) }
  panel.querySelector('.widget-close')?.addEventListener('click', () => panel.remove())
  refreshList()
}

function openProperties(w: Widget, all: Widget[], rerender: (w: Widget[]) => void, refreshList: () => void) {
  const old = document.querySelector('.lgi-widget-properties'); old?.remove()
  const p = document.createElement('section'); p.className = 'lgi-widget-toolbar lgi-widget-properties'; p.style.right = '425px'
  p.innerHTML = `<h3>⚙️ ${w.name}</h3><label>Nombre</label><input class="name"><div class="grid"><div><label>X</label><input class="x" type="number"></div><div><label>Y</label><input class="y" type="number"></div><div><label>Ancho</label><input class="width" type="number"></div><div><label>Alto</label><input class="height" type="number"></div><div><label>Z-index</label><input class="z" type="number"></div><div><label>Opacidad</label><input class="opacity" type="number" min="0" max="1" step=".05"></div></div><label>Contenido / título</label><textarea class="text"></textarea><label>URL de imagen (solo Imagen)</label><input class="url" type="url"><div class="row"><button class="save">APLICAR</button><button class="delete">ELIMINAR</button><button class="close">CERRAR</button></div>`
  document.body.appendChild(p)
  ;(['name','x','y','width','height','z','opacity'] as const).forEach(k => { (p.querySelector(`.${k}`) as HTMLInputElement).value = String((w as any)[k]) })
  ;(p.querySelector('.text') as HTMLTextAreaElement).value = String(w.config?.text ?? w.config?.title ?? w.name)
  ;(p.querySelector('.url') as HTMLInputElement).value = String(w.config?.url ?? '')
  p.querySelector('.save')?.addEventListener('click', async () => {
    const config = { ...w.config, text: (p.querySelector('.text') as HTMLTextAreaElement).value, title: (p.querySelector('.text') as HTMLTextAreaElement).value, url: (p.querySelector('.url') as HTMLInputElement).value }
    const patch = { name: (p.querySelector('.name') as HTMLInputElement).value, x: Number((p.querySelector('.x') as HTMLInputElement).value), y: Number((p.querySelector('.y') as HTMLInputElement).value), width: Number((p.querySelector('.width') as HTMLInputElement).value), height: Number((p.querySelector('.height') as HTMLInputElement).value), z_index: Number((p.querySelector('.z') as HTMLInputElement).value), opacity: Number((p.querySelector('.opacity') as HTMLInputElement).value), config, updated_at: new Date().toISOString() }
    const { error } = await supabase.from('dashboard_widgets').update(patch).eq('id', w.id)
    if (error) { alert(error.message); return }
    Object.assign(w, patch); renderWidget(w); refreshList(); p.remove(); rerender(all)
  })
  p.querySelector('.delete')?.addEventListener('click', async () => { if (!confirm('¿Eliminar este widget?')) return; const { error } = await supabase.from('dashboard_widgets').delete().eq('id', w.id); if (error) { alert(error.message); return }; document.querySelector(`[data-widget-id="${w.id}"]`)?.remove(); const i = all.findIndex(x => x.id === w.id); if (i >= 0) all.splice(i, 1); refreshList(); p.remove(); rerender(all) })
  p.querySelector('.close')?.addEventListener('click', () => p.remove())
}

async function boot() {
  ensureStyles()
  if (!(await isAdmin())) return
  const widgets = await loadWidgets()
  widgets.filter(w => w.visible).forEach(renderWidget)
  const button = document.createElement('button'); button.className = 'lgi-widget-admin-button'; button.textContent = '🧩 WIDGETS'
  button.onclick = () => openEditor(widgets, () => widgets.filter(w => w.visible).forEach(renderWidget))
  document.body.appendChild(button)
}

void boot()
