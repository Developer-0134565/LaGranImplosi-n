import { StrictMode, useEffect, useState } from 'react'
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

// Componentes
import App from './App.tsx'
import TemplateChrome from './TemplateChrome.tsx'
import LoginPage from './LoginPage'
import { supabase } from './lib/supabase'
import { UIDesigner, UIEngineProvider, UIWorkbench, useUIWorkbenchRequested } from './ui-engine'

/*
  Raíz de la aplicación.

  Dos superficies, un único provider del engine:

    * `#ui-designer` → BANCO DE PRUEBAS DEV (`UIWorkbench`): monta el engine, los
      grids de referencia y el UI Designer sin sesión. No toca gameplay.
    * resto         → aplicación real (login → juego). El `UIDesigner` es la
      herramienta DEV del engine; vive dentro del gate de sesión, igual que
      antes vivía el switcher de templates.

  `UIEngineProvider` resuelve el template activo (React + localStorage). El
  provider NO toca Supabase: ninguna preferencia visual se persiste en el
  backend.
*/

function AuthenticatedApp() {
  const [session, setSession] = useState<unknown>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let active = true

    // Autenticación canónica (email/password): no se crean sesiones anónimas.
    // Sin sesión, la aplicación muestra LoginPage.
    supabase.auth
      .getSession()
      .then(({ data }) => {
        if (!active) return
        setSession(data.session)
        setLoading(false)
      })
      .catch(() => {
        if (active) setLoading(false)
      })

    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => {
      setSession(s)
    })

    return () => {
      active = false
      sub.subscription.unsubscribe()
    }
  }, [])

  if (loading) {
    return (
      <div style={{ color: '#d7e4ee', textAlign: 'center', marginTop: '80px' }}>
        Cargando…
      </div>
    )
  }

  if (!session) {
    return <LoginPage />
  }

  return (
    <div className="app-frame">
      <TemplateChrome />
      <App />
    </div>
  )
}

function Root() {
  const workbench = useUIWorkbenchRequested()

  return (
    <UIEngineProvider>
      {workbench ? (
        <UIWorkbench />
      ) : (
        <>
          <AuthenticatedApp />
          <UIDesigner />
        </>
      )}
    </UIEngineProvider>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Root />
  </StrictMode>,
)