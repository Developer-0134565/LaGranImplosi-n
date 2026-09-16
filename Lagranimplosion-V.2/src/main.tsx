import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './legacy-template-adapter'
import App from './App.tsx'
import TemplateChrome from './TemplateChrome.tsx'
import DeveloperTypography from './DeveloperTypography.tsx'
import './planet-ownership-runtime'
import './index.css'
import './App.css'
import './styles/fonts.css'
import './styles/ui-overhaul.css'
import './styles/definition-ui.css'
import './styles/template-eventbar.css'
import './styles/frontend-runtime-fixes.css'
import './styles/template-system.css'
import './styles/template-layout-v2.css'
import './styles/typography-controls.css'
import './styles/v2-layout-fixes.css'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <div className="app-frame">
      <TemplateChrome />
      <App />
      <DeveloperTypography />
    </div>
  </StrictMode>,
)
