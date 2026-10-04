import { StrictMode, useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'

// CSS de base
import './index.css'

// Componentes
import App from './App.tsx'
import LoginPage from './LoginPage'
import { supabase } from './lib/supabase'
import { UIDesigner, UIEngine, UIEngineProvider, UIWorkbench, useUIWorkbenchRequested } from './ui-engine'
import { I18nProvider } from './i18n/LanguageProvider'
import { LanguagePicker } from './i18n/LanguagePicker'

/*
  Raíz de la aplicación.

  Dos superficies, un único provider del engine:

    * `#ui-designer` → BANCO DE PRUEBAS DEV (`UIWorkbench`): monta el engine, los
      grids de referencia y el UI Designer sin sesión. No toca gameplay.
    * resto         → aplicación real (login → juego). El `UIDesigner` es la
      herramienta DEV del engine; vive dentro del gate de sesión.

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

  /* El selector de idioma vive FUERA del gate de sesión a propósito: el login y
     el onboarding son justo las pantallas donde más hace falta poder cambiarlo. */
  if (!session) {
    return (
      <>
        <LoginPage />
        <LanguagePicker />
      </>
    )
  }

  return (
    <>
      <UIEngine>
        <div className="app-frame">
          <App />
        </div>
      </UIEngine>
      <UIDesigner />
      <LanguagePicker />
    </>
  )
}

function Root() {
  const workbench = useUIWorkbenchRequested()

  return (
    <UIEngineProvider>
      {workbench ? (
        <UIWorkbench />
      ) : (
        <AuthenticatedApp />
      )}
    </UIEngineProvider>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <I18nProvider>
      <Root />
    </I18nProvider>
  </StrictMode>,
)