import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import './styles/admin-design.css'
import './admin-design'
import './dashboard-widget-editor'
import './ui-scale'
import './styles/deuteria-original.css'
import './styles/deuteria-compat.css'
import './styles/core-modules.css'
import './styles/current-template-compat.css'
import './styles/typography-controls.css'
import './template-neo-fix'
import './style-controls'
import './widget-visibility-toggle'
import './sidebar-complete'
import './core-module-foundation'
import './live-temporal-sync'
import App from './AppStable.tsx'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
