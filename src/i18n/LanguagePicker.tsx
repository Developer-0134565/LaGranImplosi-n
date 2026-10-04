import { useEffect, useState } from 'react'
import { LANG_FLAG, LANG_LABEL, LANGS } from '../lib/i18n'
import type { Lang } from '../lib/i18n'
import { useI18n } from './I18nContext'

/**
 * Botón de idioma + ventana de selección.
 *
 * Montado en la app raíz, FUERA del gate de sesión, para que el jugador pueda
 * cambiar de idioma ANTES de autenticarse (el login y el onboarding son
 * precisamente las pantallas que más lo necesitan).
 */
export function LanguagePicker() {
  const { lang, setLang, t } = useI18n()
  const [open, setOpen] = useState(false)

  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setOpen(false)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open])

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        title={t('lang.choose')}
        aria-label={t('lang.choose')}
        aria-haspopup="dialog"
        style={{
          position: 'fixed',
          top: 12,
          right: 12,
          zIndex: 20001,
          display: 'flex',
          alignItems: 'center',
          gap: 6,
          padding: '6px 10px',
          borderRadius: 6,
          border: '1px solid #2b3a47',
          background: '#0e1620',
          color: '#d7e4ee',
          fontFamily: 'var(--font-title, Arial, sans-serif)',
          fontSize: 13,
          letterSpacing: 1,
          cursor: 'pointer',
        }}
      >
        <span aria-hidden="true">{LANG_FLAG[lang]}</span>
        <span>{lang.toUpperCase()}</span>
      </button>

      {open && (
        <div
          role="dialog"
          aria-modal="true"
          aria-label={t('lang.title')}
          onClick={() => setOpen(false)}
          style={{
            position: 'fixed',
            inset: 0,
            zIndex: 20002,
            background: 'rgba(4, 10, 16, 0.78)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          <div
            onClick={(e) => e.stopPropagation()}
            style={{
              minWidth: 300,
              padding: 24,
              borderRadius: 10,
              border: '1px solid #2b3a47',
              background: '#0e1620',
              color: '#d7e4ee',
              fontFamily: 'var(--font-title, Arial, sans-serif)',
            }}
          >
            <h2 style={{ margin: '0 0 16px', fontSize: 18, letterSpacing: 1 }}>
              {t('lang.title')}
            </h2>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {LANGS.map((code: Lang) => (
                <button
                  key={code}
                  type="button"
                  onClick={() => {
                    setLang(code)
                    setOpen(false)
                  }}
                  aria-pressed={lang === code}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 10,
                    padding: '10px 12px',
                    textAlign: 'left',
                    borderRadius: 6,
                    border: lang === code ? '1px solid #8ef0ff' : '1px solid #2b3a47',
                    background: lang === code ? '#132433' : 'transparent',
                    color: '#d7e4ee',
                    fontSize: 15,
                    cursor: 'pointer',
                  }}
                >
                  <span aria-hidden="true" style={{ fontSize: 20 }}>
                    {LANG_FLAG[code]}
                  </span>
                  <span>{LANG_LABEL[code]}</span>
                </button>
              ))}
            </div>
            <button
              type="button"
              onClick={() => setOpen(false)}
              style={{
                marginTop: 16,
                padding: '8px 14px',
                borderRadius: 6,
                border: '1px solid #2b3a47',
                background: 'transparent',
                color: '#d7e4ee',
                cursor: 'pointer',
              }}
            >
              {t('close')}
            </button>
          </div>
        </div>
      )}
    </>
  )
}