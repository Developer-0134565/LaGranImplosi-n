import type { CSSProperties, ReactNode } from 'react'

export type CardGridProps = {
  /** Ancho mínimo de tarjeta antes de reducir columnas (container query). */
  minCard?: number
  className?: string
  children: ReactNode
}

/**
 * Rejilla de tarjetas adaptativa: multi-columna en contenedores anchos,
 * apilada en contenedores estrechos. Sin media queries de viewport.
 */
export function CardGrid({ minCard = 190, className, children }: CardGridProps) {
  const classes = ['lgi-cards', className].filter(Boolean).join(' ')
  return (
    <div className={classes} style={{ '--lgi-card-min': `${minCard}px` } as CSSProperties}>
      {children}
    </div>
  )
}

export type ScreenHeaderProps = {
  eyebrow?: ReactNode
  title: ReactNode
  description?: ReactNode
  meta?: ReactNode
  className?: string
  children?: ReactNode
}

/** Cabecera de pantalla del engine (título + contadores + acciones). */
export function ScreenHeader({ eyebrow, title, description, meta, className, children }: ScreenHeaderProps) {
  const classes = ['lgi-screen-head', className].filter(Boolean).join(' ')
  return (
    <header className={classes}>
      <div className="lgi-screen-head__text">
        {eyebrow && <span className="lgi-eyebrow">{eyebrow}</span>}
        <h1>{title}</h1>
        {description && <p>{description}</p>}
      </div>
      {meta && <span className="lgi-screen-head__meta">{meta}</span>}
      {children && <div className="lgi-screen-head__extra">{children}</div>}
    </header>
  )
}
