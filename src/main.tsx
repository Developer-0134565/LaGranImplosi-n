import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'

// CSS de base
import './index.css'

// CSS de template / layout
import './styles/template-chrome.css'
import './styles/template-eventbar.css'
import './styles/template-frame-fix.css'
import './styles/template-layout-fix.css'
import './styles/template-viewport-final.css'
import './styles/template-screen-final.css'
import './styles/template-final-overrides.css'
import './styles/viewport-scale-fix.css'
import './styles/sidebar-viewport-fix.css'
import './styles/frontend-runtime-fixes.css'
import './styles/frontend-layer-fix.css'

// Autoridad de capas — DEBEN ir al final
import './styles/zz-frontend-layer-authority.css'
import './styles/zzz-wallpaper-lock.css'

import AuthGate from './AuthGate.tsx'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <AuthGate />
  </StrictMode>,
)
