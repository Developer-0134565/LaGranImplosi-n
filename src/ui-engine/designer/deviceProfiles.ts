/*
  UI ENGINE — DEVICE PROFILES (device preview del UI Designer)

  Perfiles de viewport ORIENTATIVOS usados por el marco de previsualización.
  No se detecta hardware ni user-agent: el ancho del perfil se aplica como
  contenedor real, así que lo que se ve en el preview es exactamente lo que
  producirán las container queries del engine en un contenedor de ese ancho.

  `native` no aplica marco: el engine ocupa el ancho que le da la aplicación.
*/

export type UIDeviceFamily = 'native' | 'desktop' | 'tablet' | 'mobile'

export type UIDeviceProfile = {
  id: string
  label: string
  family: UIDeviceFamily
  /** Ancho lógico del viewport (CSS px). 0 = sin marco. */
  width: number
  /** Alto orientativo del marco en el preview. 0 = sin alto fijo. */
  height: number
  /** Densidad de píxeles orientativa (informativa para el Designer). */
  dpr: number
  note?: string
}

export const UI_DEVICE_PROFILES: readonly UIDeviceProfile[] = [
  {
    id: 'native',
    label: 'Nativo (ventana real)',
    family: 'native',
    width: 0,
    height: 0,
    dpr: 0,
    note: 'Sin marco: el engine usa el ancho real de la aplicación.',
  },
  {
    id: 'desktop-1280',
    label: 'Desktop 1280',
    family: 'desktop',
    width: 1280,
    height: 0,
    dpr: 1,
  },
  {
    id: 'desktop-1440',
    label: 'Desktop 1440',
    family: 'desktop',
    width: 1440,
    height: 0,
    dpr: 1,
  },
  {
    id: 'desktop-1920',
    label: 'Desktop wide 1920',
    family: 'desktop',
    width: 1920,
    height: 0,
    dpr: 1,
    note: 'Por encima de 1920 el layout no crece: sólo gana aire.',
  },
  {
    id: 'tablet-768',
    label: 'Tablet 768',
    family: 'tablet',
    width: 768,
    height: 1024,
    dpr: 2,
  },
  {
    id: 'tablet-1024',
    label: 'Tablet 1024',
    family: 'tablet',
    width: 1024,
    height: 768,
    dpr: 2,
  },
  {
    id: 'android-360',
    label: 'Android phone 360',
    family: 'mobile',
    width: 360,
    height: 740,
    dpr: 3,
    note: 'Ancho Android más común en gama de entrada.',
  },
  {
    id: 'android-390',
    label: 'Android phone 390',
    family: 'mobile',
    width: 390,
    height: 844,
    dpr: 3,
  },
  {
    id: 'android-430',
    label: 'Android large 430',
    family: 'mobile',
    width: 430,
    height: 932,
    dpr: 3,
  },
  {
    id: 'android-tablet-800',
    label: 'Android tablet 800',
    family: 'tablet',
    width: 800,
    height: 1280,
    dpr: 2,
  },
]

export const DEFAULT_UI_DEVICE_PROFILE_ID = 'native'

export function isUIDeviceProfileId(value: unknown): value is string {
  return typeof value === 'string' && UI_DEVICE_PROFILES.some((profile) => profile.id === value)
}

export function getUIDeviceProfile(id: string | null | undefined): UIDeviceProfile {
  return (
    UI_DEVICE_PROFILES.find((profile) => profile.id === id) ??
    UI_DEVICE_PROFILES.find((profile) => profile.id === DEFAULT_UI_DEVICE_PROFILE_ID)!
  )
}
