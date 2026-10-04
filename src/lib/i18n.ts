/**
 * Idiomas de la UI. Tres idiomas; por defecto según el país IP del visitante y
 * siempre sobrescribible por el jugador.
 *
 * REGLA DE DEFAULT (2026-10-04, fijada por el producto):
 *   país de habla hispana  -> español
 *   país de habla anglófona   -> inglés
 *   Rusia                    -> ruso
 *   cualquier otro país      -> inglés (fallback)
 *
 * El país viene de `/api/visitor` del worker (Cloudflare `request.cf.country`).
 * Si ese endpoint no responde, el fallback es inglés.
 */

export type Lang = 'es' | 'en' | 'ru'

export const LANGS: readonly Lang[] = ['es', 'en', 'ru'] as const

export const LANG_LABEL: Record<Lang, string> = {
  es: 'Español',
  en: 'English',
  ru: 'Русский',
}

export const LANG_FLAG: Record<Lang, string> = {
  es: '\u{1F1EA}\u{1F1F8}',
  en: '\u{1F1EC}\u{1F1E7}',
  ru: '\u{1F1F7}\u{1F1FA}',
}

/** ISO-3166 alpha-2 -> idioma. Sin entrada => undefined (se aplica el fallback). */
const COUNTRY_TO_LANG: Record<string, Lang> = {
  // Hispanohablantes
  ES: 'es', MX: 'es', AR: 'es', CO: 'es', CL: 'es', PE: 'es', VE: 'es', EC: 'es',
  GT: 'es', CU: 'es', BO: 'es', DO: 'es', HN: 'es', PY: 'es', SV: 'es', NI: 'es',
  CR: 'es', PA: 'es', UY: 'es', PR: 'es', GL: 'es', GQ: 'es', EQ: 'es',
  // Anglófonos
  US: 'en', GB: 'en', CA: 'en', AU: 'en', NZ: 'en', IE: 'en', ZA: 'en', IN: 'en',
  NG: 'en', KE: 'en', GH: 'en', PH: 'en', SG: 'en', HK: 'en', JM: 'en', TT: 'en',
  BS: 'en', BB: 'en', BZ: 'en', MT: 'en',
  // Ruso
  RU: 'ru', BY: 'ru', KZ: 'ru', KG: 'ru', TJ: 'ru', TM: 'ru', UZ: 'ru',
}

export const DEFAULT_LANG: Lang = 'en'

/** Mapea un código de país a idioma, con fallback a inglés. */
export function langFromCountry(country: string | null | undefined): Lang {
  if (!country) return DEFAULT_LANG
  return COUNTRY_TO_LANG[country.toUpperCase()] ?? DEFAULT_LANG
}

const STORAGE_KEY = 'lgi.lang'

export function readStoredLang(): Lang | null {
  try {
    const v = window.localStorage.getItem(STORAGE_KEY)
    return v && (LANGS as readonly string[]).includes(v) ? (v as Lang) : null
  } catch {
    return null
  }
}

export function writeStoredLang(lang: Lang): void {
  try {
    window.localStorage.setItem(STORAGE_KEY, lang)
  } catch {
    /* storage bloqueado: el idioma dura lo que la sesión */
  }
}

/** Idioma inicial: preferencia guardada > país IP > inglés. */
export function resolveInitialLang(country: string | null): Lang {
  return readStoredLang() ?? langFromCountry(country)
}

/**
 * País del visitante vía el endpoint del worker, que devuelve
 * `{ country, ipHash, isDeveloper }` desde `request.cf.country`.
 * null si el worker no está desplegado o falla: el caller aplica inglés.
 */
export async function fetchVisitorCountry(signal?: AbortSignal): Promise<string | null> {
  try {
    const res = await fetch('/api/visitor', { signal })
    if (!res.ok) return null
    const json = (await res.json()) as { country?: string }
    return json.country ?? null
  } catch {
    return null
  }
}

type Dict = Record<string, string>

/** Cadenas de la UI. Añadir aquí la clave y sus tres traducciones. */
const STRINGS = {
  'nav.overview': { es: 'Resumen', en: 'Overview', ru: 'Обзор' },
  'nav.buildings': { es: 'Edificios', en: 'Buildings', ru: 'Постройки' },
  'nav.research': { es: 'Investigación', en: 'Research', ru: 'Исследования' },
  'nav.shipyard': { es: 'Hangar', en: 'Shipyard', ru: 'Верфь' },
  'nav.defense': { es: 'Defensas', en: 'Defenses', ru: 'Оборона' },
  'nav.fleet': { es: 'Flotas', en: 'Fleets', ru: 'Флоты' },
  'nav.galaxy': { es: 'Galaxia', en: 'Galaxy', ru: 'Галактика' },
  'nav.moon': { es: 'Lunas', en: 'Moons', ru: 'Луны' },
  'nav.messages': { es: 'Mensajes', en: 'Messages', ru: 'Сообщения' },
  'login.title': { es: 'LA GRAN IMPLOSIÓN', en: 'LA GRAN IMPLOSIÓN', ru: 'ЛА ГРАН ИМПЛОСИОН' },
  'login.email': { es: 'Correo', en: 'Email', ru: 'Эл. почта' },
  'login.password': { es: 'Contraseña', en: 'Password', ru: 'Пароль' },
  'login.enter': { es: 'Entrar', en: 'Sign in', ru: 'Войти' },
  'login.create': { es: 'Crear cuenta', en: 'Sign up', ru: 'Регистрация' },
  'login.forgot': { es: '¿Olvidaste tu contraseña?', en: 'Forgot your password?', ru: 'Забыли пароль?' },
  'login.noaccount': { es: '¿No tienes cuenta?', en: "Don't have an account?", ru: 'Нет аккаунта?' },
  'onboard.first': { es: 'PRIMER ACCESO', en: 'FIRST LOGIN', ru: 'ПЕРВЫЙ ВХОД' },
  'onboard.title': { es: 'Funda tu imperio', en: 'Found your empire', ru: 'Основайте империю' },
  'onboard.subtitle': {
    es: 'Tu cuenta aún no tiene un imperio. Elige tu nombre de comandante: se creará tu Homeworld con recursos iniciales.',
    en: 'Your account has no empire yet. Choose your commander name: your Homeworld will be created with starting resources.',
    ru: 'У вашего аккаунта ещё нет империи. Выберите имя командира — будет создан ваш Homeworld со стартовыми ресурсами.',
  },
  'onboard.commander': { es: 'NOMBRE DE COMANDANTE', en: 'COMMANDER NAME', ru: 'ИМЯ КОМАНДИРА' },
  'onboard.commanderPh': { es: '3-24 caracteres', en: '3-24 characters', ru: '3-24 символа' },
  'onboard.planet': { es: 'NOMBRE DEL PLANETA', en: 'PLANET NAME', ru: 'НАЗВАНИЕ ПЛАНЕТЫ' },
  'onboard.planetOptional': { es: '(opcional)', en: '(optional)', ru: '(необязательно)' },
  'onboard.planetPh': { es: '(si lo dejas vacío: Homeworld)', en: '(leave empty for Homeworld)', ru: '(пусто — будет Homeworld)' },
  'onboard.country': { es: 'PAÍS', en: 'COUNTRY', ru: 'СТРАНА' },
  'onboard.shield': { es: 'ESCUDO', en: 'EMBLEM', ru: 'ЭМБЛЕМА' },
  'onboard.create': { es: 'CREAR IMPERIO', en: 'CREATE EMPIRE', ru: 'СОЗДАТЬ ИМПЕРИЮ' },
  'onboard.creating': { es: 'CREANDO IMPERIO…', en: 'CREATING EMPIRE…', ru: 'СОЗДАНИЕ ИМПЕРИИ…' },
  'onboard.logout': { es: 'CERRAR SESIÓN', en: 'SIGN OUT', ru: 'ВЫЙТИ' },
  'onboard.nameTooShort': { es: 'Mínimo 3 caracteres.', en: 'Minimum 3 characters.', ru: 'Минимум 3 символа.' },
  'onboard.planetInvalid': {
    es: 'Máximo 32 caracteres: letras, números, espacios, punto, guion o guion bajo.',
    en: 'Maximum 32 characters: letters, numbers, spaces, dot, dash or underscore.',
    ru: 'Максимум 32 символа: буквы, цифры, пробелы, точка, дефис или подчёркивание.',
  },
  'lang.choose': { es: 'Idioma', en: 'Language', ru: 'Язык' },
  'lang.title': { es: 'Elige tu idioma', en: 'Choose your language', ru: 'Выберите язык' },
  'close': { es: 'Cerrar', en: 'Close', ru: 'Закрыть' },
  'signout': { es: 'CERRAR SESIÓN', en: 'SIGN OUT', ru: 'ВЫЙТИ' },
} satisfies Record<string, Dict>

export type StringKey = keyof typeof STRINGS

/** Traduce una clave. Si falta en ese idioma, cae al inglés y luego a la clave. */
export function translate(lang: Lang, key: StringKey): string {
  const entry = STRINGS[key]
  return entry[lang] ?? entry.en ?? key
}
