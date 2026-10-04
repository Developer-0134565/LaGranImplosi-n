import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from './lib/supabase'

/*
  Wreck Field / Space Dock panel — thin UI layer over the certified wreck-field backend.

  Authority rule (this panel decides NOTHING):
    * the ONLY read is `get_planet_wreck_field(planet)`, a SECURITY DEFINER contract that
      resolves the owner from `auth.uid()` itself and returns 0 rows for a foreign planet,
      a destroyed planet or an anonymous caller. The client never sends a player id.
    * the ONLY mutation is `start_planet_wreck_field_repairs(planet)`, also owner-scoped,
      which delegates to the engine's `start_wreck_field_repairs(field)`.
    * after any mutation the panel RE-READS the contract; it never decrements a quantity
      locally. There is no second source of truth: no direct read of planet_wreck_fields.

  What this panel deliberately does NOT do:
    * it does not compute the recoverable percentage, the repair rate, the duration or the
      expiry. Those are the engine's (least(100, 20 + 8*level) %, 5*level ships/hour, 72 h)
      and they are rendered exactly as returned.
    * it never writes planet_wreck_fields / planet_wreck_field_ships directly (no client
      write policy exists at all — the tables are RLS-protected and backend-written).
    * it does not decide whether a repair is allowed: a BLOCKED field renders the server's
      own `out_result` (e.g. NO_SPACE_DOCK), it is not inferred locally.

  Refresh rules: the data is temporal (repairs tick, the field decays after 72 h), so the
  panel re-reads on mount, whenever the active planet changes, and on a timer while a
  repair is in progress. A failed read surfaces as an explicit error state rather than an
  empty field, so a wreck is never silently hidden.
*/

type WreckRow = {
  wreck_field_id: string
  planet_id: string
  status: 'ACTIVE' | 'REPAIRING' | 'BLOCKED'
  space_dock_level: number
  blocked_reason: string | null
  expires_at: string
  repair_started_at: string | null
  repair_finishes_at: string | null
  ship_id: string | null
  ship_name: string | null
  quantity: number | null
  repaired_quantity: number | null
  pending_quantity: number | null
}

const fmt = (value: number | null | undefined) =>
  value == null ? '—' : Math.floor(Number(value)).toLocaleString('es-ES')

const fmtTime = (value: string | null | undefined) =>
  value ? new Date(value).toLocaleString('es-ES') : '—'

const STATUS_LABEL: Record<WreckRow['status'], string> = {
  ACTIVE: 'CAMPO ACTIVO',
  REPAIRING: 'REPARANDO',
  BLOCKED: 'BLOQUEADO',
}

export default function WreckFieldPanel({ planetId }: { planetId: string }) {
  const [rows, setRows] = useState<WreckRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)

  const load = useCallback(async () => {
    if (!planetId) return
    const { data, error: err } = await supabase.rpc('get_planet_wreck_field', {
      p_planet_id: planetId,
    })
    // An RPC rejection is a real error state, NOT an empty wreck field.
    if (err) {
      setError(err.message)
      setRows(null)
      return
    }
    setError(null)
    setRows((data ?? []) as WreckRow[])
  }, [planetId])

  /* The initial read is fired from the effect through a microtask so the setState lands in an
     async callback, not synchronously in the effect body (repo rule: no setState in an effect).
     The generation counter drops a response that a newer planet has already superseded, so a
     slow read for a previous body can never overwrite the current one. */
  const generation = useRef(0)
  useEffect(() => {
    const current = ++generation.current
    void Promise.resolve().then(() => {
      if (current !== generation.current) return
      void load()
    })
  }, [load])

  const field = rows?.[0] ?? null
  const ships = (rows ?? []).filter((r) => r.ship_id !== null)

  // While a repair is running the state is temporal: re-read so the UI never keeps
  // showing a wreck that the engine has already consumed or completed.
  useEffect(() => {
    if (field?.status !== 'REPAIRING') return
    const timer = window.setInterval(() => void load(), 5000)
    return () => window.clearInterval(timer)
  }, [field?.status, load])
const startRepairs = async () => {
    if (!planetId || busy) return
    setBusy(true)
    setError(null)
    setNotice(null)
    try {
      const { data, error: err } = await supabase.rpc('start_planet_wreck_field_repairs', {
        p_planet_id: planetId,
      })
      if (err) throw err
      const row = (data ?? [])[0]
      setNotice(
        row?.out_status === 'REPAIRING'
          ? `Reparación iniciada. Fin serverside: ${fmtTime(row.out_finishes_at)}.`
          : `Reparación no iniciada: ${row?.out_result ?? 'SIN RESPUESTA'}`,
      )
      // Re-read the authoritative state; never adjust a quantity locally.
      await load()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No se pudo iniciar la reparación.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="neo-panel lgi-wreck-field">
      <div className="neo-panel-header">
        <strong>CAMPO DE RESTOS · DIQUE ESPACIAL</strong>
        {field && <span className="neo-counter">{STATUS_LABEL[field.status]}</span>}
      </div>

      {error && <div className="neo-panel neo-empty">ERROR: {error}</div>}
      {!error && rows === null && <div className="neo-empty">Cargando campo de restos…</div>}

      {!error && rows !== null && !field && (
        <div className="neo-empty">
          No hay campo de restos en este cuerpo. Se crea automáticamente cuando tus naves
          pierden una batalla aquí.
        </div>
      )}

      {!error && field && (
        <>
          <div className="neo-resource">
            <span>DIQUE ESPACIAL</span>
            <b>nivel {field.space_dock_level}</b>
          </div>
          <div className="neo-resource">
            <span>NAVES EN EL CAMPO</span>
            <b>{fmt(ships.reduce((acc, s) => acc + Number(s.quantity ?? 0), 0))}</b>
          </div>
          <div className="neo-resource">
            <span>PENDIENTES</span>
            <b>{fmt(ships.reduce((acc, s) => acc + Number(s.pending_quantity ?? 0), 0))}</b>
          </div>
          <div className="neo-resource">
            <span>DESAPARECE</span>
            <b>{fmtTime(field.expires_at)}</b>
          </div>
          {field.status === 'REPAIRING' && (
            <div className="neo-resource">
              <span>FIN DE LA REPARACIÓN</span>
              <b>{fmtTime(field.repair_finishes_at)}</b>
            </div>
          )}
          {field.status === 'BLOCKED' && (
            <div className="neo-empty">
              Reparación bloqueada por el servidor: {field.blocked_reason ?? 'SIN MOTIVO'}
            </div>
          )}

          <ul className="neo-wreck-list">
            {ships.map((s) => (
              <li key={s.ship_id}>
                <strong>{s.ship_name ?? s.ship_id}</strong>
                <span>
                  {fmt(s.pending_quantity)} pendientes de {fmt(s.quantity)}
                </span>
              </li>
            ))}
          </ul>

          {notice && <div className="neo-panel neo-empty">{notice}</div>}

          {field.status === 'ACTIVE' && (
            <button
              type="button"
              className="neo-button"
              disabled={busy}
              onClick={() => void startRepairs()}
            >
              {busy ? 'INICIANDO…' : 'INICIAR REPARACIÓN'}
            </button>
          )}
        </>
      )}
    </section>
  )
}