import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  ALLIANCE_PERMISSIONS,
  SocialRpcError,
  applyToAlliance,
  cancelBuddyRequest,
  createAlliance,
  createAllianceRank,
  defendDispatchReadiness,
  dissolveAlliance,
  leaveAlliance,
  listAllianceMembers,
  listBuddyRelations,
  removeBuddy,
  respondAllianceApplication,
  respondBuddyRequest,
  sendBuddyRequest,
  setAllianceMemberRank,
  type AllianceMemberRow,
  type AlliancePermission,
  type BuddyRelation,
  type DefendReadiness,
} from './social'

/*
  HOOKS DE LA CAPA SOCIAL

  Reglas que respetan estos hooks:
   - Estados explícitos: `loading`, `error` y `empty` son DATOS, no excepciones
     ocultas. La UI nunca afirma "vacío" mientras la petición sigue en curso.
   - INVALIDACIÓN COHERENTE: toda mutación vuelve a leer el estado desde el
     servidor. No se muta la caché localmente: si el servidor dice otra cosa,
     manda el servidor.
   - SIN CARRERAS: cada carga lleva un contador monótono; si dos cargas se
     solapan, sólo la última escribe estado.
   - SIN LLAMADAS DUPLICADAS: una acción en curso deshabilita el control y el hook
     ignora el segundo intento, en lugar de enviar dos peticiones.
   - La identidad la resuelve el backend con auth.uid(): aquí nunca se envía un
     `playerId` de llamante.
*/

export type AsyncState = 'idle' | 'loading' | 'ready' | 'error'

/** Error de una acción, conservando el código del servidor para la UI. */
export type SocialFailure = { message: string; code: string; operation: string }

function toFailure(operation: string, error: unknown): SocialFailure {
  if (error instanceof SocialRpcError) {
    return { message: error.message, code: error.code, operation: error.operation }
  }
  return {
    message: error instanceof Error ? error.message : 'Error desconocido',
    code: 'UNEXPECTED',
    operation,
  }
}

/**
 * Referencia de carga en curso. Permite descartar respuestas obsoletas: si el
 * usuario relanza la carga antes de que responda la anterior, la respuesta vieja
 * ya no debe escribir estado.
 */
function useLoadGuard() {
  const runId = useRef(0)
  const next = useCallback(() => {
    runId.current += 1
    return runId.current
  }, [])
  // `candidate` evita sombrear el ref `runId`: si se llamara igual, la
  // comparación sería `number === number` y siempre sería cierta.
  const isCurrent = useCallback((candidate: number) => runId.current === candidate, [])
  return { next, isCurrent }
}

/* ============================================================== BUDDIES ==== */

export type BuddyModel = {
  state: AsyncState
  error: SocialFailure | null
  /** Amistades aceptadas: la lista de amigos. */
  friends: BuddyRelation[]
  /** Solicitudes que espera este jugador. */
  incoming: BuddyRelation[]
  /** Solicitudes que este jugador ha enviado y siguen abiertas. */
  outgoing: BuddyRelation[]
  isEmpty: boolean
  busy: boolean
  refresh: () => Promise<void>
  sendRequest: (addresseePlayerId: string, message?: string) => Promise<boolean>
  respondRequest: (relationId: string, accept: boolean) => Promise<boolean>
  cancelRequest: (relationId: string) => Promise<boolean>
  removeFriend: (buddyPlayerId: string) => Promise<boolean>
  clearError: () => void
}

export function useBuddies(): BuddyModel {
  const [relations, setRelations] = useState<BuddyRelation[]>([])
  // Nace en 'loading': el primer renderizado no puede afirmar que no hay
  // relaciones mientras la consulta todavía no ha respondido.
  const [state, setState] = useState<AsyncState>('loading')
  const [error, setError] = useState<SocialFailure | null>(null)
  const [busy, setBusy] = useState(false)
  const guard = useLoadGuard()

  /** Carga real. Igual que los loaders de `useFleetDispatch`, NO escribe estado
   *  antes del primer `await`: así el efecto que la dispara no encadena renders
   *  (regla react-hooks/set-state-in-effect). El estado nace en 'loading'. */
  const load = useCallback(async () => {
    const runId = guard.next()
    try {
      const rows = await listBuddyRelations()
      // Descarta la respuesta si mientras cargaba se lanzó otra más nueva.
      if (!guard.isCurrent(runId)) return
      setRelations(rows)
      setError(null)
      setState('ready')
    } catch (cause) {
      if (!guard.isCurrent(runId)) return
      setError(toFailure('list_buddies', cause))
      setState('error')
    }
  }, [guard])

  /**
   * Entrada PÚBLICA de carga. El efecto y los refrescos manuales usan esta, no
   * `load`: marcar 'loading' aquí sí es correcto porque ocurre en un manejador de
   * evento o en un microtask, nunca de forma síncrona dentro del efecto.
   */
  const refresh = useCallback(async () => {
    setState('loading')
    await load()
  }, [load])

  useEffect(() => {
    // El estado inicial ya es 'loading', así que el efecto sólo dispara la
    // lectura sin provocar un render en cascada.
    void load()
  }, [load])

  /**
   * Envuelve una mutación: marca busy, ejecuta, refresca desde el servidor y
   * devuelve si tuvo éxito. El segundo clic durante el vuelo se ignora.
   */
  const runMutation = useCallback(
    async (operation: string, action: () => Promise<void>): Promise<boolean> => {
      if (busy) return false
      setBusy(true)
      setError(null)
      try {
        await action()
        await refresh()
        return true
      } catch (cause) {
        const failure = toFailure(operation, cause)
        setError(failure)
        // El detalle técnico se conserva para el log; la UI decide cómo mostrarlo.
        console.error(`[social] ${operation}`, failure.code, failure.message)
        return false
      } finally {
        setBusy(false)
      }
    },
    [busy, refresh],
  )

  const friends = useMemo(
    () => relations.filter((relation) => relation.status === 'ACCEPTED'),
    [relations],
  )
  const incoming = useMemo(
    () =>
      relations.filter(
        (relation) => relation.status === 'PENDING' && relation.direction === 'INCOMING_PENDING',
      ),
    [relations],
  )
  const outgoing = useMemo(
    () =>
      relations.filter(
        (relation) => relation.status === 'PENDING' && relation.direction === 'OUTGOING_PENDING',
      ),
    [relations],
  )

  return {
    state,
    error,
    friends,
    incoming,
    outgoing,
    // `empty` sólo es verdadero cuando la carga TERMINÓ bien y no hay nada:
    // durante la carga no se afirma que esté vacío, se afirma que no se sabe.
    isEmpty: state === 'ready' && relations.length === 0,
    busy,
    refresh,
    sendRequest: (addresseePlayerId, message) =>
      runMutation('send_buddy_request', () => sendBuddyRequest(addresseePlayerId, message)),
    respondRequest: (relationId, accept) =>
      runMutation('respond_buddy_request', () => respondBuddyRequest(relationId, accept)),
    cancelRequest: (relationId) =>
      runMutation('cancel_buddy_request', () => cancelBuddyRequest(relationId)),
    removeFriend: (buddyPlayerId) => runMutation('remove_buddy', () => removeBuddy(buddyPlayerId)),
    clearError: () => setError(null),
  }
}

/* ============================================================ ALIANCES ==== */

export type AllianceSummary = {
  allianceId: string
  isFounder: boolean
  rankName: string | null
  /** Permisos del llamante, resueltos por el SERVIDOR, nunca inferidos aquí. */
  permissions: ReadonlySet<AlliancePermission>
}

export type AllianceModel = {
  state: AsyncState
  error: SocialFailure | null
  /** null = el jugador NO pertenece a ninguna alianza. */
  alliance: AllianceSummary | null
  members: AllianceMemberRow[]
  isEmpty: boolean
  busy: boolean
  canManageApplications: boolean
  canManageClasses: boolean
  refresh: () => Promise<void>
  create: (tag: string, name: string) => Promise<boolean>
  apply: (allianceId: string, message?: string) => Promise<boolean>
  respondApplication: (applicationId: string, accept: boolean) => Promise<boolean>
  leave: () => Promise<boolean>
  dissolve: () => Promise<boolean>
  createRank: (name: string, permissions: readonly AlliancePermission[]) => Promise<boolean>
  assignRank: (playerId: string, rankId: string | null) => Promise<boolean>
  clearError: () => void
}

export type UseAllianceArgs = {
  /**
   * Identidad del JUGADOR (no del usuario de auth). Se usa SÓLO para leer el
   * propio estado; las mutaciones nunca lo envían como llamante, porque el
   * backend lo resuelve con auth.uid().
   */
  playerId?: string
  /** Si se conoce, evita un viaje de descubrimiento. */
  allianceId?: string | null
}

/**
 * Estado de alianza del jugador.
 *
 * NOTA DE ALCANCE DEL CONTRATO: las migraciones sociales NO exponen un RPC para
 * "mis propias solicitudes de ingreso" ni para "listar las solicitudes recibidas
 * de mi alianza". Este hook NO inventa esas listas y la UI no ofrece esos
 * botones: prometerían una acción que ningún contrato puede cumplir. `apply()` y
 * `respondApplication()` sí existen. La vista de solicitudes pendientes queda
 * documentada como bloqueo, no simulada.
 *
 * Descubrimiento: `list_alliance_members` exige `alliance_id`. Sin él no hay
 * contrato de "mi alianza", así que el estado es honestamente desconocido en vez
 * de adivinado; la navegación debe pasar el allianceId cuando lo conozca.
 */
export function useAlliance({ playerId, allianceId }: UseAllianceArgs = {}): AllianceModel {
  const [members, setMembers] = useState<AllianceMemberRow[]>([])
  const [resolvedId, setResolvedId] = useState<string | null>(allianceId ?? null)
  const [state, setState] = useState<AsyncState>('loading')
  const [error, setError] = useState<SocialFailure | null>(null)
  const [busy, setBusy] = useState(false)
  const guard = useLoadGuard()

  /**
 * Igual que en `useBuddies`: ninguna escritura de estado antes del primer
 * `await`, para que el efecto que dispara la lectura no encadena renders
 * (react-hooks/set-state-in-effect). El `await` inicial es lo que hace que
 * TODAS las rutas de escritura ocurran de forma asíncrona.
 */
  const load = useCallback(async () => {
    const runId = guard.next()
    const target = playerId ? allianceId ?? resolvedId : null

    try {
      // Sin identidad no hay nada que consultar. El `await` mantiene la
      // escritura fuera de la ruta síncrona del efecto.
      await Promise.resolve()
      if (!guard.isCurrent(runId)) return

      if (!playerId || !target) {
        // Sin identidad o sin allianceId conocido el estado es 'desconocido',
        // no 'sin alianza': no se afirma una membresía que no se ha consultado.
        setMembers([])
        setResolvedId(null)
        setError(null)
        setState(playerId ? 'ready' : 'idle')
        return
      }

      const rows = await listAllianceMembers(target)
      if (!guard.isCurrent(runId)) return

      const me = rows.find((member) => member.playerId === playerId) ?? null
      setError(null)
      if (!me) {
        // 0 filas visibles = este jugador no pertenece a la alianza (o no ve el
        // roster). No se inventa una membresía para rellenar la pantalla.
        setMembers([])
        setResolvedId(null)
        setState('ready')
        return
      }

      setMembers(rows)
      setResolvedId(target)
      setState('ready')
    } catch (cause) {
      if (!guard.isCurrent(runId)) return
      setError(toFailure('list_alliance_members', cause))
      setState('error')
    }
  }, [allianceId, playerId, resolvedId, guard])

  /** Entrada pública: aquí sí es correcto marcar 'loading' (no va en el efecto). */
  const refresh = useCallback(async () => {
    setState('loading')
    await load()
  }, [load])

  useEffect(() => {
    // El estado inicial ya es 'loading': el efecto sólo dispara la lectura.
    void load()
  }, [load])

  const me = useMemo(
    () => (playerId ? members.find((member) => member.playerId === playerId) ?? null : null),
    [members, playerId],
  )

  const permissions = useMemo(() => new Set<AlliancePermission>(me?.permissions ?? []), [me])

  const alliance: AllianceSummary | null = useMemo(() => {
    if (!resolvedId || !me) return null
    return { allianceId: resolvedId, isFounder: me.isFounder, rankName: me.rankName, permissions }
  }, [me, permissions, resolvedId])

const runMutation = useCallback(
    async (operation: string, action: () => Promise<void>): Promise<boolean> => {
      if (busy) return false
      setBusy(true)
      setError(null)
      try {
        await action()
        await refresh()
        return true
      } catch (cause) {
        const failure = toFailure(operation, cause)
        setError(failure)
        console.error(`[social] ${operation}`, failure.code, failure.message)
        return false
      } finally {
        setBusy(false)
      }
    },
    [busy, refresh],
  )

  return {
    state,
    error,
    alliance,
    members,
    isEmpty: state === 'ready' && members.length === 0,
    busy,
    // El permiso se pide al SERVIDOR: la UI no lo deduce ni lo reimplementa.
    canManageApplications: permissions.has('edit_applications'),
    canManageClasses: permissions.has('manage_classes'),
    refresh,
    create: (tag, name) => runMutation('create_alliance', async () => { await createAlliance(tag, name) }),
    apply: (id, message) => runMutation('apply_to_alliance', async () => { await applyToAlliance(id, message) }),
    respondApplication: (applicationId, accept) =>
      runMutation('respond_alliance_application', async () => {
        await respondAllianceApplication(applicationId, accept)
      }),
    leave: () => runMutation('leave_alliance', async () => { await leaveAlliance() }),
    dissolve: () => runMutation('dissolve_alliance', async () => { await dissolveAlliance() }),
    createRank: (name, perms) =>
      runMutation('create_alliance_rank', async () => { await createAllianceRank(name, perms) }),
    assignRank: (id, rankId) =>
      runMutation('set_alliance_member_rank', async () => { await setAllianceMemberRank(id, rankId) }),
    clearError: () => setError(null),
  }
}

/* =============================================================== DEFEND ==== */

/**
 * Readiness de DEFEND tal y como la informa el servidor. Se expone sólo para
 * mostrar el estado real: NO habilita ninguna acción de dispatch, que sigue
 * bloqueado por el rediseño multi-flota.
 */
export function useDefendReadiness(): { state: AsyncState; readiness: DefendReadiness | null } {
  // Nace en 'loading': no se afirma nada antes de que el servidor responda.
  const [readiness, setReadiness] = useState<DefendReadiness | null>(null)
  const [state, setState] = useState<AsyncState>('loading')
  const guard = useLoadGuard()

  useEffect(() => {
    let cancelled = false
    const runId = guard.next()
    // Sin `setState` síncrono dentro del efecto: el estado inicial ya es
    // 'loading' y el resultado se escribe al resolver la promesa.
    void defendDispatchReadiness()
      .then((value) => {
        if (cancelled || !guard.isCurrent(runId)) return
        setReadiness(value)
        setState('ready')
      })
      .catch(() => {
        if (cancelled || !guard.isCurrent(runId)) return
        setState('error')
      })
    // Cleanup explícito: al desmontar no se escribe estado en un componente muerto.
    return () => {
      cancelled = true
    }
  }, [guard])

  return { state, readiness }
}

/** Vocabulario de permisos expuesto para los controles de la UI. */
export { ALLIANCE_PERMISSIONS }