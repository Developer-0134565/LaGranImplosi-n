import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import './styles/template-eventbar.css'
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
