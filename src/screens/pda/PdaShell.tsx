/* =============================================================================
   PDA SHELL v1 — PERSONAL DATA ASSISTANT
   -----------------------------------------------------------------------------
   Nueva SUPERFICIE de interfaz (contenedor modular), no un sistema nuevo.

   Reglas duras de esta misión (v1):
     * 0 migraciones, 0 RPC nuevas, 0 cambios de gameplay.
     * MESSAGES / NOTIFICATIONS / IA ASSISTANT / MINI-GAMES son PLACEHOLDERS.
       NO se migra aqui el panel de mensajes existente: la PDA sera el destino
       futuro de ese sistema, para que la verdad siga teniendo UNA sola fuente.
     * La IA NO esta conectada a ningun proveedor, no hace fetch, no envia datos
       a terceros. La restriccion owner-scoped (auth.uid()) queda DOCUMENTADA
       para la mision futura que implemente el modelo.

   Se reusan los componentes y variables `--neo-*` que ya usa el resto de LGI:
   la PDA no introduce una segunda estetica.
   ========================================================================== */

import { useState, type ReactNode } from 'react'
import { GalagaCanvas } from './games/GalagaCanvas'

export type PdaModuleId = 'OVERVIEW' | 'MESSAGES' | 'NOTIFICATIONS' | 'IA' | 'GAMES'

type PdaModule = { id: PdaModuleId; label: string; glyph: string; pending?: boolean }

const MODULES: PdaModule[] = [
  { id: 'OVERVIEW', label: 'Overview', glyph: '◈' },
  { id: 'MESSAGES', label: 'Messages', glyph: '✉', pending: true },
  { id: 'NOTIFICATIONS', label: 'Notifications', glyph: '◭', pending: true },
  { id: 'IA', label: 'IA Assistant', glyph: '◆', pending: true },
  { id: 'GAMES', label: 'Mini-Games', glyph: '✦', pending: true },
]

/** Placeholder generico para modulos cuya mision aun no existe. */
function PdaPlaceholder({ title, children, points }: { title: string; children: ReactNode; points?: string[] }) {
  return (
    <div className="pda-placeholder">
      <h3>{title}</h3>
      <p>{children}</p>
      {points && points.length > 0 && (
        <ul>
          {points.map(point => (
            <li key={point}>{point}</li>
          ))}
        </ul>
      )}
    </div>
  )
}

/* ---------------------------------------------------------------------------
   OVERVIEW — solo consume informacion que la app YA tiene en memoria.
   No consulta nada por su cuenta: 0 llamadas nuevas, 0 contratos nuevos.
   ------------------------------------------------------------------------- */

export type PdaOverviewProps = {
  playerName: string
  bodyName: string | null
  bodyCoordinates: string | null
  isMoon: boolean
  resourceSummary: { metal: number; crystal: number; deuterium: number; energyBalancePerHour: number }
  counters: { planets: number; moons: number; reports: number }
}

function PdaOverview({ playerName, bodyName, bodyCoordinates, isMoon, resourceSummary, counters }: PdaOverviewProps) {
  const fmt = (value: number) => new Intl.NumberFormat('es-ES', { maximumFractionDigits: 0 }).format(value)
  return (
    <>
      <div className="pda-module-head">
        <h2>OVERVIEW</h2>
        <p>Estado del imperio leido de los contratos que la aplicacion ya consume. La PDA no decide nada.</p>
      </div>
      <div className="pda-stats">
        <div className="pda-stat"><small>CAPITAN</small><b>{playerName}</b></div>
        <div className="pda-stat"><small>CUERPO ACTIVO</small><b>{bodyName ?? '-'}</b></div>
        <div className="pda-stat"><small>TIPO</small><b>{isMoon ? 'LUNA' : 'PLANETA'}</b></div>
        <div className="pda-stat"><small>COORDENADAS</small><b>{bodyCoordinates ?? '-'}</b></div>
        <div className="pda-stat"><small>METAL</small><b>{fmt(resourceSummary.metal)}</b></div>
        <div className="pda-stat"><small>CRISTAL</small><b>{fmt(resourceSummary.crystal)}</b></div>
        <div className="pda-stat"><small>DEUTERIO</small><b>{fmt(resourceSummary.deuterium)}</b></div>
        {/* ENERGIA is a BALANCE, not a stock. The previous `energy` field came from
            `planet_resources.energy`, a column the engine never writes outside resets, so this tile
            always rendered 0. The contract already returns the authoritative figure. */}
        <div className="pda-stat"><small>ENERGIA /H</small><b>{fmt(resourceSummary.energyBalancePerHour)}</b></div>
        <div className="pda-stat"><small>PLANETAS</small><b>{fmt(counters.planets)}</b></div>
        <div className="pda-stat"><small>LUNAS</small><b>{fmt(counters.moons)}</b></div>
        <div className="pda-stat"><small>INFORMES</small><b>{fmt(counters.reports)}</b></div>
      </div>
    </>
  )
}

/* ---------------------------------------------------------------------------
   MESSAGES — placeholder. NO se migra aqui el panel de mensajes existente.
   ------------------------------------------------------------------------- */

function PdaMessages({ inbox }: { inbox?: ReactNode }) {
  return (
    <>
      <div className="pda-module-head">
        <h2>MESSAGES</h2>
        <p>Bandeja e informes del imperio. La autoridad sigue siendo el sistema de mensajes existente.</p>
      </div>
      {inbox ?? (
        <PdaPlaceholder title="SIN BANDEJA MONTADA">
          Este contenedor deberia montar el consumidor de mensajes existente.
        </PdaPlaceholder>
      )}
    </>
  )
}

/* ---------------------------------------------------------------------------
   NOTIFICATIONS — placeholder. NO se crea un sistema de notificaciones.
   ------------------------------------------------------------------------- */

function PdaNotifications() {
  return (
    <>
      <div className="pda-module-head">
        <h2>NOTIFICATIONS</h2>
        <p>Contenedor preparado para un sistema de avisos propio.</p>
      </div>
      <PdaPlaceholder title="SIN SISTEMA DE NOTIFICACIONES TODAVIA">
        Esta mision no crea avisos, ni bandejas, ni preferencias de lectura. El modulo existe solo para
        fijar el sitio donde vivira esa funcion si algun dia se autoriza.
      </PdaPlaceholder>
    </>
  )
}

/* ---------------------------------------------------------------------------
   IA ASSISTANT — placeholder DESCONECTADO.
   Requisito futuro documentado: el modelo NO puede hablar con Supabase ni con
   credenciales. Solo un contrato server-side owner-scoped le entregaria contexto:

       auth.uid() -> players.user_id -> players.id -> resumen autorizado -> IA

   Prohibido para esa implementacion futura: acceso arbitrario a otros jugadores,
   credenciales, secretos, tablas privadas, service_role o datos globales.
   ------------------------------------------------------------------------- */

function PdaAiAssistant() {
  return (
    <>
      <div className="pda-module-head">
        <h2>IA ASSISTANT</h2>
        <p>Your read-only strategic advisor. Analyzes information available to your empire and provides
          recommendations.</p>
      </div>
      <PdaPlaceholder
        title="OFFLINE / NOT CONFIGURED"
        points={[
          'Ningun modelo esta conectado: no hay llamadas, no hay claves, no se envia ningun dato.',
          'El contexto futuro llegara por un contrato server-side owner-scoped (auth.uid() -> players.user_id -> players.id).',
          'La IA no tendra acceso directo a la base de datos, a credenciales, a service_role ni a datos de otros jugadores.',
        ]}
      >
        Analiza informacion ya disponible para tu imperio y ofrece recomendaciones. Esta seccion es
        unicamente visual: no se ha implementado el asesor.
      </PdaPlaceholder>
      <div className="pda-cta-row">
        <button type="button" className="neo-button" disabled>
          ASK ASSISTANT
        </button>
        <span className="pda-status-offline">STATUS: OFFLINE / NOT CONFIGURED</span>
      </div>
    </>
  )
}

/* ---------------------------------------------------------------------------
   MINI-GAMES — placeholder vacio. NO se implementa Galaga aqui.
   ------------------------------------------------------------------------- */

function PdaMiniGames() {
  return (
    <>
      <div className="pda-module-head">
        <h2>MINI-GAMES</h2>
        <p>Zona de entretenimiento del dispositivo.</p>
      </div>
      <PdaPlaceholder
        title="GALAGA — ESTRUCTURA BASE, SIN JUEGO"
        points={[
          'El lienzo esta montado y vacio: todavia no hay jugador, enemigos, disparos ni colisiones.',
          'El gameplay lo implementara el usuario como ejercicio de aprendizaje de HTML5 Canvas.',
          'game loop, input, entidades, colisiones, render y oleadas: todos pendientes, a proposito.',
        ]}
      >
        Galaga queda preparado estructuralmente, pero el juego todavia NO existe. No hay codigo de
        juego escrito: solo el canvas, su ref y sus dimensiones.
      </PdaPlaceholder>
      <GalagaCanvas label="Galaga" />
    </>
  )
}

/* ---------------------------------------------------------------------------
   SHELL — marco del dispositivo + navegacion entre modulos.
   ------------------------------------------------------------------------- */

export type PdaShellProps = PdaOverviewProps & {
  /** Modulo inicial: la navegacion "MENSAJES" abre la PDA directamente en MESSAGES. */
  initialModule?: PdaModuleId
  /** Contenido ya existente que el modulo MESSAGES monta (la bandeja y los informes actuales). */
  messagesSlot?: ReactNode
}

export function PdaShell({ initialModule = 'OVERVIEW', messagesSlot, ...overview }: PdaShellProps) {
  const [active, setActive] = useState<PdaModuleId>(initialModule)

  return (
    <div className="pda-shell">
      <div className="neo-section-head">
        <div>
          <span className="neo-eyebrow">DISPOSITIVO DE ABORDO</span>
          <h1>PDA</h1>
          <p>Contenedor modular para las funciones que se moveran aqui poco a poco.</p>
        </div>
      </div>

      <section className="pda-device">
        <header className="pda-head">
          <span className="pda-glyph">&#9673;</span>
          <div className="pda-titles">
            <strong>PDA</strong>
            <span>PERSONAL DATA ASSISTANT</span>
          </div>
          <div className="pda-hud">
            <span className="pda-hud-dot" />
            <span className="pda-hud-label">ONLINE</span>
          </div>
        </header>

        <nav className="pda-tabs" aria-label="Modulos de la PDA">
          {MODULES.map(module => (
            <button
              key={module.id}
              type="button"
              className={`pda-tab${active === module.id ? ' active' : ''}`}
              data-pending={module.pending ? 'true' : 'false'}
              aria-pressed={active === module.id}
              onClick={() => setActive(module.id)}
            >
              {module.glyph} {module.label}
            </button>
          ))}
        </nav>

        <div className="pda-body">
          {active === 'OVERVIEW' && <PdaOverview {...overview} />}
          {active === 'MESSAGES' && <PdaMessages inbox={messagesSlot} />}
          {active === 'NOTIFICATIONS' && <PdaNotifications />}
          {active === 'IA' && <PdaAiAssistant />}
          {active === 'GAMES' && <PdaMiniGames />}
        </div>
      </section>
    </div>
  )
}



