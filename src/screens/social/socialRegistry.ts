import { createUIRegistry, defineUIModule } from '../../ui-engine'

/*
  REGISTRY DE LA PANTALLA SOCIAL

  Cada módulo declara su id `dominio.nombre`. El template decide después en qué
  región vive y en qué orden; este archivo no contiene ninguna decisión de
  layout.

  El dominio es `messages` porque la capa social comparte el eje de
  "relaciones entre jugadores" con la mensajería; el template `classic` ya
  declara `messages.feed` en `aside`, y estos ids caen en `main` por defecto,
  que es donde corresponde un formulario de gestión.
*/

export const socialModuleIds = {
  command: 'messages.social-command',
  buddies: 'messages.buddies',
  incoming: 'messages.buddy-incoming',
  outgoing: 'messages.buddy-outgoing',
  buddyRequest: 'messages.buddy-request',
  alliance: 'messages.alliance',
  allianceCreate: 'messages.alliance-create',
  allianceApply: 'messages.alliance-apply',
  allianceMembers: 'messages.alliance-members',
  allianceRanks: 'messages.alliance-ranks',
  defend: 'messages.defend-status',
} as const

export const socialRegistry = createUIRegistry([
  defineUIModule('messages', 'social-command', 'Barra social', 'Estado de carga y contadores de relaciones.'),
  defineUIModule('messages', 'buddies', 'Amigos', 'Relaciones aceptadas (list_buddies).'),
  defineUIModule('messages', 'buddy-incoming', 'Solicitudes recibidas', 'Peticiones que esperan respuesta.'),
  defineUIModule('messages', 'buddy-outgoing', 'Solicitudes enviadas', 'Peticiones abiertas enviadas.'),
  defineUIModule('messages', 'buddy-request', 'Enviar solicitud', 'Envío de solicitud por id de jugador.'),
  defineUIModule('messages', 'alliance', 'Mi alianza', 'Estado de membresía y rango propio.'),
  defineUIModule('messages', 'alliance-create', 'Crear alianza', 'Fundación de una alianza propia.'),
  defineUIModule('messages', 'alliance-apply', 'Solicitar ingreso', 'Solicitud de ingreso a una alianza.'),
  defineUIModule('messages', 'alliance-members', 'Miembros', 'Roster visible según see_members.'),
  defineUIModule('messages', 'alliance-ranks', 'Rangos y permisos', 'Permisos resueltos por el servidor.'),
  defineUIModule('messages', 'defend-status', 'Estado DEFEND', 'Readiness real informado por el servidor.'),
])