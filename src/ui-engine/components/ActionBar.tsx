import type { ReactNode } from 'react'

export type ActionBarProps = {
  /** Texto que explica por qué la acción principal está bloqueada. */
  hint?: ReactNode
  align?: 'start' | 'end' | 'between'
  className?: string
  children: ReactNode
}

/** Barra de acciones: agrupa la acción principal y sus motivos de bloqueo. */
export function ActionBar({ hint, align = 'between', className, children }: ActionBarProps) {
  const classes = ['lgi-actions', `lgi-actions--${align}`, className].filter(Boolean).join(' ')
  return (
    <div className={classes}>
      <div className="lgi-actions__content">{children}</div>
      {hint && <small className="lgi-actions__hint">{hint}</small>}
    </div>
  )
}

export type NoticeBarProps = {
  notice?: string | null
  error?: string | null
  onDismiss?: () => void
  className?: string
}

/** Avisos del servidor: el éxito y el rechazo se muestran sin reinterpretar. */
export function NoticeBar({ notice, error, onDismiss, className }: NoticeBarProps) {
  if (!notice && !error) return null
  const classes = ['lgi-notice-bar', className].filter(Boolean).join(' ')
  return (
    <div className={classes} role="status">
      {notice && <p className="lgi-notice lgi-notice--ok">{notice}</p>}
      {error && <p className="lgi-notice lgi-notice--error">ERROR: {error}</p>}
      {onDismiss && (
        <button type="button" className="lgi-notice-bar__dismiss" onClick={onDismiss} aria-label="Descartar aviso">
          ×
        </button>
      )}
    </div>
  )
}

export type PillTone = 'default' | 'accent' | 'ok' | 'warn' | 'danger'

/** Etiqueta compacta de estado. */
export function Pill({ tone = 'default', children }: { tone?: PillTone; children: ReactNode }) {
  return <span className={`lgi-pill lgi-pill--${tone}`}>{children}</span>
}
