import { useState } from 'react'
import { supabase } from './lib/supabase'
import { AVATARS, DEFAULT_AVATAR_ID, renderAvatar } from './lib/avatars'
import { useI18n } from './i18n/I18nContext'

/**
 * Onboarding explícito (email/password): el usuario autenticado elige su nombre
 * y la RPC `provision_player` crea su imperio (player + Homeworld + recursos +
 * research) para su propio auth.uid(). No existe modo invitado ni creación
 * automática de jugadores.
 */
/**
 * Países ofrecidos en el onboarding (ISO-3166 alpha-2 + bandera). Es una lista de
 * conveniencia, NO una restricción: el servidor acepta cualquier alpha-2 válido y
 * cae en 'XX' si no puede determinarlo.
 */
const COUNTRY_OPTIONS: ReadonlyArray<{ code: string; label: string }> = [
  { code: 'XX', label: '\u{1F30D} Sin país / Mundo' },
  { code: 'ES', label: '\u{1F1EA}\u{1F1F8} España' },
  { code: 'AR', label: '\u{1F1E6}\u{1F1F7} Argentina' },
  { code: 'MX', label: '\u{1F1F2}\u{1F1FD} México' },
  { code: 'CO', label: '\u{1F1E8}\u{1F1F4} Colombia' },
  { code: 'CL', label: '\u{1F1E8}\u{1F1F1} Chile' },
  { code: 'PE', label: '\u{1F1F5}\u{1F1EA} Perú' },
  { code: 'US', label: '\u{1F1FA}\u{1F1F8} Estados Unidos' },
  { code: 'BR', label: '\u{1F1E7}\u{1F1F7} Brasil' },
  { code: 'FR', label: '\u{1F1EB}\u{1F1F7} Francia' },
  { code: 'DE', label: '\u{1F1E9}\u{1F1EA} Alemania' },
  { code: 'IT', label: '\u{1F1EE}\u{1F1F9} Italia' },
  { code: 'PT', label: '\u{1F1F5}\u{1F1F9} Portugal' },
  { code: 'GB', label: '\u{1F1EC}\u{1F1E7} Reino Unido' },
  { code: 'RU', label: '\u{1F1F7}\u{1F1FA} Rusia' },
  { code: 'CN', label: '\u{1F1E8}\u{1F1F3} China' },
  { code: 'JP', label: '\u{1F1EF}\u{1F1F5} Japón' },
  { code: 'IN', label: '\u{1F1EE}\u{1F1F3} India' },
  { code: 'AU', label: '\u{1F1E6}\u{1F1FA} Australia' },
]

export default function OnboardingPanel({
  busy,
  error,
  onSubmit,
}: {
  busy: boolean
  error: string | null
  onSubmit: (
    username: string,
    countryCode: string,
    planetName: string,
    avatarId: string,
  ) => void | Promise<void>
}) {
  const [username, setUsername] = useState('')
  const [countryCode, setCountryCode] = useState('XX')
  const [planetName, setPlanetName] = useState('')
  const [avatarId, setAvatarId] = useState(DEFAULT_AVATAR_ID)
  const { t } = useI18n()
  const trimmed = username.trim()
  const trimmedPlanet = planetName.trim()
  const planetOk =
    trimmedPlanet === '' ||
    (trimmedPlanet.length <= 32 && /^[\p{L}\p{N} ._-]+$/u.test(trimmedPlanet))
  const valid = trimmed.length >= 3 && trimmed.length <= 24 && /^[0-9A-Za-z _.-]+$/.test(trimmed) && trimmed.toLowerCase() !== 'devplayer'

  return (
    <div className="neo-main-view" style={{ maxWidth: 520, margin: '80px auto', padding: '0 20px' }}>
      <div className="neo-panel">
        <div className="neo-section-head">
          <div>
            <span className="neo-eyebrow">{t('onboard.first')}</span>
            <h1>{t('onboard.title')}</h1>
            <p>{t('onboard.subtitle')}</p>
          </div>
        </div>
        <label className="font-control">
          <span>{t('onboard.commander')}</span>
          <input
            value={username}
            maxLength={24}
            onChange={(e) => setUsername(e.target.value)}
            placeholder={t('onboard.commanderPh')}
            disabled={busy}
          />
        </label>
        <label className="font-control">
          <span>{t('onboard.country')}</span>
          <select
            value={countryCode}
            onChange={(e) => setCountryCode(e.target.value)}
            disabled={busy}
          >
            {COUNTRY_OPTIONS.map((c) => (
              <option key={c.code} value={c.code}>
                {c.label}
              </option>
            ))}
          </select>
        </label>
        <label className="font-control">
          <span>{t('onboard.planet')} <small>{t('onboard.planetOptional')}</small></span>
          <input
            value={planetName}
            maxLength={32}
            onChange={(e) => setPlanetName(e.target.value)}
            placeholder={t('onboard.planetPh')}
            disabled={busy}
          />
          {!planetOk && (
            <small style={{ color: '#f2b8b5' }}>{t('onboard.planetInvalid')}</small>
          )}
        </label>
        <label className="font-control">
          <span>{t('onboard.shield')}</span>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: '8px', marginTop: '6px' }}>
            {AVATARS.map((a) => (
              <button
                key={a.id}
                type="button"
                onClick={() => setAvatarId(a.id)}
                disabled={busy}
                title={a.name}
                aria-label={a.name}
                aria-pressed={avatarId === a.id}
                style={{
                  width: '44px',
                  height: '44px',
                  padding: 0,
                  borderRadius: '50%',
                  cursor: busy ? 'not-allowed' : 'pointer',
                  background: 'transparent',
                  outline: avatarId === a.id ? '2px solid #8ef0ff' : '1px solid #2b3a47',
                  outlineOffset: '2px',
                }}
                dangerouslySetInnerHTML={{ __html: renderAvatar(a.id, 40) }}
              />
            ))}
          </div>
        </label>
        {error && <div className="neo-panel neo-empty" style={{ color: '#f2b8b5' }}>{error}</div>}
        <button
          type="button"
          className="neo-button"
          disabled={busy || !valid || !planetOk}
          onClick={() => void onSubmit(trimmed, countryCode, trimmedPlanet, avatarId)}
        >
          {busy ? t('onboard.creating') : t('onboard.create')}
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
            {t('onboard.logout')}
          </button>
        </div>
      </div>
    </div>
  )
}
