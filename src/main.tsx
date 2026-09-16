import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import './styles/deuteria-original.css'
import './styles/gimplosion-shell.css'
import './styles/gimplosion-compat.css'
import './styles/current-template-compat.css'
import './styles/typography-controls.css'
import './ui-scale'
import './style-controls'
import App from './AppStable.tsx'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
