import { useState } from 'react'
import type { ReactNode } from 'react'
import { Panel, ScreenHeader, UIEngineScreen, type UIModuleMap } from '../../ui-engine'
import { useAlliance, useBuddies, useDefendReadiness } from '../../lib/useSocial'
import { socialModuleIds } from './socialRegistry'
import {
  AllianceApplyModule,
  AllianceCreateModule,
  AllianceMembersModule,
  AlliancePermissionsModule,
  AllianceStatusModule,
  BuddyIncomingModule,
  BuddyOutgoingModule,
  BuddyRequestModule,
  BuddiesListModule,
  DefendStatusModule,
} from './SocialModules'

/*
  PANTALLA SOCIAL (amigos/buddies + alianzas)

  La pantalla declara sus módulos y el template decide dónde vive cada uno; es el
  mismo patrón que FleetScreen. Toda la lógica está en los hooks (`useBuddies`,
  `useAlliance`) y toda la autoridad es del backend.

  Lo que NO se ofrece a propósito, porque ningún contrato lo respalda:
   - buscador de jugadores (no existe RPC de búsqueda);
   - listado de solicitudes de ingreso recibidas o propias (no existe RPC);
   - cualquier acción de DEFEND (su dispatch está bloqueado).
*/

export type SocialScreenProps = {
  /** Identidad del jugador para el estado de alianza; el backend resuelve el llamante. */
  playerId?: string
  /** Conocido por la navegación cuando existe; si falta, el estado se declara desconocido. */
  allianceId?: string | null
}

export function SocialScreen({ playerId, allianceId }: SocialScreenProps) {
  const buddies = useBuddies()
  const alliance = useAlliance({ playerId, allianceId })
  const defend = useDefendReadiness()
  const [confirmRemoval, setConfirmRemoval] = useState<string | null>(null)

  const modules: Record<string, ReactNode> = {
    [socialModuleIds.command]: (
      <ScreenHeader
        eyebrow="IMPERIO · RELACIONES"
        title="Social"
        description="Amigos y alianzas. Toda decisión de permiso y de ownership la toma el servidor."
        meta={`${buddies.friends.length} AMIGOS · ${buddies.incoming.length} RECIBIDAS`}
      />
    ),

    [socialModuleIds.buddies]: (
      <Panel title="Amigos" meta={`${buddies.friends.length}`} tone="accent">
        <BuddiesListModule model={buddies} />
      </Panel>
    ),

    [socialModuleIds.incoming]: (
      <Panel title="Solicitudes recibidas" meta={`${buddies.incoming.length}`}>
        <BuddyIncomingModule model={buddies} />
      </Panel>
    ),

    [socialModuleIds.outgoing]: (
      <Panel title="Solicitudes enviadas" meta={`${buddies.outgoing.length}`}>
        <BuddyOutgoingModule model={buddies} />
      </Panel>
    ),

    [socialModuleIds.buddyRequest]: (
      <Panel title="Enviar solicitud" tone="quiet">
        <BuddyRequestModule model={buddies} />
      </Panel>
    ),

[socialModuleIds.alliance]: (
      <Panel title="Mi alianza" tone="accent">
        <AllianceStatusModule model={alliance} />
        {alliance.alliance && (
          <div className="social-actions">
            {alliance.alliance.isFounder ? (
              // El fundador no puede "irse": el RPC lo rechaza con
              // ALLIANCE_FOUNDER_CANNOT_LEAVE. Se ofrece disolver, que es la
              // única salida real, y se explica el porqué.
              <button
                type="button"
                className="neo-button danger"
                disabled={alliance.busy}
                onClick={() => setConfirmRemoval('dissolve')}
              >
                DISOLVER ALIANZA
              </button>
            ) : (
              <button
                type="button"
                className="neo-button secondary"
                disabled={alliance.busy}
                onClick={() => setConfirmRemoval('leave')}
              >
                ABANDONAR ALIANZA
              </button>
            )}
            <p className="social-hint">
              {alliance.alliance.isFounder
                ? 'Como fundador no puedes abandonar: tendrías que disolver la alianza y perderla para todos.'
                : 'Abandonar elimina tu membresía; no afecta al resto de miembros.'}
            </p>
          </div>
        )}
      </Panel>
    ),

    [socialModuleIds.allianceCreate]: (
      <Panel title="Crear alianza" tone="quiet">
        <AllianceCreateModule model={alliance} />
      </Panel>
    ),

    [socialModuleIds.allianceApply]: (
      <Panel title="Solicitar ingreso" tone="quiet">
        <AllianceApplyModule model={alliance} />
      </Panel>
    ),

    [socialModuleIds.allianceMembers]: (
      <Panel title="Miembros" meta={alliance.alliance ? `${alliance.members.length}` : '—'}>
        <AllianceMembersModule model={alliance} />
      </Panel>
    ),

    [socialModuleIds.allianceRanks]: (
      <Panel title="Rangos y permisos" meta={alliance.alliance?.rankName ?? 'SIN ALIANZA'}>
        <AlliancePermissionsModule model={alliance} />
      </Panel>
    ),

    [socialModuleIds.defend]: (
      <Panel title="Estado DEFEND" tone="quiet">
        <DefendStatusModule state={defend.state} readiness={defend.readiness} />
      </Panel>
    ),
  }

  /**
   * Confirmación para la acción destructiva: quitar una amistad o disolver una
   * alianza no tiene vuelta atrás, así que se pide antes de enviar.
   */
  if (confirmRemoval !== null) {
    const isDissolve = confirmRemoval === 'dissolve'
    modules['messages.social-actions'] = (
      <Panel title="Confirmar" tone="accent">
        <p>
          {isDissolve
            ? '¿Disolver la alianza? Se eliminarán sus miembros, rangos y solicitudes. No se puede deshacer.'
            : '¿Abandonar la alianza? Perderás tu membresía y tu rango.'}
        </p>
        <div className="social-actions">
          <button
            type="button"
            className="neo-button danger"
            disabled={alliance.busy}
            onClick={() => {
              if (isDissolve) void alliance.dissolve()
              else void alliance.leave()
              setConfirmRemoval(null)
            }}
          >
            {isDissolve ? 'DISOLVER' : 'ABANDONAR'}
          </button>
          <button
            type="button"
            className="neo-button secondary"
            onClick={() => setConfirmRemoval(null)}
          >
            CANCELAR
          </button>
        </div>
      </Panel>
    )
  }

  return <UIEngineScreen id="social" modules={modules as UIModuleMap} />
}