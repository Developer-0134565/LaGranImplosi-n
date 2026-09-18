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
import { ensureSession } from './lib/identity'

function Root() {
  const [session, setSession] = useState<unknown>(null)
  const [loading, setLoading] = useState(true)
  const [authError, setAuthError] = useState<string | null>(null)

  useEffect(() => {
    let active = true

    // Modo invitado: si no hay sesión persistida se crea una sesión ANÓNIMA.
    // Solo si eso falla se muestra la pantalla de login.
    ensureSession()
      .then(async () => {
        const { data } = await supabase.auth.getSession()
        if (!active) return
        setSession(data.session)
        setLoading(false)
      })
      .catch((error: unknown) => {
        if (!active) return
        setAuthError(error instanceof Error ? error.message : 'No se pudo iniciar la sesión')
        setLoading(false)
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
    return (
      <>
        {authError && (
          <div style={{ color: '#f2b8b5', textAlign: 'center', marginTop: '40px' }}>
            No se pudo iniciar el modo invitado ({authError}). Inicia sesión para continuar.
          </div>
        )}
        <LoginPage />
      </>
    )
  }

  return (
    <div className="app-frame">
      <TemplateChrome />
      <App />
    </div>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Root />
  </StrictMode>,
)