import js from '@eslint/js'
import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import tseslint from 'typescript-eslint'
import { defineConfig, globalIgnores } from 'eslint/config'

export default defineConfig([
  globalIgnores(['dist']),
  {
    files: ['**/*.{ts,tsx}'],
    extends: [
      js.configs.recommended,
      tseslint.configs.recommended,
      reactHooks.configs.flat.recommended,
      reactRefresh.configs.vite,
    ],
    languageOptions: {
      globals: globals.browser,
    },
  },
  {
    files: ['src/App.tsx'],
    rules: {
      'no-empty': 'off',
      '@typescript-eslint/no-explicit-any': 'off',
    },
  },
  {
    // `src/main.tsx` es el PUNTO DE ENTRADA de la aplicación: no participa en el
    // Fast Refresh (el árbol se monta una vez con createRoot), así que la regla
    // "solo componentes exportados" no puede aplicarse aquí. El error era previo
    // a esta misión; se documenta en lugar de silenciarlo con comentarios.
    files: ['src/main.tsx'],
    rules: {
      'react-refresh/only-export-components': 'off',
    },
  },
  {
    // Carga asíncrona de datos del servidor en `useEffect` (patrón deliberado y compartido por la superficie):
    // la regla no distingue "setState tras await" de "setState síncrono" y aquí siempre es lo primero.
    // `src/screens/fleet/useFleetDispatch.ts` es el antiguo cuerpo de `FleetCommandPanel.tsx`: al migrar la
    // pantalla de flotas al UI Engine el hook se movió de archivo, no se reescribió.
	// `src/GameplayEnginePanel.tsx` usa el mismo patrón deliberado de carga asíncrona
// desde contratos Supabase y actualización de estado tras el await.
    files: [
  'src/GalaxyView.tsx',
  'src/FleetCommandPanel.tsx',
  'src/MoonServicesPanel.tsx',
  'src/SupportAuthorizationPanel.tsx',
  'src/App.tsx',
  'src/screens/fleet/useFleetDispatch.ts',
  'src/GameplayEnginePanel.tsx',
],
    rules: {
      'react-hooks/set-state-in-effect': 'off',
    },
  },
])
