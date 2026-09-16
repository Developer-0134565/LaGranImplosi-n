import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import './styles/template-eventbar.css'
import './styles/template-frame-fix.css'
import './styles/template-layout-fix.css'
import './styles/template-viewport-final.css'
import './styles/template-screen-final.css'
import './styles/template-final-overrides.css'
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
