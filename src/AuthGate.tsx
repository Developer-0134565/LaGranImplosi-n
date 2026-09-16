import { useEffect, useState } from 'react'
import TemplateChrome from './TemplateChrome.tsx'
import LoginPage from './LoginPage'
import App from './App.tsx'
import { supabase } from './lib/supabase'

export default function AuthGate() {
  const [session, setSession] = useState<unknown>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      setLoading(false)
    })

    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => {
      setSession(s)
    })

    return () => sub.subscription.unsubscribe()
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
