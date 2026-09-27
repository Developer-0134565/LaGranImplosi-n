import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from './lib/supabase'

/*
  ACS_HOLD — autorizaciones de apoyo (concesión, revocación y descubrimiento).

  Autoridad: `grant_planet_support_authorization` y `revoke_planet_support_authorization` conceden/retiran la
  autorización (sólo el propietario del planeta destino, comprobado por el servidor), `start_support_fleet`
  revalida la autorización al enviar el apoyo y `get_player_support_authorizations()` — contrato de descubrimiento
  owner-scoped añadido en 20260926214030 — devuelve únicamente las autorizaciones no revocadas en las que el
  jugador es parte. Este panel no decide nada: muestra lo que responde el servidor y traduce sus rechazos.

  Identificación del invitado: sin directorio de jugadores. El propietario indica las COORDENADAS de un cuerpo
  visible (la galaxia ya publica `planets.player_id`) y el contrato de concesión valida el resto.
*/

type AuthorizationRow = {
  out_authorization_id: string
  out_direction: string
  out_destination_planet_id: string
  out_destination_name: string
  out_destination_kind: string
  out_galaxy: number
  out_system: number
  out_position: number
  out_owner_player_id: string
  out_owner_username: string
  out_guest_player_id: string
  out_guest_username: string
  out_authorized_at: string
  out_expires_at: string | null
  out_is_usable: boolean
}

type OwnPlanet = {
  id: string
  name: string
  galaxy: number
  system: number
  position: number
  kind: string
}

const stamp = (value: string | null | undefined) =>
  !value ? '—' : new Date(value).toLocaleString('es-ES')

const errorMessage = (value: unknown, fallback: string): string => {
  if (value instanceof Error) return value.message
  if (typeof value === 'object' && value !== null && 'message' in value) {
    const message = (value as { message?: unknown }).message
    if (typeof message === 'string' && message.length > 0) return message
  }
  return fallback
}

export function SupportAuthorizationPanel({
  playerId,
  universeId,
  onChanged,
}: {
  playerId?: string
  universeId?: string
  onChanged?: () => void
}) {
  const [rows, setRows] = useState<AuthorizationRow[]>([])
  const [planets, setPlanets] = useState<OwnPlanet[]>([])
  const [destinationId, setDestinationId] = useState('')
  const [guestGalaxy, setGuestGalaxy] = useState('')
  const [guestSystem, setGuestSystem] = useState('')
  const [guestPosition, setGuestPosition] = useState('')
  const [expiresAt, setExpiresAt] = useState('')
  const [busy, setBusy] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    if (!playerId) return
    const [authResult, planetResult] = await Promise.all([
      supabase.rpc('get_player_support_authorizations'),
      supabase
        .from('planets')
        .select('id,name,galaxy,system,position,kind')
        .eq('player_id', playerId)
        .eq('is_destroyed', false)
        .order('galaxy')
        .order('system')
        .order('position'),
    ])
    if (authResult.error) {
      setError(authResult.error.message)
      return
    }
    if (planetResult.error) {
      setError(planetResult.error.message)
      return
    }
    setRows((authResult.data ?? []) as AuthorizationRow[])
    setPlanets((planetResult.data ?? []) as OwnPlanet[])
  }, [playerId])

  useEffect(() => {
    void load()
  }, [load])

  const received = useMemo(() => rows.filter((row) => row.out_direction === 'RECEIVED'), [rows])
  const granted = useMemo(() => rows.filter((row) => row.out_direction === 'GRANTED'), [rows])

  async function grant() {
    if (!playerId || !destinationId) {
      setError('Selecciona uno de tus cuerpos como destino del apoyo.')
      return
    }
    if (!universeId) {
      setError('No se pudo identificar el universo activo.')
      return
    }
    const galaxy = Number.parseInt(guestGalaxy, 10)
    const system = Number.parseInt(guestSystem, 10)
    const position = Number.parseInt(guestPosition, 10)
    if (!Number.isFinite(galaxy) || !Number.isFinite(system) || !Number.isFinite(position)) {
      setError('Indica las coordenadas del invitado [galaxia:sistema:posición].')
      return
    }
    setBusy('grant')
    setError(null)
    setNotice(null)
    try {
      const { data: guestBody, error: lookupError } = await supabase
        .from('planets')
        .select('id,player_id,name,kind')
        .eq('universe_id', universeId)
        .eq('galaxy', galaxy)
        .eq('system', system)
        .eq('position', position)
        .eq('is_destroyed', false)
        .maybeSingle()
      if (lookupError) throw lookupError
      if (!guestBody?.player_id) throw new Error(`No hay un cuerpo habitado en [${galaxy}:${system}:${position}].`)
      const { error: grantError } = await supabase.rpc('grant_planet_support_authorization', {
        p_player_id: playerId,
        p_planet_id: destinationId,
        p_guest_player_id: guestBody.player_id,
        p_expires_at: expiresAt ? new Date(expiresAt).toISOString() : null,
      })
      if (grantError) throw grantError
      setNotice(`Autorización concedida al jugador de ${guestBody.name} [${galaxy}:${system}:${position}].`)
      setGuestGalaxy('')
      setGuestSystem('')
      setGuestPosition('')
      setExpiresAt('')
      await load()
      onChanged?.()
    } catch (grantError) {
      setError(errorMessage(grantError, 'No se pudo conceder la autorización.'))
    } finally {
      setBusy(null)
    }
  }

  async function revoke(row: AuthorizationRow) {
    if (!playerId) return
    setBusy(row.out_authorization_id)
    setError(null)
    setNotice(null)
    try {
      const { data: revoked, error: revokeError } = await supabase.rpc('revoke_planet_support_authorization', {
        p_player_id: playerId,
        p_planet_id: row.out_destination_planet_id,
        p_guest_player_id: row.out_guest_player_id,
      })
      if (revokeError) throw revokeError
      setNotice(
        revoked
          ? `Autorización retirada a ${row.out_guest_username}.`
          : 'El servidor no encontró una autorización vigente que retirar.',
      )
      await load()
      onChanged?.()
    } catch (revokeError) {
      setError(errorMessage(revokeError, 'No se pudo retirar la autorización.'))
    } finally {
      setBusy(null)
    }
  }

  return (
    <section className="neo-panel">
      <div className="fleet-group-head">
        <h2>AUTORIZACIONES DE APOYO (ACS_HOLD)</h2>
        <span>{rows.length} VIGENTES · {received.length} RECIBIDAS · {granted.length} CONCEDIDAS</span>
      </div>
      {notice && <p>{notice}</p>}
      {error && <p>ERROR: {error}</p>}
      <p>
        El apoyo sólo puede aterrizar en un cuerpo cuyo propietario lo haya autorizado. El propietario concede
        desde aquí indicando las coordenadas del invitado; el invitado ve lo que le han autorizado y lo elige al
        preparar la misión <b>APOYO ACS</b>. La autoridad sigue siendo del servidor: el envío revalida la
        autorización en el momento del despacho.
      </p>

      <div className="fleet-controls">
        <label>
          <span>MI CUERPO AUTORIZADO</span>
          <select value={destinationId} onChange={(event) => setDestinationId(event.target.value)}>
            {planets.length === 0 && <option value="">Sin cuerpos en posesión</option>}
            {planets.map((planet) => (
              <option key={planet.id} value={planet.id}>
                {planet.name} [{planet.galaxy}:{planet.system}:{planet.position}]
                {planet.kind === 'MOON' ? ' · LUNA' : ''}
              </option>
            ))}
          </select>
        </label>
        <label>
          <span>GALAXIA DEL INVITADO</span>
          <input inputMode="numeric" value={guestGalaxy} onChange={(event) => setGuestGalaxy(event.target.value.replace(/[^0-9]/g, ''))} />
        </label>
        <label>
          <span>SISTEMA</span>
          <input inputMode="numeric" value={guestSystem} onChange={(event) => setGuestSystem(event.target.value.replace(/[^0-9]/g, ''))} />
        </label>
        <label>
          <span>POSICIÓN</span>
          <input inputMode="numeric" value={guestPosition} onChange={(event) => setGuestPosition(event.target.value.replace(/[^0-9]/g, ''))} />
        </label>
        <label>
          <span>CADUCA (OPCIONAL)</span>
          <input type="datetime-local" value={expiresAt} onChange={(event) => setExpiresAt(event.target.value)} />
        </label>
        <button type="button" className="neo-button" disabled={busy === 'grant' || !destinationId} onClick={() => void grant()}>
          {busy === 'grant' ? 'CONCEDIENDO…' : 'CONCEDER APOYO'}
        </button>
      </div>

      {rows.length === 0 ? (
        <div className="neo-empty">
          No hay autorizaciones de apoyo vigentes: nadie te ha autorizado y tú no has autorizado a nadie.
        </div>
      ) : (
        <div className="neo-list-panel">
          {rows.map((row) => (
            <article className="neo-list-row" key={row.out_authorization_id}>
              <div>
                <strong>
                  {row.out_destination_name} [{row.out_galaxy}:{row.out_system}:{row.out_position}]
                  {row.out_destination_kind === 'MOON' ? ' · LUNA' : ''}
                </strong>
                <small>
                  {row.out_direction === 'RECEIVED'
                    ? `Te autoriza ${row.out_owner_username}`
                    : `Autorizas a ${row.out_guest_username}`}
                </small>
              </div>
              <span className={`status-pill ${row.out_is_usable ? 'completed' : 'cancelled'}`}>
                {row.out_direction === 'RECEIVED' ? 'RECIBIDA' : 'CONCEDIDA'}
              </span>
              <div>
                <small>DESDE <b>{stamp(row.out_authorized_at)}</b></small>
                <small>CADUCA <b>{stamp(row.out_expires_at)}</b></small>
              </div>
              <div>
                <small>ESTADO <b>{row.out_is_usable ? 'UTILIZABLE' : 'CADUCADA'}</b></small>
                {row.out_direction === 'GRANTED' && (
                  <button
                    type="button"
                    className="neo-button secondary"
                    disabled={busy === row.out_authorization_id}
                    onClick={() => void revoke(row)}
                  >
                    {busy === row.out_authorization_id ? 'RETIRANDO…' : 'RETIRAR'}
                  </button>
                )}
              </div>
            </article>
          ))}
        </div>
      )}
    </section>
  )
}