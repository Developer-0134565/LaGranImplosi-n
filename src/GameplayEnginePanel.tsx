import { useCallback, useEffect, useState } from 'react'
import { supabase } from './lib/supabase'

/*
  Gameplay Engine panels — read/act contracts of the GAMEPLAY COMPLETION SWEEP.

  Authority rule: these panels NEVER decide anything. Every number and every transition comes from a server-side
  contract (`get_player_fleet_slots`, `recall_fleet`, `get_player_messages`, `mark_message_read`,
  `get_player_espionage_reports`, `get_player_expedition_reports`, `get_universe_ranking`); the UI only renders
  the answer and shows the server's own error text when a call is refused (e.g. FLEET_SLOTS_FULL,
  FLEET_NOT_RECALLABLE).

  `FleetSlotsPanel` expone la autoridad de slots y, cuando recibe la lista de movimientos, la acción de retirada.
  La vista de flota delega la retirada por movimiento a `ActiveFleetsPanel` (src/FleetCommandPanel.tsx), por lo
  que `fleets` es opcional: sin lista se muestran sólo los números del contrato.
*/

type FleetRef = { id: string; mission_type: string; status: string }

type SlotRow = {
  out_max_slots: number
  out_slots_in_use: number
  out_slots_available: number
  out_computer_technology_level: number
}

type MessageRow = {
  out_message_id: string
  out_sender_username: string | null
  out_subject: string
  out_body: string | null
  out_read_at: string | null
  out_created_at: string
  out_is_read: boolean
}

type ReportRow = {
  out_report_id: string
  out_target_name: string | null
  out_galaxy: number
  out_system: number
  out_position: number
  out_espionage_level: number
  out_target_espionage_level: number
  out_metal: number
  out_crystal: number
  out_deuterium: number
  out_energy: number
  /* `out_fleet`, `out_defenses`, `out_buildings` and `out_research` are the reveal-gated maps stored by
     `resolve_espionage_arrival`; the booleans tell «not revealed» apart from «nothing there». Both are server
     answers: the panel never re-derives the OGameX rule. */
  out_fleet: Record<string, number> | null
  out_defenses: Record<string, number> | null
  out_buildings: Record<string, number> | null
  out_research: Record<string, number> | null
  out_ships_revealed: boolean
  out_defenses_revealed: boolean
  out_buildings_revealed: boolean
  out_research_revealed: boolean
  out_counter_espionage_chance: number
  out_counter_espionage_triggered: boolean
  out_probes_sent: number
  out_probes_lost: number
  out_created_at: string
}

type RankRow = {
  out_rank: number
  out_player_id: string
  out_username: string
  out_player_type: string
  out_points: number
  out_is_current_player: boolean
}

function stamp(value: string | null | undefined) {
  if (!value) return '—'
  return new Date(value).toLocaleString('es-ES')
}

export function FleetSlotsPanel({ playerId, fleets = [] }: { playerId?: string; fleets?: FleetRef[] }) {
  const [slots, setSlots] = useState<SlotRow | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    if (!playerId) return
    const { data, error: e } = await supabase.rpc('get_player_fleet_slots')
    if (e) { setError(e.message); return }
    setSlots((data as SlotRow[] | null)?.[0] ?? null)
  }, [playerId])

  useEffect(() => { void refresh() }, [refresh])

  const recall = async (fleetId: string) => {
    if (!playerId) return
    setBusyId(fleetId); setError(null); setNotice(null)
    try {
      const { error: e } = await supabase.rpc('recall_fleet', { p_player_id: playerId, p_fleet_id: fleetId })
      if (e) throw e
      setNotice('Flota retirada: volverá con la carga intacta.')
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No se pudo retirar la flota.')
    } finally {
      setBusyId(null)
    }
  }

  const recallable = fleets.filter(f => f.status === 'OUTBOUND' || f.status === 'HOLDING')

  return <section className="neo-panel">
    <div className="fleet-group-head">
      <h2>SLOTS DE FLOTA</h2>
      <span>{slots ? `${slots.out_slots_available} / ${slots.out_max_slots} DISPONIBLES` : '—'}</span>
    </div>
    <div className="neo-definition-stats">
      <span>TECNOLOGÍA DE ORDENADORES <b>{slots ? slots.out_computer_technology_level : '—'}</b></span>
      <span>MÁXIMO <b>{slots ? slots.out_max_slots : '—'}</b></span>
      <span>EN VUELO <b>{slots ? slots.out_slots_in_use : '—'}</b></span>
      <span>LIBRES <b>{slots ? slots.out_slots_available : '—'}</b></span>
    </div>
    {recallable.length
      ? <div className="neo-card-grid">{recallable.map(f => <article className="neo-panel neo-definition" key={f.id}>
          <div className="neo-panel-title"><div><strong>{f.mission_type}</strong><small>{f.status}</small></div></div>
          <button type="button" className="neo-button" disabled={busyId === f.id} onClick={() => void recall(f.id)}>
            {busyId === f.id ? 'RETIRANDO…' : 'RETIRAR FLOTA'}
          </button>
        </article>)}</div>
      : <div className="neo-empty">No hay flotas retirables: solo se puede retirar una flota en vuelo o en espera.</div>}
    {notice && <p>{notice}</p>}
    {error && <p>{error}</p>}
  </section>
}


export function PlayerInboxPanel({ playerId }: { playerId?: string }) {
  const [rows, setRows] = useState<MessageRow[]>([])
  const [error, setError] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    if (!playerId) return
    const { data, error: e } = await supabase.rpc('get_player_messages', { p_limit: 50, p_unread_only: false })
    if (e) { setError(e.message); return }
    setRows((data as MessageRow[] | null) ?? [])
  }, [playerId])

  useEffect(() => { void refresh() }, [refresh])

  const markRead = async (id: string) => {
    setBusyId(id)
    try {
      const { error: e } = await supabase.rpc('mark_message_read', { p_message_id: id })
      if (e) throw e
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No se pudo marcar el mensaje.')
    } finally {
      setBusyId(null)
    }
  }

  return <section className="neo-panel">
    <div className="fleet-group-head">
      <h2>BANDEJA DEL JUGADOR</h2>
      <span>{rows.filter(r => !r.out_is_read).length} SIN LEER · {rows.length} TOTAL</span>
    </div>
    {error && <p>{error}</p>}
    {rows.length
      ? <div className="neo-list-panel">{rows.map(m => <article className="neo-list-row" key={m.out_message_id}>
          <div>
            <strong>{m.out_is_read ? '·' : '●'} {m.out_subject}</strong>
            <small>{m.out_body ?? ''}</small>
          </div>
          <span className={`status-pill ${m.out_is_read ? 'completed' : 'outbound'}`}>{m.out_is_read ? 'LEÍDO' : 'NUEVO'}</span>
          <div><small>FECHA</small><b>{stamp(m.out_created_at)}</b></div>
          {!m.out_is_read && <button type="button" className="neo-button" disabled={busyId === m.out_message_id}
            onClick={() => void markRead(m.out_message_id)}>MARCAR LEÍDO</button>}
        </article>)}</div>
      : <div className="neo-empty">Tu bandeja está vacía: los eventos de juego (combate, espionaje, flotas,
          expediciones, colonización, reciclaje) aparecerán aquí.</div>}
  </section>
}

/** Los nombres vienen de los contratos `ui_ship_definitions` / `ui_defense_definitions` /
 *  `ui_building_definitions` / `ui_research_definitions`; si un id no estuviera definido se muestra tal cual
 *  (nunca se inventa un nombre). El gating lo decide SIEMPRE el servidor: la UI sólo separa «no revelado» de
 *  «nada en el objetivo» con las banderas que devuelve el contrato. */
function unitSummary(units: Record<string, number> | null, names: Record<string, string>) {
  const entries = Object.entries(units ?? {})
  if (!entries.length) return null
  return entries.map(([id, qty]) => `${names[id] ?? id} ×${qty}`).join(' · ')
}

function levelSummary(levels: Record<string, number> | null, names: Record<string, string>) {
  const entries = Object.entries(levels ?? {})
  if (!entries.length) return null
  return entries.map(([id, lvl]) => `${names[id] ?? id} ${lvl}`).join(' · ')
}

export function EspionageReportsPanel({ playerId }: { playerId?: string }) {
  const [rows, setRows] = useState<ReportRow[]>([])
  const [names, setNames] = useState<Record<string, string>>({})
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!playerId) return
    void (async () => {
      const [ships, defenses, buildings, research] = await Promise.all([
        supabase.rpc('ui_ship_definitions'),
        supabase.rpc('ui_defense_definitions'),
        supabase.rpc('ui_building_definitions'),
        supabase.rpc('ui_research_definitions'),
      ])
      if (!ships.error && !defenses.error && !buildings.error && !research.error) {
        const map: Record<string, string> = {}
        ;(ships.data ?? []).forEach(s => { map[s.id] = s.name })
        ;(defenses.data ?? []).forEach(d => { map[d.id] = d.name })
        ;(buildings.data ?? []).forEach(b => { map[b.id] = b.name })
        ;(research.data ?? []).forEach(r => { map[r.id] = r.name })
        setNames(map)
      }
    })()
  }, [playerId])

  useEffect(() => {
    if (!playerId) return
    void (async () => {
      const { data, error: e } = await supabase.rpc('get_player_espionage_reports', { p_limit: 25 })
      if (e) { setError(e.message); return }
      setRows((data as ReportRow[] | null) ?? [])
    })()
  }, [playerId])

  return <section className="neo-panel">
    <div className="fleet-group-head"><h2>INFORMES DE ESPIONAJE</h2><span>{rows.length} INFORMES</span></div>
    {error && <p>{error}</p>}
    {rows.length
      ? <div className="neo-list-panel">{rows.map(r => {
          const ships = unitSummary(r.out_fleet, names)
          const defenses = unitSummary(r.out_defenses, names)
          const buildings = levelSummary(r.out_buildings, names)
          const research = levelSummary(r.out_research, names)
          return <article className="neo-list-row" key={r.out_report_id}>
            <div>
              <strong>{r.out_target_name ?? 'Objetivo'} [{r.out_galaxy}:{r.out_system}:{r.out_position}]</strong>
              <small>M {r.out_metal} · C {r.out_crystal} · D {r.out_deuterium} · energía {r.out_energy}</small>
              <small>NIVEL PROPIO {r.out_espionage_level} · OBJETIVO {r.out_target_espionage_level} ·
                sondas {r.out_probes_sent}{r.out_probes_lost > 0 ? ` (${r.out_probes_lost} perdidas)` : ''}</small>
              <small>NAVES {r.out_ships_revealed
                ? (ships ?? 'sin naves en el objetivo')
                : 'no reveladas (nivel de espionaje insuficiente)'}</small>
              <small>DEFENSAS {r.out_defenses_revealed
                ? (defenses ?? 'sin defensas en el objetivo')
                : 'no reveladas (nivel de espionaje insuficiente)'}</small>
              <small>EDIFICIOS {r.out_buildings_revealed
                ? (buildings ?? 'sin edificios en el objetivo')
                : 'no revelados (nivel de espionaje insuficiente)'}</small>
              <small>INVESTIGACIÓN {r.out_research_revealed
                ? (research ?? 'sin investigaciones en el objetivo')
                : 'no revelada (nivel de espionaje insuficiente)'}</small>
            </div>
            <span className={`status-pill ${r.out_counter_espionage_triggered ? 'cancelled' : 'completed'}`}>
              {r.out_counter_espionage_triggered ? 'CONTRAESPIONAJE' : `RIESGO ${r.out_counter_espionage_chance}%`}
            </span>
            <div><small>FECHA</small><b>{stamp(r.out_created_at)}</b></div>
          </article>
        })}</div>
      : <div className="neo-empty">Todavía no hay informes: envía sondas desde la vista de galaxia.</div>}
  </section>
}

export function RankingPanel({ playerId, universeId }: { playerId?: string; universeId?: string }) {
  const [rows, setRows] = useState<RankRow[]>([])
  const [category, setCategory] = useState<'GENERAL' | 'ECONOMY' | 'RESEARCH' | 'MILITARY'>('GENERAL')
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!playerId || !universeId) return
    void (async () => {
      // Conjunto de categorías de OGameX (economy/research/military + general).
      // Typed contract: the database.types.ts entry was added by the 2026-09-26 audit.
      const { data, error: e } = await supabase.rpc('get_universe_ranking_by_category', {
        p_universe_id: universeId,
        p_category: category,
        p_limit: 10,
      })
      if (e) { setError(e.message); return }
      setError(null)
      setRows((data as RankRow[] | null) ?? [])
    })()
  }, [playerId, universeId, category])

  const categories: Array<'GENERAL' | 'ECONOMY' | 'RESEARCH' | 'MILITARY'> = ['GENERAL', 'ECONOMY', 'RESEARCH', 'MILITARY']

  return <section className="neo-panel">
    <div className="fleet-group-head"><h2>CLASIFICACIÓN DEL UNIVERSO</h2><span>{category} · TOP {rows.length}</span></div>
    <div className="message-tabs">{categories.map(c =>
      <button type="button" key={c} className={category === c ? 'active' : ''} onClick={() => setCategory(c)}>{c}</button>)}</div>
    {error && <p>{error}</p>}
    {rows.length
      ? <div className="neo-list-panel">{rows.map(r => <article className="neo-list-row" key={r.out_player_id}>
          <div><strong>#{r.out_rank} {r.out_username}</strong><small>{r.out_player_type}</small></div>
          <span className="status-pill">{r.out_points}</span>
          {r.out_is_current_player && <span className="status-pill completed">TÚ</span>}
        </article>)}</div>
      : <div className="neo-empty">La clasificación se refresca cada 5 minutos.</div>}
  </section>
}

type ExpeditionReportRow = {
  fleet_id: string
  created_at: string
  resolved_at: string | null
  outcome: string | null
  event_type: string | null
  metal: number | null
  crystal: number | null
  deuterium: number | null
  dark_matter: number | null
  ships: unknown
  item_id: string | null
  item_name: string | null
  item_quantity: number | null
  merchant_resource: string | null
  battle_id: string | null
  delay_seconds: number | null
  speedup_seconds: number | null
  loss_percentage: number | null
}

function expeditionDetail(row: ExpeditionReportRow): string {
  const parts: string[] = []
  const metal = Number(row.metal ?? 0)
  const crystal = Number(row.crystal ?? 0)
  const deuterium = Number(row.deuterium ?? 0)
  if (metal > 0 || crystal > 0 || deuterium > 0) {
    parts.push(`recursos ${Math.floor(metal)} M / ${Math.floor(crystal)} C / ${Math.floor(deuterium)} D`)
  }
  if (Number(row.dark_matter ?? 0) > 0) parts.push(`materia oscura ${Math.floor(Number(row.dark_matter))}`)
  if (row.ships && typeof row.ships === 'object') {
    const entries = Object.entries(row.ships as Record<string, number>)
    if (entries.length > 0) parts.push(`naves ${entries.map(([id, qty]) => `${id}×${Number(qty)}`).join(', ')}`)
  }
  if (row.item_id) parts.push(`objeto ${row.item_name ?? row.item_id} ×${Number(row.item_quantity ?? 1)}`)
  if (row.merchant_resource) parts.push(`comerciante ${row.merchant_resource}`)
  if (row.battle_id) parts.push('combate')
  if (Number(row.loss_percentage ?? 0) > 0) parts.push(`pérdidas ${Math.floor(Number(row.loss_percentage))}%`)
  if (Number(row.delay_seconds ?? 0) > 0) parts.push(`retraso ${Math.floor(Number(row.delay_seconds))} s`)
  if (Number(row.speedup_seconds ?? 0) > 0) parts.push(`aceleración ${Math.floor(Number(row.speedup_seconds))} s`)
  return parts.length > 0 ? parts.join(' · ') : 'Sin recompensas registradas.'
}

/** Resultados de expedición tal como los devuelve `get_player_expedition_reports` (tabla con
 *  `deny_direct_api_access`: sólo se lee por contrato). */
export function ExpeditionReportsPanel({ playerId }: { playerId?: string }) {
  const [rows, setRows] = useState<ExpeditionReportRow[]>([])
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!playerId) return
    void (async () => {
      const { data, error: e } = await supabase.rpc('get_player_expedition_reports', { p_limit: 25 })
      if (e) { setError(e.message); return }
      setRows((data as ExpeditionReportRow[] | null) ?? [])
    })()
  }, [playerId])

  return <section className="neo-panel">
    <div className="fleet-group-head"><h2>RESULTADOS DE EXPEDICIÓN</h2><span>{rows.length} INFORMES</span></div>
    {error && <p>{error}</p>}
    {rows.length
      ? <div className="neo-list-panel">{rows.map(r => <article className="neo-list-row" key={r.fleet_id}>
          <div>
            <strong>{r.event_type ?? r.outcome ?? 'RESULTADO'}</strong>
            <small>{expeditionDetail(r)}</small>
          </div>
          <span className="status-pill">{r.outcome ?? '—'}</span>
          <div><small>RESUELTO</small><b>{stamp(r.resolved_at ?? r.created_at)}</b></div>
          <div><small>FLOTA</small><b>{r.fleet_id.slice(0, 8)}…</b></div>
        </article>)}</div>
      : <div className="neo-empty">Todavía no hay expediciones resueltas: lanza una y aparecerá aquí al volver.</div>}
  </section>
}

type MerchantOfferRow = {
  has_merchant: boolean
  offered_resource: string | null
  metal_rate: number | null
  crystal_rate: number | null
  deuterium_rate: number | null
  source: string | null
  created_at: string | null
  updated_at: string | null
}

type TradeResultRow = { sold: number; bought: number; bought_resource: string; remaining_merchant: boolean }

const MERCHANT_RESOURCES: Array<'METAL' | 'CRYSTAL' | 'DEUTERIUM'> = ['METAL', 'CRYSTAL', 'DEUTERIUM']

const fmtTradeRate = (value: number | null | undefined) => (value === null || value === undefined ? '—' : String(Number(value)))

/** Comerciante de expedición (OGameX `ExpeditionOutcomeType::GainMerchantTrade`).
 *
 *  Autoridad: `get_player_expedition_merchant` declara si hay oferta, qué recurso ENTREGA el comerciante y con
 *  qué cambios; `trade_with_expedition_merchant` ejecuta el comercio y devuelve `sold`/`bought` ya calculados.
 *  Este panel no deriva el cambio, no decide si hay comerciante y no envía ningún id de jugador: sólo el cuerpo
 *  activo, el recurso con el que se paga y la cantidad. `player_expedition_merchants` está cerrada al cliente,
 *  de modo que todo pasa por contrato. */
export function ExpeditionMerchantPanel({ playerId, bodyId, bodyLabel, onTraded }: {
  playerId?: string
  bodyId?: string | null
  bodyLabel?: string | null
  onTraded?: () => void
}) {
  const [offer, setOffer] = useState<MerchantOfferRow | null>(null)
  const [payWith, setPayWith] = useState<'METAL' | 'CRYSTAL' | 'DEUTERIUM'>('CRYSTAL')
  const [amount, setAmount] = useState('1000')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)

  /** Lee la oferta activa. Devuelve la fila (o null) y NO escribe estado: la escritura ocurre siempre después
   *  del `await`, tanto en la carga inicial como tras un comercio (mismo patrón que `ExpeditionReportsPanel`). */
  const fetchOffer = useCallback(async () => {
    if (!playerId) return null
    const { data, error: e } = await supabase.rpc('get_player_expedition_merchant')
    if (e) throw e
    return ((data as MerchantOfferRow[] | null) ?? [])[0] ?? null
  }, [playerId])

  useEffect(() => {
    if (!playerId) return
    void (async () => {
      try { setOffer(await fetchOffer()) }
      catch (err) { setError(err instanceof Error ? err.message : 'No se pudo leer el comerciante.') }
    })()
  }, [playerId, fetchOffer])

  /** El recurso con el que se paga no puede ser el que entrega el comerciante (regla del contrato). */
  const payable = MERCHANT_RESOURCES.filter(resource => resource !== offer?.offered_resource)
  const selected = payable.includes(payWith) ? payWith : (payable[0] ?? 'CRYSTAL')

  const trade = async () => {
    if (!bodyId) { setError('Selecciona un cuerpo activo para comerciar.'); return }
    const quantity = Number(amount)
    if (!Number.isFinite(quantity) || quantity <= 0) { setError('Indica una cantidad mayor que cero.'); return }
    setBusy(true); setError(null); setNotice(null)
    try {
      const { data, error: e } = await supabase.rpc('trade_with_expedition_merchant', {
        p_planet_id: bodyId,
        p_sell_resource: selected,
        p_sell_amount: quantity,
      })
      if (e) throw e
      const row = ((data as TradeResultRow[] | null) ?? [])[0]
      setNotice(row
        ? `Recibido ${Math.floor(row.bought)} ${row.bought_resource} a cambio de ${Math.floor(row.sold)} ${selected}. ${row.remaining_merchant ? 'El comerciante sigue disponible.' : 'El comerciante se marcha.'}`
        : 'Comercio realizado.')
      setOffer(await fetchOffer())
      onTraded?.()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No se pudo comerciar con el comerciante.')
    } finally { setBusy(false) }
  }

  if (!playerId) return null

  return <section className="neo-panel neo-definition">
    <div className="fleet-group-head">
      <h2>COMERCIANTE DE EXPEDICIÓN</h2>
      <span>{offer?.has_merchant ? 'OFERTA DISPONIBLE' : 'SIN OFERTA'} · {bodyLabel ?? 'SIN CUERPO'}</span>
    </div>
    {notice && <div className="neo-empty">{notice}</div>}
    {error && <div className="neo-empty">ERROR: {error}</div>}
    {offer?.has_merchant
      ? <>
          <div className="neo-definition-extra">
            <span>ENTREGA <b>{offer.offered_resource ?? '—'}</b></span>
            <span>CAMBIOS M/C/D <b>{fmtTradeRate(offer.metal_rate)} / {fmtTradeRate(offer.crystal_rate)} / {fmtTradeRate(offer.deuterium_rate)}</b></span>
            <span>ORIGEN <b>{offer.source ?? '—'}</b></span>
          </div>
          <div className="fleet-controls">
            <label>
              <span>PAGAS CON</span>
              <select value={selected} onChange={(event) => setPayWith(event.target.value as 'METAL' | 'CRYSTAL' | 'DEUTERIUM')}>
                {payable.map(resource => <option key={resource} value={resource}>{resource}</option>)}
              </select>
            </label>
            <label>
              <span>CANTIDAD</span>
              <input
                inputMode="numeric"
                value={amount}
                onChange={(event) => setAmount(event.target.value.replace(/[^0-9]/g, ''))}
              />
            </label>
          </div>
          <small>El servidor calcula el cambio y recorta la compra si no cabe en el almacén. El comerciante se
            marcha después del comercio.</small>
          <button type="button" className="neo-button" disabled={busy || !bodyId} onClick={() => void trade()}>
            {busy ? 'COMERCIANDO…' : `COMERCIAR DESDE ${bodyLabel ?? 'EL CUERPO ACTIVO'}`}
          </button>
        </>
      : <div className="neo-empty">Ningún comerciante disponible: aparece como resultado de una expedición
          (ganancia de comerciante) y queda a la espera de que lo uses. Los cambios son los de su oferta y no se
          pierde nada mientras no comercias.</div>}
  </section>
}

type MoonRow = {
  out_moon_id: string
  out_parent_planet_id: string
  out_parent_name: string | null
  out_name: string
  out_galaxy: number
  out_system: number
  out_position: number
  out_diameter_km: number
  out_fields_total: number
  out_fields_used: number
  out_cooldown_until: string | null
  out_metal: number
  out_crystal: number
  out_deuterium: number
  out_buildings: Record<string, number | string> | null
}

export function MoonsPanel({ playerId }: { playerId?: string }) {
  const [rows, setRows] = useState<MoonRow[]>([])
  const [error, setError] = useState<string | null>(null)
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    if (!playerId) return
    void (async () => {
      const { data, error: e } = await supabase.rpc('get_player_moons')
      if (e) { setError(e.message); return }
      setRows((data as MoonRow[] | null) ?? [])
    })()
  }, [playerId])

  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 30000)
    return () => window.clearInterval(timer)
  }, [])

  const cooldown = (until: string | null) => {
    if (!until) return 'LISTO'
    const left = Math.floor((new Date(until).getTime() - now) / 1000)
    return left > 0 ? `ENFRIANDO ${Math.ceil(left / 60)} min` : 'LISTO'
  }

  const level = (row: MoonRow, id: string) => Number(row.out_buildings?.[id] ?? 0)

  return <section className="neo-panel">
    <div className="fleet-group-head"><h2>LUNAS</h2><span>{rows.length} EN POSESIÓN</span></div>
    {error && <p>{error}</p>}
    {rows.length
      ? <div className="neo-list-panel">{rows.map(m => <article className="neo-list-row" key={m.out_moon_id}>
          <div>
            <strong>{m.out_name} [{m.out_galaxy}:{m.out_system}:{m.out_position}]</strong>
            <small>Orbita {m.out_parent_name ?? '—'} · diámetro {m.out_diameter_km} km</small>
          </div>
          <span className="status-pill">{m.out_fields_used} / {m.out_fields_total} CAMPOS</span>
          <div><small>BASE LUNAR</small><b>{level(m, 'lunar_base')}</b></div>
          <div><small>FALANX</small><b>{level(m, 'sensor_phalanx')}</b></div>
          <div><small>PUERTA DE SALTO</small><b>{level(m, 'jump_gate')}</b></div>
          <div><small>SALTO</small><b>{cooldown(m.out_cooldown_until)}</b></div>
          <div><small>M / C / D</small><b>{`${Math.floor(m.out_metal)} / ${Math.floor(m.out_crystal)} / ${Math.floor(m.out_deuterium)}`}</b></div>
        </article>)}</div>
      : <div className="neo-empty">Sin lunas: se forman cuando el campo de escombros de una batalla alcanza el tamaño
          mínimo y la tirada de creación acierta.</div>}
  </section>
}

