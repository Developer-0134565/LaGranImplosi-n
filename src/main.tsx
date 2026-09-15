import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import './styles/admin-design.css'
import './admin-design'
import './dashboard-widget-editor'
import './ui-scale'
import App from './App.tsx'
import './styles/deuteria-original.css'
import './styles/deuteria-compat.css'
import './template-neo-fix'
import './widget-visibility-toggle'
import './sidebar-complete'
import './core-module-foundation'
import './galaxy-mount'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
