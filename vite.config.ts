import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

import { cloudflare } from "@cloudflare/vite-plugin";

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), cloudflare()],

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