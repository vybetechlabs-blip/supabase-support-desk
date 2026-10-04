import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  // 127.0.0.1, not localhost: matches auth.site_url in supabase/config.toml.
  server: { host: '127.0.0.1', port: 5173, strictPort: true },
})
