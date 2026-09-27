import type { UITemplate, UITemplateId } from '../types'
import { classicTemplate } from './classic'
import { commandTemplate } from './command'
import { industrialTemplate } from './industrial'
import { minimalTemplate } from './minimal'
import { orbitalTemplate } from './orbital'
import { tacticalTemplate } from './tactical'

/** Registro de templates del engine. El orden define el del UI Designer. */
export const UI_TEMPLATES: readonly UITemplate[] = [
  classicTemplate,
  commandTemplate,
  tacticalTemplate,
  orbitalTemplate,
  industrialTemplate,
  minimalTemplate,
]

export const DEFAULT_UI_TEMPLATE_ID: UITemplateId = 'classic'

const TEMPLATE_BY_ID = new Map<UITemplateId, UITemplate>(
  UI_TEMPLATES.map((template) => [template.id, template]),
)

export function isUITemplateId(value: unknown): value is UITemplateId {
  return typeof value === 'string' && TEMPLATE_BY_ID.has(value as UITemplateId)
}

/** Resolución tolerante: cualquier id desconocido cae al template por defecto. */
export function getUITemplate(id: UITemplateId | null | undefined): UITemplate {
  return (id ? TEMPLATE_BY_ID.get(id) : undefined) ?? TEMPLATE_BY_ID.get(DEFAULT_UI_TEMPLATE_ID)!
}

export { classicTemplate, commandTemplate, tacticalTemplate, orbitalTemplate, industrialTemplate, minimalTemplate }
export type { UITemplate, UITemplateId }
