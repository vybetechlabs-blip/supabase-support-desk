import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const publishableKey = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY

if (!url || !publishableKey) {
  throw new Error('Missing VITE_SUPABASE_URL or VITE_SUPABASE_PUBLISHABLE_KEY. Copy .env.example to .env.local.')
}
if (publishableKey.startsWith('sb_secret_')) {
  // Guard against the most damaging setup mistake: a secret key in browser code bypasses RLS.
  throw new Error('VITE_SUPABASE_PUBLISHABLE_KEY holds a secret key. Use the publishable key.')
}

// Browser client: publishable key only. Every query runs as anon or authenticated, so RLS applies.
export const supabase = createClient(url, publishableKey)
