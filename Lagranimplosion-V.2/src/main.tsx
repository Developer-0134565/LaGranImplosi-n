import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App.tsx'
import TemplateChrome from './TemplateChrome.tsx'
import DeveloperTypography from './DeveloperTypography.tsx'
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

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <div className="app-frame">
      <TemplateChrome />
      <App />
      <DeveloperTypography />
    </div>
  </StrictMode>,
)
