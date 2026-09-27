import type { ReactNode } from 'react'

export type StatTone = 'default' | 'accent' | 'ok' | 'warn' | 'danger'

export type StatItem = {
  label: ReactNode
  value: ReactNode
  tone?: StatTone
}

export type StatGridProps = {
  items: readonly StatItem[]
  /** Columnas en el contenedor ancho; el contenedor decide cuándo apilar. */
  columns?: 1 | 2 | 3 | 4
  className?: string
}

/**
 * Rejilla de estadísticas ADAPTATIVA: el número de columnas llega al layout
 * como `data-columns`, pero el apilado real lo decide la container query de
 * `ui-engine.css` según el espacio disponible. Nunca depende del viewport.
 */
export function StatGrid({ items, columns = 2, className }: StatGridProps) {
  const classes = ['lgi-stats', className].filter(Boolean).join(' ')
  return (
    <dl className={classes} data-columns={columns}>
      {items.map((item, index) => (
        <div
          className={`lgi-stat lgi-stat--${item.tone ?? 'default'}`}
          key={typeof item.label === 'string' ? item.label : `stat-${index}`}
        >
          <dt>{item.label}</dt>
          <dd>{item.value}</dd>
        </div>
      ))}
    </dl>
  )
}
