import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import './styles/template-eventbar.css'
import './styles/template-frame-fix.css'
import './styles/template-layout-fix.css'
import './styles/template-viewport-final.css'
import './styles/template-screen-final.css'
import './styles/template-final-overrides.css'
import './styles/viewport-scale-fix.css'
import './styles/sidebar-viewport-fix.css'
import './styles/frontend-runtime-fixes.css'
import './styles/zz-frontend-layer-authority.css'
import App from './App.tsx'
import TemplateChrome from './TemplateChrome.tsx'

/* Runtime authority: Vite can inject component CSS after the entry stylesheet.
   Install the wallpaper guard directly in <head> so later stylesheet order cannot
   turn the decorative wallpaper/frame into a foreground layer. */
const wallpaperGuard = document.createElement('style')
wallpaperGuard.id = 'lagranimplosion-wallpaper-guard'
wallpaperGuard.textContent = `
.template-frame-overlay,.template-frame-edge,
img[src*="wallpaper"],img[src*="Wallpaper"],img[src*="Frameoverlay"],img[src*="frameoverlay"],
[class*="wallpaper"],[id*="wallpaper"],[class*="Wallpaper"],[id*="Wallpaper"]{
 display:none!important;visibility:hidden!important;opacity:0!important;pointer-events:none!important;
 width:0!important;height:0!important;max-width:0!important;max-height:0!important;
 position:absolute!important;inset:auto!important;background:none!important;border:0!important;
 box-shadow:none!important;z-index:-2147483647!important;
}
body>img{display:none!important;visibility:hidden!important;pointer-events:none!important}
html,body{overflow:hidden!important;background-color:#05080d!important}
body{background-image:url('/IMAGENES/wallpaper.jpg')!important;background-position:center center!important;background-size:cover!important;background-repeat:no-repeat!important;background-attachment:fixed!important}
#root,.app-frame{position:relative!important;z-index:1!important;isolation:isolate!important}
.game{position:relative!important;z-index:2!important;background:transparent!important;isolation:isolate!important}
.template-chrome{position:fixed!important;z-index:5000!important}
.template-planetstrip{position:fixed!important;z-index:4890!important}
.template-side{position:fixed!important;z-index:4900!important}
`
document.head.appendChild(wallpaperGuard)

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <div className="app-frame">
      <TemplateChrome />
      <App />
    </div>
  </StrictMode>,
)
