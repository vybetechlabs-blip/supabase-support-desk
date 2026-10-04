// triage: store an embedding for a ticket and, when an Anthropic key is configured,
// classify its category and priority with Claude Haiku 4.5.
//
// Called by the browser right after a customer creates a ticket, and by agents
// ("Run triage"). Auth mode 'user': the caller must send a valid user JWT.
// The ticket is read through the caller's RLS (only its owner or an agent gets it);
// the write uses the admin client because customers may not set these columns.
import '@supabase/functions-js/edge-runtime.d.ts'
import { withSupabase } from '@supabase/server'
import Anthropic from '@anthropic-ai/sdk'

import { classifyIfNeeded, outcomeOf } from './classify.ts'

// Built-in embedding model (gte-small, 384 dimensions). Created once per worker.
const embedder = new Supabase.ai.Session('gte-small')

// Null when no key is configured: classifyTicket then returns the stub result.
function anthropicClient(): Anthropic | null {
  const apiKey = Deno.env.get('ANTHROPIC_API_KEY')
  return apiKey ? new Anthropic({ apiKey }) : null
}

export default {
  fetch: withSupabase({ auth: 'user' }, async (req, ctx) => {
    if (req.method !== 'POST') return Response.json({ error: 'POST only' }, { status: 405 })

    let payload: { ticket_id?: unknown; force?: unknown }
    try {
      payload = await req.json()
    } catch {
      return Response.json({ error: 'body must be JSON' }, { status: 400 })
    }
    const ticketId = Number(payload.ticket_id)
    if (!Number.isInteger(ticketId) || ticketId <= 0) {
      return Response.json({ error: 'ticket_id must be a positive integer' }, { status: 400 })
    }

    // RLS decides visibility: a customer gets only their own ticket, an agent any ticket.
    const { data: ticket, error } = await ctx.supabase
      .from('tickets')
      .select('id, subject, body, category, priority, triaged_at')
      .eq('id', ticketId)
      .maybeSingle()
    if (error) return Response.json({ error: error.message }, { status: 500 })
    if (!ticket) return Response.json({ error: 'ticket not found' }, { status: 404 })

    // Re-running triage costs a model call; only agents may force it.
    if (ticket.triaged_at && payload.force === true) {
      const { data: me } = await ctx.supabase.from('profiles').select('role').eq('id', String(ctx.jwtClaims?.sub)).single()
      if (me?.role !== 'agent') return Response.json({ error: 'only agents can re-run triage' }, { status: 403 })
    } else if (ticket.triaged_at) {
      return Response.json({ ticket_id: ticketId, skipped: 'already triaged' })
    }

    const text = `${ticket.subject}\n\n${ticket.body}`
    const embedding = (await embedder.run(text, { mean_pool: true, normalize: true })) as number[]
    // No model call when an agent already set both fields; the embedding is still stored.
    const result = await classifyIfNeeded(anthropicClient(), ticket)

    // Never overwrite a category or priority an agent already set.
    const outcome = outcomeOf(result)
    // triaged_at is set whatever the outcome: it is the once-per-ticket gate above.
    const update: Record<string, unknown> = {
      embedding: JSON.stringify(embedding),
      triaged_at: new Date().toISOString(),
      triage_outcome: outcome,
    }
    if (!ticket.category && result.category) update.category = result.category
    if (!ticket.priority && result.priority) update.priority = result.priority

    const { error: writeError } = await ctx.supabaseAdmin.from('tickets').update(update).eq('id', ticketId)
    if (writeError) return Response.json({ error: writeError.message }, { status: 500 })

    return Response.json({
      ticket_id: ticketId,
      embedding_dimensions: embedding.length,
      classifier: result.classifier,
      outcome,
      category: update.category ?? ticket.category,
      priority: update.priority ?? ticket.priority,
      ...(result.note ? { note: result.note } : {}),
    })
  }),
}
