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
})