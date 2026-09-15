import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import './styles/deuteria-original.css'
import './styles/deuteria-compat.css'
import './styles/current-template-compat.css'
import './styles/typography-controls.css'
import './ui-scale'
import './style-controls'
import './sidebar-complete'
import App from './AppStable.tsx'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
