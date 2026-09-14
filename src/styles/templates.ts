export type DashboardTemplate = {
  id: string
  name: string
  category: 'HUD' | 'TÁCTICA' | 'ESTRATÉGICA' | 'CLÁSICA' | 'EXPERIMENTAL'
  description: string
  layout: string
}

export const TEMPLATE_STORAGE_KEY = 'lagranimplosion-template'

export const dashboardTemplates: DashboardTemplate[] = [
  { id: 'deuteria', name: 'Deuteria', category: 'HUD', description: 'HUD compacto con rail lateral y órbita planetaria.', layout: 'template-deuteria' },
  { id: 'command', name: 'Command Center', category: 'HUD', description: 'Centro de mando con cabecera dominante y paneles densos.', layout: 'template-command' },
  { id: 'orbital', name: 'Orbital', category: 'HUD', description: 'Planeta central y paneles orbitando alrededor.', layout: 'template-orbital' },
  { id: 'neon', name: 'Neon Grid', category: 'HUD', description: 'Retícula tecnológica con paneles flotantes.', layout: 'template-neon' },
  { id: 'military', name: 'Military Ops', category: 'TÁCTICA', description: 'Interfaz táctica, compacta y orientada a operaciones.', layout: 'template-military' },
  { id: 'fleet', name: 'Fleet Command', category: 'TÁCTICA', description: 'Prioriza navegación, flota y estado de misión.', layout: 'template-fleet' },
  { id: 'warroom', name: 'War Room', category: 'TÁCTICA', description: 'Diseño de sala de guerra con panel lateral amplio.', layout: 'template-warroom' },
  { id: 'science', name: 'Science Lab', category: 'ESTRATÉGICA', description: 'Jerarquía limpia para investigación y evolución.', layout: 'template-science' },
  { id: 'economy', name: 'Economy', category: 'ESTRATÉGICA', description: 'Recursos y producción como protagonistas.', layout: 'template-economy' },
  { id: 'galaxy', name: 'Galaxy Map', category: 'ESTRATÉGICA', description: 'Mucho espacio central para mapas y coordenadas.', layout: 'template-galaxy' },
  { id: 'classic', name: 'Classic Empire', category: 'CLÁSICA', description: 'Estructura clásica de juego de estrategia.', layout: 'template-classic' },
  { id: 'portal', name: 'Portal', category: 'CLÁSICA', description: 'Barra superior y módulos apilados como un portal.', layout: 'template-portal' },
  { id: 'cards', name: 'Card Deck', category: 'CLÁSICA', description: 'Paneles convertidos en tarjetas modulares.', layout: 'template-cards' },
  { id: 'minimal', name: 'Minimal', category: 'CLÁSICA', description: 'Máxima superficie útil y mínima decoración.', layout: 'template-minimal' },
  { id: 'terminal', name: 'Terminal', category: 'EXPERIMENTAL', description: 'Terminal de control monoespaciada.', layout: 'template-terminal' },
  { id: 'vertical', name: 'Vertical Tower', category: 'EXPERIMENTAL', description: 'Módulos verticales para pantallas estrechas.', layout: 'template-vertical' },
  { id: 'split', name: 'Split Screen', category: 'EXPERIMENTAL', description: 'Dos zonas principales para información simultánea.', layout: 'template-split' },
  { id: 'commanddeck', name: 'Command Deck', category: 'EXPERIMENTAL', description: 'Puente de mando con navegación inferior.', layout: 'template-commanddeck' },
]

export const defaultTemplate = dashboardTemplates[0]

export function getTemplate(id: string | null | undefined): DashboardTemplate {
  return dashboardTemplates.find((template) => template.id === id) ?? defaultTemplate
}
