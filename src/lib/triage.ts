import { supabase } from './supabase'

export type TriageResult = {
  ticket_id: number
  embedding_dimensions?: number
  classifier?: 'claude-haiku-4-5' | 'stub' | 'error' | 'skipped'
  outcome?: 'classified' | 'no_key' | 'failed' | 'skipped'
  category?: string | null
  priority?: string | null
  note?: string
  skipped?: string
}

// Calls the `triage` Edge Function with the signed-in user's session.
// Best effort: a failure leaves the ticket untriaged, and an agent can re-run it.
export async function triageTicket(ticketId: number, force = false): Promise<TriageResult | { error: string }> {
  const { data, error } = await supabase.functions.invoke<TriageResult>('triage', {
    body: { ticket_id: ticketId, force },
  })
  if (error) {
    console.warn(`triage for ticket ${ticketId} failed:`, error.message)
    return { error: error.message }
  }
  return data as TriageResult
}
