import type { ReactNode } from 'react'

export type PanelTone = 'default' | 'accent' | 'quiet'

export type PanelProps = {
  title?: ReactNode
  meta?: ReactNode
  tone?: PanelTone
  /** El cuerpo se pega al borde: útil para listas y tablas. */
  flush?: boolean
  className?: string
  children: ReactNode
}

/**
 * Superficie de panel del engine. Único lugar donde se decide cómo se ve un
 * panel: los módulos sólo lo usan. Todo sale de tokens (--lgi-*).
 */
export function Panel({ title, meta, tone = 'default', flush = false, className, children }: PanelProps) {
  const classes = ['lgi-panel', `lgi-panel--${tone}`]
  if (flush) classes.push('lgi-panel--flush')
  if (className) classes.push(className)
  const labelled = typeof title === 'string'

  return (
    <section className={classes.join(' ')} aria-label={labelled ? title : undefined}>
      {(title || meta) && (
        <header className="lgi-panel__head">
          {title && <h2 className="lgi-panel__title">{title}</h2>}
          {meta && <span className="lgi-panel__meta">{meta}</span>}
        </header>
      )}
      <div className="lgi-panel__body">{children}</div>
    </section>
  )
}
