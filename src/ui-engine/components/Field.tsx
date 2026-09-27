import type { CSSProperties, ReactNode } from 'react'

export type FieldProps = {
  label: ReactNode
  hint?: ReactNode
  /** El control ocupa el ancho disponible del field. */
  wide?: boolean
  className?: string
  children: ReactNode
}

/** Campo etiquetado: el control se pasa como child (select/input/datetime). */
export function Field({ label, hint, wide = false, className, children }: FieldProps) {
  const classes = ['lgi-field']
  if (wide) classes.push('lgi-field--wide')
  if (className) classes.push(className)
  return (
    <label className={classes.join(' ')}>
      <span className="lgi-field__label">{label}</span>
      {children}
      {hint && <small className="lgi-field__hint">{hint}</small>}
    </label>
  )
}

export type FieldRowProps = {
  /** Columnas mínimas antes de apilar (container query). */
  minColumn?: number
  className?: string
  children: ReactNode
}

/** Fila de campos que se apila cuando el contenedor se estrecha. */
export function FieldRow({ minColumn = 120, className, children }: FieldRowProps) {
  const classes = ['lgi-field-row', className].filter(Boolean).join(' ')
  return (
    <div className={classes} style={{ '--lgi-field-min': `${minColumn}px` } as CSSProperties}>
      {children}
    </div>
  )
}
