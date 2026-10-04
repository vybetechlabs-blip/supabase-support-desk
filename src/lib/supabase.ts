import { createClient } from '@supabase/supabase-js'
import type { Database } from './database.types'

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
export const supabase = createClient<Database>(url, publishableKey)

export type Tables<T extends keyof Database['public']['Tables']> = Database['public']['Tables'][T]['Row']
export type Profile = Tables<'profiles'>
export type Ticket = Tables<'tickets'>
export type Message = Tables<'messages'>
export type TicketUpdate = Database['public']['Tables']['tickets']['Update']

export const STATUSES = ['open', 'pending', 'resolved'] as const
export const CATEGORIES = ['account', 'billing', 'bug', 'performance', 'integration', 'how_to', 'other'] as const
export const PRIORITIES = ['low', 'normal', 'high', 'urgent'] as const
