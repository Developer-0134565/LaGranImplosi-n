import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import './styles/App.css'
import './styles/fonts.css'
import './styles/ui-overhaul.css'
import './styles/definition-ui.css'
import './styles/template-eventbar.css'
import './styles/frontend-runtime-fixes.css'
import './styles/template-system.css'
import App from './App.tsx'
import TemplateChrome from './TemplateChrome.tsx'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <div className="app-frame">
      <TemplateChrome />
      <App />
    </div>
  </StrictMode>,
)
