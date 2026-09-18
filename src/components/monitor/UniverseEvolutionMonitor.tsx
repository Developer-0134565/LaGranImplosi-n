import { useEffect, useState } from 'react'
import {
  fetchUniverseEvolutionMonitorPublic,
  type UniverseEvolutionMonitorPublicRow,
} from '../../lib/universeEvolutionMonitor'

type Props = {
  universeId?: string | null
}

function formatTimestamp(value: string | null): string {
  if (!value) {
    return '—'
  }

  const date = new Date(value)

  if (Number.isNaN(date.getTime())) {
    return '—'
  }

  return date.toLocaleString('es-ES', {
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  })
}

function formatSeconds(value: number | null): string {
  if (value === null || value === undefined) {
    return '—'
  }

  if (value < 60) {
    return `${value}s`
  }

  if (value < 3600) {
    const minutes = Math.floor(value / 60)
    const seconds = value % 60
    return `${minutes}m ${seconds}s`
  }

  const hours = Math.floor(value / 3600)
  const minutes = Math.floor((value % 3600) / 60)
  return `${hours}h ${minutes}m`
}

function formatNumber(value: number | null | undefined): string {
  if (value === null || value === undefined) {
    return '—'
  }

  return new Intl.NumberFormat('es-ES', { maximumFractionDigits: 0 }).format(value)
}

function formatPercent(value: number | null | undefined, digits = 2): string {
  if (value === null || value === undefined) {
    return '—'
  }

  const percent = value * 100
  return `${percent.toFixed(digits)}%`
}

function formatMetric(label: string, value: string) {
  return (
    <div className="neo-resource">
      <span>{label}</span>
      <b>{value}</b>
    </div>
  )
}

export default function UniverseEvolutionMonitor({ universeId }: Props) {
  const [data, setData] = useState<UniverseEvolutionMonitorPublicRow | null>(null)
  const [loading, setLoading] = useState(false)
  const [isUnavailable, setIsUnavailable] = useState(false)

  useEffect(() => {
    let ignore = false

    const load = async () => {
      if (!universeId) {
        setData(null)
        setIsUnavailable(false)
        setLoading(false)
        return
      }

      setLoading(true)
      setIsUnavailable(false)

      try {
        const next = await fetchUniverseEvolutionMonitorPublic(universeId)

        if (!ignore) {
          setData(next)
        }
      } catch {
        if (!ignore) {
          setData(null)
          setIsUnavailable(true)
        }
      } finally {
        if (!ignore) {
          setLoading(false)
        }
      }
    }

    void load()

    const intervalId = window.setInterval(() => {
      void load()
    }, 30000)

    return () => {
      ignore = true
      window.clearInterval(intervalId)
    }
  }, [universeId])

  if (!universeId) {
    return null
  }

  if (isUnavailable) {
    return (
      <section className="neo-panel" aria-live="polite">
        <div className="neo-panel-header">
          <strong>UNIVERSE EVOLUTION MONITOR</strong>
          <span>NO DISPONIBLE</span>
        </div>
        <p>El monitor no está disponible en este momento.</p>
      </section>
    )
  }

  const status = data?.status ?? '—'
  const isActive = data?.is_active ?? false

  return (
    <section className="neo-panel" aria-live="polite">
      <div className="neo-panel-header">
        <strong>UNIVERSE EVOLUTION MONITOR</strong>
        <span>{loading ? 'ACTUALIZANDO…' : status}</span>
      </div>

      {!data ? (
        <p>{loading ? 'Cargando estado del universo…' : 'Sin datos del monitor disponibles.'}</p>
      ) : (
        <div className="neo-overview-grid">
          <div className="neo-panel">
            <div className="neo-panel-header">
              <strong>STATUS</strong>
            </div>
            <h2>{data.universe_name ?? 'Universo'}</h2>
            <p>{isActive ? 'Activo' : 'Inactivo'}</p>
            <div className="neo-resource">
              <span>ESTADO</span>
              <b>{status}</b>
            </div>
          </div>

          <div className="neo-panel">
            <div className="neo-panel-header">
              <strong>CLOCK</strong>
            </div>
            {formatMetric('Última ejecución', formatTimestamp(data.clock_last_tick_at))}
            {formatMetric('Próxima ejecución', formatTimestamp(data.clock_next_tick_at))}
            {formatMetric('Intervalo', `${formatNumber(data.clock_interval_seconds)}s`)}
            {formatMetric('Procesando', data.clock_is_processing ? 'Sí' : 'No')}
            {formatMetric('Lag', formatSeconds(data.clock_lag_seconds))}
            {formatMetric('Ticks pendientes', formatNumber(data.clock_ticks_due))}
          </div>

          <div className="neo-panel">
            <div className="neo-panel-header">
              <strong>EXPANSION</strong>
            </div>
            {formatMetric('Galaxias', formatNumber(data.galaxy_count))}
            {formatMetric('Normales', formatNumber(data.normal_galaxy_count))}
            {formatMetric('Especiales', formatNumber(data.special_galaxy_count))}
            {formatMetric('Sistemas', formatNumber(data.system_count))}
            {formatMetric('Posiciones', formatNumber(data.unlocked_positions))}
            {formatMetric('Pendientes', formatNumber(data.expansion_pending_galaxies))}
            {formatMetric('Lag más antiguo', formatSeconds(data.expansion_oldest_lag_seconds))}
          </div>

          <div className="neo-panel">
            <div className="neo-panel-header">
              <strong>GALAXY ROLLS</strong>
            </div>
            {formatMetric('Próxima tirada', formatTimestamp(data.next_galaxy_roll_at))}
            {formatMetric('Tiradas pendientes', formatNumber(data.galaxy_rolls_due))}
          </div>

          <div className="neo-panel">
            <div className="neo-panel-header">
              <strong>AI POPULATION</strong>
            </div>
            {formatMetric('Planetas AI', formatNumber(data.ai_planets_count))}
            {formatMetric('Actual', formatPercent(data.ai_density))}
            {formatMetric('Objetivo', formatPercent(data.ai_density_target))}
            {formatMetric('Tolerancia', `±${formatPercent(data.ai_density_tolerance)}`)}
            {formatMetric('Rango', `${formatPercent(data.ai_density_lower_bound)} – ${formatPercent(data.ai_density_upper_bound)}`)}
            {formatMetric('Déficit', formatNumber(data.ai_deficit))}
            {formatMetric('Batch', formatNumber(data.ai_generation_batch))}
            {formatMetric('Batches estimados', formatNumber(data.ai_estimated_batches))}
            {formatMetric('Próxima reconciliación', formatTimestamp(data.next_ai_reconciliation_at))}
          </div>

          <div className="neo-panel">
            <div className="neo-panel-header">
              <strong>CATCH-UP</strong>
            </div>
            {formatMetric('Ticks pendientes', formatNumber(data.clock_ticks_due))}
            {formatMetric('Expansion backlog', formatNumber(data.expansion_pending_galaxies))}
            {formatMetric('Roll backlog', formatNumber(data.galaxy_rolls_due))}
            {formatMetric('Próxima reconciliación', formatTimestamp(data.next_ai_reconciliation_at))}
          </div>
        </div>
      )}
    </section>
  )
}
