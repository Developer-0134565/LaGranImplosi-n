import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

import { cloudflare } from "@cloudflare/vite-plugin";

const localDeveloperFrontend = () => ({
  name: 'lgi-local-developer-frontend',
  transform(code: string, id: string) {
    if (!id.endsWith('/src/AppStable.tsx')) return
    const marker = 'const LOCAL_DEV_FRONTEND=import.meta.env.DEV'
    if (!code.includes(marker)) return
    return code.replace(
      marker,
      "const LOCAL_DEV_FRONTEND=import.meta.env.DEV || window.location.hostname==='localhost' || window.location.hostname==='127.0.0.1'",
    )
  },
})

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), localDeveloperFrontend(), cloudflare()],

  resolve: {
    // Fuerza a Vite a usar una sola instancia de React en todo el bundle.
    // Sin esto, @supabase/auth-ui-react puede cargar su propia copia de React
    // y lanzar "Cannot read properties of null (reading 'useState')".
    dedupe: ['react', 'react-dom'],
  },

  optimizeDeps: {
    // Evita que Vite pre-optimice las dependencias de Supabase por separado,
    // que es lo que crea la copia duplicada de React.
    exclude: ['@supabase/auth-ui-react', '@supabase/auth-ui-shared'],
  },
})