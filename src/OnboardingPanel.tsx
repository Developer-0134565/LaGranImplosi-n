import { useState } from 'react'
import { supabase } from './lib/supabase'

/**
 * Onboarding explícito (email/password): el usuario autenticado elige su nombre
 * y la RPC `provision_player` crea su imperio (player + Homeworld + recursos +
 * research) para su propio auth.uid(). No existe modo invitado ni creación
 * automática de jugadores.
 */
export default function OnboardingPanel({
  busy,
  error,
  onSubmit,
}: {
  busy: boolean
  error: string | null
  onSubmit: (username: string) => void | Promise<void>
}) {
  const [username, setUsername] = useState('')
  const trimmed = username.trim()
  const valid = trimmed.length >= 3 && trimmed.length <= 24 && /^[0-9A-Za-z _.-]+$/.test(trimmed) && trimmed.toLowerCase() !== 'devplayer'

  return (
    <div className="neo-main-view" style={{ maxWidth: 520, margin: '80px auto', padding: '0 20px' }}>
      <div className="neo-panel">
        <div className="neo-section-head">
          <div>
            <span className="neo-eyebrow">PRIMER ACCESO</span>
            <h1>Funda tu imperio</h1>
            <p>Tu cuenta aún no tiene un imperio. Elige un nombre de comandante: se creará tu Homeworld con recursos iniciales.</p>
          </div>
        </div>
        <label className="font-control">
          <span>NOMBRE DE COMANDANTE</span>
          <input
            value={username}
            maxLength={24}
            onChange={(e) => setUsername(e.target.value)}
            placeholder="3-24 caracteres"
            disabled={busy}
          />
        </label>
        {error && <div className="neo-panel neo-empty" style={{ color: '#f2b8b5' }}>{error}</div>}
        <button
          type="button"
          className="neo-button"
          disabled={busy || !valid}
          onClick={() => void onSubmit(trimmed)}
        >
          {busy ? 'CREANDO IMPERIO…' : 'CREAR IMPERIO'}
        </button>
        <div className="neo-empty">
          <button
            type="button"
            className="neo-button secondary"
            disabled={busy}
            onClick={async () => {
              await supabase.auth.signOut()
              window.location.reload()
            }}
          >
            CERRAR SESIÓN
          </button>
        </div>
      </div>
    </div>
  )
}