export function formatNumber(value: number | string | undefined | null) {
  if (value === undefined || value === null) return '—'
  const n = Number(value)
  return Number.isFinite(n) ? new Intl.NumberFormat('es-ES', { maximumFractionDigits: 0 }).format(n) : '—'
}

export function formatDuration(value: number | string | undefined | null) {
  const seconds = Number(value)
  if (!Number.isFinite(seconds) || seconds <= 0) return '—'
  const total = Math.round(seconds)
  const days = Math.floor(total / 86400)
  const hours = Math.floor((total % 86400) / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const secs = total % 60
  return days ? `${days}d ${hours}h` : hours ? `${hours}h ${minutes}m` : minutes ? `${minutes}m ${secs}s` : `${secs}s`
}

export function coordinates(p: { galaxy: number; system: number; position: number }) {
  return `[${p.galaxy}:${p.system}:${p.position}]`
}

export function formatTime(value?: string | null) {
  if (!value) return '—'
  return new Date(value).toLocaleString('es-ES', { hour: '2-digit', minute: '2-digit', second: '2-digit' })
}
