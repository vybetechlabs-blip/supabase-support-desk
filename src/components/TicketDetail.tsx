import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { supabase, STATUSES, CATEGORIES, PRIORITIES, type Profile, type Ticket, type TicketUpdate } from '../lib/supabase'
import { useRealtime } from '../lib/realtime'
import { triageTicket } from '../lib/triage'
import { SimilarTickets } from './SimilarTickets'

type TicketView = Omit<Ticket, 'embedding'> & {
  customer: { display_name: string } | null
  assignee: { display_name: string } | null
}
type MessageView = {
  id: number
  body: string
  is_internal: boolean
  created_at: string
  author_id: string
  author: { display_name: string; role: string } | null
}

export function TicketDetail({ ticketId, profile }: { ticketId: number; profile: Profile }) {
  const isAgent = profile.role === 'agent'
  const [ticket, setTicket] = useState<TicketView | null>(null)
  const [messages, setMessages] = useState<MessageView[]>([])
  const [error, setError] = useState<string | null>(null)
  const [notFound, setNotFound] = useState(false)

  const loadTicket = useCallback(async () => {
    const { data, error } = await supabase
      .from('tickets')
      .select(
        // Every column except the 384-number embedding, which the browser never needs.
        'id, customer_id, subject, body, status, category, priority, assignee_id, resolution, triaged_at, created_at, updated_at,' +
          ' customer:profiles!tickets_customer_id_fkey(display_name), assignee:profiles!tickets_assignee_id_fkey(display_name)',
      )
      .eq('id', ticketId)
      .maybeSingle()
    if (error) setError(error.message)
    else if (!data) setNotFound(true) // RLS hides tickets the caller may not see.
    else setTicket(data as unknown as TicketView)
  }, [ticketId])

  const loadMessages = useCallback(async () => {
    const { data, error } = await supabase
      .from('messages')
      .select('id, body, is_internal, created_at, author_id, author:profiles(display_name, role)')
      .eq('ticket_id', ticketId)
      .order('created_at', { ascending: true })
    if (error) setError(error.message)
    else setMessages(data as unknown as MessageView[])
  }, [ticketId])

  useEffect(() => {
    loadTicket()
    loadMessages()
  }, [loadTicket, loadMessages])

  useRealtime(`ticket-${ticketId}`, [{ table: 'tickets', event: 'UPDATE', filter: `id=eq.${ticketId}` }], loadTicket)
  useRealtime(`messages-${ticketId}`, [{ table: 'messages', event: 'INSERT', filter: `ticket_id=eq.${ticketId}` }], loadMessages)

  if (notFound) return <p className="muted">Ticket not found.</p>
  if (!ticket) return error ? <p className="error">{error}</p> : <p>Loading…</p>

  return (
    <section className={isAgent ? 'detail with-side' : 'detail'}>
      <div>
        <p><a href="#/">← Back to tickets</a></p>
        <h1>#{ticket.id} {ticket.subject}</h1>
        <p className="meta">
          <span className={`badge status-${ticket.status}`}>{ticket.status}</span>
          {isAgent && <> · from {ticket.customer?.display_name}</>}
          {' · '}opened {new Date(ticket.created_at).toLocaleString()}
          {ticket.assignee && <> · assigned to {ticket.assignee.display_name}</>}
        </p>
        <article className="message original">
          <p className="body">{ticket.body}</p>
        </article>
        {ticket.status === 'resolved' && ticket.resolution && (
          <article className="message resolution">
            <strong>Resolution</strong>
            <p className="body">{ticket.resolution}</p>
          </article>
        )}
        <h2>Conversation</h2>
        {messages.length === 0 && <p className="muted">No replies yet.</p>}
        {messages.map((m) => (
          <article key={m.id} className={`message ${m.is_internal ? 'internal' : ''} ${m.author_id === profile.id ? 'own' : ''}`}>
            <header>
              <strong>{m.author?.display_name ?? 'Unknown'}</strong>
              {m.is_internal && <span className="badge internal-badge">internal note</span>}
              <time>{new Date(m.created_at).toLocaleString()}</time>
            </header>
            <p className="body">{m.body}</p>
          </article>
        ))}
        {error && <p className="error" role="alert">{error}</p>}
        <ReplyForm ticketId={ticket.id} isAgent={isAgent} onSent={loadMessages} />
      </div>
      {isAgent && (
        <aside>
          {/* Remount on change so live updates from other agents or the triage function reset the form. */}
          <AgentControls
            key={[ticket.status, ticket.category, ticket.priority, ticket.resolution, ticket.assignee_id].join('|')}
            ticket={ticket}
            profile={profile}
            onSaved={loadTicket}
          />
          <TriageBox ticket={ticket} onDone={loadTicket} />
          <SimilarTickets key={ticket.triaged_at ?? 'untriaged'} ticketId={ticket.id} hasEmbedding={!!ticket.triaged_at} />
        </aside>
      )}
    </section>
  )
}

function ReplyForm({ ticketId, isAgent, onSent }: { ticketId: number; isAgent: boolean; onSent: () => void }) {
  const [body, setBody] = useState('')
  const [internal, setInternal] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function submit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    // author_id defaults to auth.uid(); the insert policy checks it and the ticket.
    const { error } = await supabase.from('messages').insert({ ticket_id: ticketId, body, is_internal: isAgent && internal })
    setBusy(false)
    if (error) {
      setError(error.message)
      return
    }
    setBody('')
    setInternal(false)
    onSent()
  }

  return (
    <form onSubmit={submit} className={`card reply ${internal ? 'internal' : ''}`}>
      <label>
        {internal ? 'Internal note (agents only)' : 'Reply'}
        <textarea value={body} onChange={(e) => setBody(e.target.value)} required maxLength={10000} rows={4} />
      </label>
      {isAgent && (
        <label className="inline">
          <input type="checkbox" checked={internal} onChange={(e) => setInternal(e.target.checked)} /> Internal note
        </label>
      )}
      {error && <p className="error" role="alert">{error}</p>}
      <button type="submit" disabled={busy}>{internal ? 'Add note' : 'Send reply'}</button>
    </form>
  )
}

function AgentControls({ ticket, profile, onSaved }: { ticket: TicketView; profile: Profile; onSaved: () => void }) {
  const [status, setStatus] = useState(ticket.status)
  const [category, setCategory] = useState(ticket.category ?? '')
  const [priority, setPriority] = useState(ticket.priority ?? '')
  const [resolution, setResolution] = useState(ticket.resolution ?? '')
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)

  async function update(values: TicketUpdate) {
    setError(null)
    setSaved(false)
    const { error } = await supabase.from('tickets').update(values).eq('id', ticket.id)
    if (error) setError(error.message)
    else {
      setSaved(true)
      onSaved()
    }
  }

  return (
    <div className="card controls">
      <h2>Ticket</h2>
      <p>
        Assignee: {ticket.assignee?.display_name ?? <span className="muted">unassigned</span>}{' '}
        {ticket.assignee_id !== profile.id && (
          <button className="small" onClick={() => update({ assignee_id: profile.id })}>Assign to me</button>
        )}
      </p>
      <label>
        Status
        <select value={status} onChange={(e) => setStatus(e.target.value)}>
          {STATUSES.map((s) => <option key={s}>{s}</option>)}
        </select>
      </label>
      <label>
        Category
        <select value={category} onChange={(e) => setCategory(e.target.value)}>
          <option value="">untriaged</option>
          {CATEGORIES.map((c) => <option key={c}>{c}</option>)}
        </select>
      </label>
      <label>
        Priority
        <select value={priority} onChange={(e) => setPriority(e.target.value)}>
          <option value="">untriaged</option>
          {PRIORITIES.map((p) => <option key={p}>{p}</option>)}
        </select>
      </label>
      {status === 'resolved' && (
        <label>
          Resolution summary
          <textarea value={resolution} onChange={(e) => setResolution(e.target.value)} rows={3} maxLength={2000} />
        </label>
      )}
      {error && <p className="error" role="alert">{error}</p>}
      {saved && <p className="muted">Saved.</p>}
      <button
        onClick={() =>
          update({
            status,
            category: category || null,
            priority: priority || null,
            resolution: status === 'resolved' ? resolution || null : ticket.resolution,
          })
        }
      >
        Save changes
      </button>
    </div>
  )
}

function TriageBox({ ticket, onDone }: { ticket: TicketView; onDone: () => void }) {
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState<string | null>(null)

  async function run() {
    setBusy(true)
    const r = await triageTicket(ticket.id, true)
    setBusy(false)
    if ('error' in r) setResult(`Triage failed: ${r.error}`)
    else if (r.classifier === 'stub') setResult('Embedding stored. Classification is a stub (no ANTHROPIC_API_KEY): set category and priority by hand.')
    else if (r.classifier === 'error') setResult(`Embedding stored. Classification failed (${r.note ?? 'unknown error'}).`)
    else setResult(`Classified by ${r.classifier}: ${r.category ?? '?'} / ${r.priority ?? '?'}`)
    onDone()
  }

  return (
    <div className="card">
      <h2>Triage</h2>
      <p className="muted">
        {ticket.triaged_at ? `Triaged ${new Date(ticket.triaged_at).toLocaleString()}` : 'Not triaged yet.'}
      </p>
      {result && <p>{result}</p>}
      <button className="secondary" onClick={run} disabled={busy}>
        {busy ? 'Running…' : ticket.triaged_at ? 'Re-run triage' : 'Run triage'}
      </button>
    </div>
  )
}
