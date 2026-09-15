import { supabase } from './lib/supabase'

const ADMIN_PLAYER_ID = '60f1043a-2fa6-416c-80db-2a83215b5404'
const WIDGET_LAYER_ID = 'lagranimplosion-dashboard-widget-layer'

async function isAdmin(): Promise<boolean> {
  const { data, error } = await supabase.from('planets').select('id, players(id)').eq('is_destroyed', false)
  if (error) return false
  return (data ?? []).some((planet: any) => {
    const players = Array.isArray(planet.players) ? planet.players : [planet.players]
    return players.some((player: any) => player?.id === ADMIN_PLAYER_ID)
  })
}

function ensureStyles() {
  if (document.getElementById('dashboard-widget-editor-css')) return
  const style = document.createElement('style')
  style.id = 'dashboard-widget-editor-css'
  style.textContent = `
.dashboard-widget-layer{position:fixed;inset:0;z-index:0;pointer-events:none;overflow:hidden}
.dashboard-widget-layer img{width:100%;height:100%;display:block;object-fit:cover;object-position:center;opacity:.72}
.dashboard-widget-admin-button{position:fixed;right:18px;bottom:18px;z-index:99999;padding:10px 14px;border:1px solid rgba(53,208,255,.45);border-radius:8px;background:rgba(10,16,26,.95);color:#35d0ff;cursor:pointer;font:700 12px system-ui;letter-spacing:.08em}
.dashboard-widget-toolbar{position:fixed;right:18px;bottom:62px;z-index:100000;width:330px;padding:16px;border:1px solid rgba(53,208,255,.4);border-radius:12px;background:rgba(10,16,26,.97);color:#d7e3f4;box-shadow:0 14px 40px rgba(0,0,0,.65);font:14px/1.4 system-ui;backdrop-filter:blur(14px)}
.dashboard-widget-toolbar h3{margin:0 0 12px;color:#35d0ff}.dashboard-widget-toolbar label{display:block;margin:10px 0 5px;color:#8fa3bd;font-size:12px}.dashboard-widget-toolbar input,.dashboard-widget-toolbar select{width:100%;box-sizing:border-box;padding:8px;background:#0d131d;color:#d7e3f4;border:1px solid rgba(126,180,255,.2);border-radius:7px}.dashboard-widget-toolbar input[type=range]{padding:0}.dashboard-widget-toolbar .row{display:flex;gap:8px;margin-top:12px}.dashboard-widget-toolbar button{flex:1;padding:9px;border:1px solid rgba(53,208,255,.35);border-radius:7px;background:#102332;color:#d7e3f4;cursor:pointer;font-weight:700}
` 
  document.head.appendChild(style)
}

function ensureLayer() {
  let layer = document.getElementById(WIDGET_LAYER_ID)
  if (!layer) {
    layer = document.createElement('div')
    layer.id = WIDGET_LAYER_ID
    layer.className = 'dashboard-widget-layer'
    layer.innerHTML = '<img alt="Dashboard background" />'
    document.body.prepend(layer)
  }
  return layer
}

async function loadBackground() {
  const { data } = await supabase.from('dashboard_widgets').select('id,config,visible').eq('player_id', ADMIN_PLAYER_ID).eq('widget_type', 'image').order('updated_at', { ascending: false }).limit(1).maybeSingle()
  if (!data || !data.visible || typeof data.config?.url !== 'string') return
  const image = ensureLayer().querySelector('img') as HTMLImageElement
  image.src = data.config.url
  image.style.opacity = String(data.config.opacity ?? 0.72)
  image.style.objectFit = data.config.fit === 'contain' ? 'contain' : 'cover'
  image.dataset.widgetId = data.id
}

function openEditor() {
  if (document.querySelector('.dashboard-widget-toolbar')) return
  const panel = document.createElement('section')
  panel.className = 'dashboard-widget-toolbar'
  panel.innerHTML = `<h3>🧩 EDITOR DE WIDGETS</h3><div>Fondo del dashboard</div><label>Subir imagen</label><input class="widget-file" type="file" accept="image/png,image/jpeg,image/webp,image/avif"><label>O usar URL</label><input class="widget-url" type="url" placeholder="https://.../imagen.jpg"><label>Opacidad <span class="widget-opacity-label">72%</span></label><input class="widget-opacity" type="range" min="0" max="1" step="0.01" value="0.72"><label>Modo</label><select class="widget-fit"><option value="cover">Cubrir pantalla</option><option value="contain">Contener imagen</option></select><div class="row"><button class="widget-save">GUARDAR</button><button class="widget-close">CERRAR</button></div>`
  document.body.appendChild(panel)
  const layer = ensureLayer()
  const image = layer.querySelector('img') as HTMLImageElement
  const file = panel.querySelector('.widget-file') as HTMLInputElement
  const url = panel.querySelector('.widget-url') as HTMLInputElement
  const opacity = panel.querySelector('.widget-opacity') as HTMLInputElement
  const label = panel.querySelector('.widget-opacity-label') as HTMLElement
  const fit = panel.querySelector('.widget-fit') as HTMLSelectElement
  opacity.addEventListener('input', () => { image.style.opacity = opacity.value; label.textContent = `${Math.round(Number(opacity.value) * 100)}%` })
  fit.addEventListener('change', () => { image.style.objectFit = fit.value })
  file.addEventListener('change', () => { const selected = file.files?.[0]; if (selected) image.src = URL.createObjectURL(selected) })
  panel.querySelector('.widget-close')?.addEventListener('click', () => panel.remove())
  panel.querySelector('.widget-save')?.addEventListener('click', async () => {
    const selected = file.files?.[0]
    let finalUrl = url.value.trim()
    if (selected) {
      const ext = selected.name.split('.').pop()?.toLowerCase() || 'jpg'
      const path = `admin/dashboard-${Date.now()}.${ext}`
      const upload = await supabase.storage.from('dashboard-assets').upload(path, selected, { upsert: true, contentType: selected.type })
      if (upload.error) { alert(upload.error.message); return }
      finalUrl = supabase.storage.from('dashboard-assets').getPublicUrl(path).data.publicUrl
    }
    if (!finalUrl) { alert('Selecciona una imagen o introduce una URL.'); return }
    const config = { url: finalUrl, opacity: Number(opacity.value), fit: fit.value, role: 'background' }
    const widgetId = image.dataset.widgetId
    const result = widgetId
      ? await supabase.from('dashboard_widgets').update({ config, visible: true, updated_at: new Date().toISOString() }).eq('id', widgetId)
      : await supabase.from('dashboard_widgets').insert({ player_id: ADMIN_PLAYER_ID, widget_type: 'image', name: 'Dashboard Background', width: window.innerWidth, height: window.innerHeight, config }).select('id').single()
    if (result.error) { alert(result.error.message); return }
    if (!widgetId && 'data' in result && result.data) image.dataset.widgetId = result.data.id
    image.src = finalUrl; alert('Widget guardado correctamente.')
  })
}

async function boot() {
  ensureStyles()
  if (!(await isAdmin())) return
  await loadBackground()
  const button = document.createElement('button')
  button.className = 'dashboard-widget-admin-button'
  button.textContent = '🧩 WIDGETS'
  button.addEventListener('click', openEditor)
  document.body.appendChild(button)
}

void boot()
