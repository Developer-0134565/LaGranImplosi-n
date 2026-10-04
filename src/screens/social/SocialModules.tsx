import { useState } from 'react'
import { ALLIANCE_PERMISSION_LABELS } from '../../lib/social'
import type { DefendReadiness } from '../../lib/social'
import type { AllianceModel, AsyncState, BuddyModel } from '../../lib/useSocial'

/*
  MÓDULOS DE PRESENTACIÓN DE LA PANTALLA SOCIAL

  Igual que en flota, un módulo NO conoce su posición: sólo declara contenido y
  el template decide la región. Ninguno reimplementa reglas de negocio: todas
  vienen del backend ya resueltas en los hooks.
*/

function StateMessage({ state, empty, children }: { state: AsyncState; empty: boolean; children: string }) {
  if (state === 'loading' || state === 'idle') {
    return (
      <p role="status" className="social-state social-state--loading">
        Cargando relaciones…
      </p>
    )
  }
  if (state === 'error') return null
  if (empty) {
    return (
      <p role="status" className="social-state social-state--empty">
        {children}
      </p>
    )
  }
  return null
}

/* --------------------------------------------------------------- amigos --- */

/** Lista de amigos aceptados, con acción destructiva de salida. */
export function BuddiesListModule({ model }: { model: BuddyModel }) {
  return (
    <div className="social-list">
      <StateMessage state={model.state} empty={model.friends.length === 0}>
        Todavía no tienes amigos. Envía una solicitud para empezar.
      </StateMessage>
      <ul className="social-rows">
        {model.friends.map((friend) => (
          <li key={friend.relationId} className="social-row">
            <span className="social-row__name">{friend.buddyUsername}</span>
            <button
              type="button"
              className="neo-button danger"
              disabled={model.busy}
              onClick={() => void model.removeFriend(friend.buddyPlayerId)}
              aria-label={`Eliminar a ${friend.buddyUsername} de tus amigos`}
            >
              ELIMINAR
            </button>
          </li>
        ))}
      </ul>
    </div>
  )
}

/** Solicitudes recibidas: sólo el destinatario puede responder (lo exige el RPC). */
export function BuddyIncomingModule({ model }: { model: BuddyModel }) {
  return (
    <div className="social-list">
      <StateMessage state={model.state} empty={model.incoming.length === 0}>
        No tienes solicitudes pendientes.
      </StateMessage>
      <ul className="social-rows">
        {model.incoming.map((relation) => (
          <li key={relation.relationId} className="social-row">
            <span className="social-row__name">{relation.buddyUsername}</span>
            <span className="social-row__actions">
              <button
                type="button"
                className="neo-button primary"
                disabled={model.busy}
                onClick={() => void model.respondRequest(relation.relationId, true)}
                aria-label={`Aceptar la solicitud de ${relation.buddyUsername}`}
              >
                ACEPTAR
              </button>
              <button
                type="button"
                className="neo-button secondary"
                disabled={model.busy}
                onClick={() => void model.respondRequest(relation.relationId, false)}
                aria-label={`Rechazar la solicitud de ${relation.buddyUsername}`}
              >
                RECHAZAR
              </button>
            </span>
          </li>
        ))}
      </ul>
    </div>
  )
}

/** Solicitudes enviadas: sólo el emisor puede cancelar. */
export function BuddyOutgoingModule({ model }: { model: BuddyModel }) {
  return (
    <div className="social-list">
      <StateMessage state={model.state} empty={model.outgoing.length === 0}>
        No has enviado solicitudes pendientes.
      </StateMessage>
      <ul className="social-rows">
        {model.outgoing.map((relation) => (
          <li key={relation.relationId} className="social-row">
            <span className="social-row__name">{relation.buddyUsername}</span>
            <button
              type="button"
              className="neo-button secondary"
              disabled={model.busy}
              onClick={() => void model.cancelRequest(relation.relationId)}
              aria-label={`Cancelar la solicitud enviada a ${relation.buddyUsername}`}
            >
              CANCELAR
            </button>
          </li>
        ))}
      </ul>
    </div>
  )
}

/**
 * Envío de solicitud por identificador de jugador.
 *
 * BLOQUEO DOCUMENTADO: no existe un RPC de búsqueda de jugadores en el contrato
 * social, así que NO se ofrece un buscador. El campo pide el UUID exacto, que es
 * lo que `send_buddy_request` consume. Añadir un buscador exigiría un contrato
 * nuevo, y esta misión no crea contratos.
 */
export function BuddyRequestModule({ model }: { model: BuddyModel }) {
  const [targetId, setTargetId] = useState('')
  const [message, setMessage] = useState('')

  return (
    <form
      className="social-form"
      onSubmit={(event) => {
        event.preventDefault()
        const value = targetId.trim()
        if (value.length === 0 || model.busy) return
        void model.sendRequest(value, message.trim() || undefined)
      }}
    >
      <label htmlFor="social-buddy-target">
        <span>ID DE JUGADOR (UUID)</span>
        <input
          id="social-buddy-target"
          value={targetId}
          onChange={(event) => setTargetId(event.target.value)}
          placeholder="00000000-0000-0000-0000-000000000000"
        />
      </label>
      <label htmlFor="social-buddy-message">
        <span>MENSAJE (OPCIONAL)</span>
        <input
          id="social-buddy-message"
          value={message}
          maxLength={500}
          onChange={(event) => setMessage(event.target.value)}
          placeholder="Hasta 500 caracteres"
        />
      </label>
      <p className="social-hint">
        No hay búsqueda de jugadores en el contrato actual: introduce el identificador exacto.
      </p>
      <button
        type="submit"
        className="neo-button primary"
        disabled={model.busy || targetId.trim().length === 0}
      >
        ENVIAR SOLICITUD
      </button>
    </form>
  )
}

/* --------------------------------------------------------------- alianzas -- */

/** Estado de membresía del jugador. Si no hay alliance, lo dice explícitamente. */
export function AllianceStatusModule({ model }: { model: AllianceModel }) {
  if (model.state === 'loading' || model.state === 'idle') {
    return (
      <p role="status" className="social-state social-state--loading">
        Consultando tu alianza…
      </p>
    )
  }
  if (!model.alliance) {
    return (
      <p role="status" className="social-state social-state--empty">
        No perteneces a ninguna alianza. Puedes fundar una o solicitar ingreso en otra.
      </p>
    )
  }
  const { alliance } = model
  return (
    <dl className="social-definition">
      <div>
        <dt>ROL</dt>
        <dd>{alliance.isFounder ? 'FUNDADOR' : 'MIEMBRO'}</dd>
      </div>
      <div>
        <dt>RANGO</dt>
        <dd>{alliance.rankName ?? 'SIN RANGO'}</dd>
      </div>
      <div>
        <dt>IDENTIFICADOR</dt>
        <dd className="social-mono">{alliance.allianceId}</dd>
      </div>
      <div>
        <dt>MIEMBROS</dt>
        <dd>{model.members.length}</dd>
      </div>
    </dl>
  )
}

/** Fundación de alianza. Respeta la validación del servidor (tag 3-8, nombre 3-30). */
export function AllianceCreateModule({ model }: { model: AllianceModel }) {
  const [tag, setTag] = useState('')
  const [name, setName] = useState('')

  if (model.alliance) {
    return (
      <p role="status" className="social-state social-state--empty">
        Ya perteneces a una alianza: no puedes fundar otra.
      </p>
    )
  }

  return (
    <form
      className="social-form"
      onSubmit={(event) => {
        event.preventDefault()
        if (model.busy) return
        void model.create(tag.trim(), name.trim())
      }}
    >
      <label htmlFor="social-alliance-tag">
        <span>ETIQUETA (3-8 ALFANUMÉRICOS)</span>
        <input
          id="social-alliance-tag"
          value={tag}
          maxLength={8}
          onChange={(event) => setTag(event.target.value)}
        />
      </label>
      <label htmlFor="social-alliance-name">
        <span>NOMBRE (3-30)</span>
        <input
          id="social-alliance-name"
          value={name}
          maxLength={30}
          onChange={(event) => setName(event.target.value)}
        />
      </label>
      <button type="submit" className="neo-button primary" disabled={model.busy}>
        FUNDAR ALIANZA
      </button>
    </form>
  )
}

/**
 * Solicitud de ingreso. Requiere el id de la alianza: el contrato social no
 * expone un listado de alianzas al que elegir, así que no se simula un selector.
 */
export function AllianceApplyModule({ model }: { model: AllianceModel }) {
  const [allianceId, setAllianceId] = useState('')
  const [message, setMessage] = useState('')

  if (model.alliance) {
    return (
      <p role="status" className="social-state social-state--empty">
        Ya tienes alianza: no puedes solicitar ingreso en otra.
      </p>
    )
  }

  return (
    <form
      className="social-form"
      onSubmit={(event) => {
        event.preventDefault()
        const value = allianceId.trim()
        if (value.length === 0 || model.busy) return
        void model.apply(value, message.trim() || undefined)
      }}
    >
      <label htmlFor="social-apply-alliance">
        <span>ID DE ALIANZA</span>
        <input
          id="social-apply-alliance"
          value={allianceId}
          onChange={(event) => setAllianceId(event.target.value)}
        />
      </label>
      <label htmlFor="social-apply-message">
        <span>MENSAJE (OPCIONAL)</span>
        <input
          id="social-apply-message"
          value={message}
          maxLength={500}
          onChange={(event) => setMessage(event.target.value)}
        />
      </label>
      <p className="social-hint">
        El contrato no lista alianzas abiertas: introduces el identificador exacto.
      </p>
      <button
        type="submit"
        className="neo-button primary"
        disabled={model.busy || allianceId.trim().length === 0}
      >
        SOLICITAR INGRESO
      </button>
    </form>
  )
}

/** Roster visible. El backend ya lo filtra por `see_members`. */
export function AllianceMembersModule({ model }: { model: AllianceModel }) {
  if (!model.alliance) {
    return (
      <p role="status" className="social-state social-state--empty">
        Sin alianza no hay miembros que mostrar.
      </p>
    )
  }
  return (
    <div className="social-list">
      <StateMessage state={model.state} empty={model.members.length === 0}>
        El roster no es visible con tus permisos actuales.
      </StateMessage>
      <ul className="social-rows">
        {model.members.map((member) => (
          <li key={member.playerId} className="social-row">
            <span className="social-row__name">{member.username}</span>
            <span className="social-row__meta">
              {member.isFounder ? 'FUNDADOR' : member.rankName ?? 'SIN RANGO'}
            </span>
          </li>
        ))}
      </ul>
    </div>
  )
}

/**
 * Permisos del llamante, tal y como los resolvió el servidor. Muestra sólo lo
 * concedido: la UI no reimplementa la regla de permisos.
 */
export function AlliancePermissionsModule({ model }: { model: AllianceModel }) {
  if (!model.alliance) {
    return (
      <p role="status" className="social-state social-state--empty">
        Los permisos pertenecen a una alianza.
      </p>
    )
  }
  const granted = [...model.alliance.permissions]
  if (granted.length === 0) {
    return (
      <p role="status" className="social-state social-state--empty">
        Tu rango no tiene permisos administrativos asignados.
      </p>
    )
  }
  return (
    <ul className="social-rows">
      {granted.map((permission) => (
        <li key={permission} className="social-row">
          <span className="social-row__name">{ALLIANCE_PERMISSION_LABELS[permission]}</span>
          <span className="social-row__meta social-mono">{permission}</span>
        </li>
      ))}
    </ul>
  )
}

/* ------------------------------------------------------------------ DEFEND -- */

/**
 * Estado REAL de DEFEND según el servidor. No es un interruptor: deja claro que
 * el despacho y el combate siguen bloqueados por el rediseño multi-flota.
 */
export function DefendStatusModule({ state, readiness }: { state: AsyncState; readiness: DefendReadiness | null }) {
  if (state === 'loading' || state === 'idle') {
    return (
      <p role="status" className="social-state social-state--loading">
        Consultando el estado de DEFEND…
      </p>
    )
  }
  if (!readiness) {
    return (
      <p role="status" className="social-state social-state--empty">
        El servidor no informó del estado de DEFEND.
      </p>
    )
  }
  return (
    <>
      <dl className="social-definition">
        <div>
          <dt>ESQUEMA</dt>
          <dd>{readiness.schemaReady ? 'LISTO' : 'NO LISTO'}</dd>
        </div>
        <div>
          <dt>AUTORIZACIÓN SOCIAL</dt>
          <dd>{readiness.authorizationReady ? 'LISTA' : 'NO LISTA'}</dd>
        </div>
        <div>
          <dt>DESPACHO</dt>
          <dd>{readiness.dispatchOpen ? 'ABIERTO' : 'BLOQUEADO'}</dd>
        </div>
        <div>
          <dt>COMBATE MULTI-FLOTA</dt>
          <dd>{readiness.combatReady ? 'LISTO' : 'PENDIENTE'}</dd>
        </div>
      </dl>
      <p className="social-hint">{readiness.blockingReason}</p>
    </>
  )
}