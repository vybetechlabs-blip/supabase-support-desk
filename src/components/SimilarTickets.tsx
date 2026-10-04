import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'

type Match = { id: number; subject: string; category: string | null; resolution: string | null; similarity: number }

// Top resolved tickets similar to this one. public.similar_tickets runs with the
// caller's rights, so it only ever returns tickets the caller may read.
export function SimilarTickets({ ticketId, hasEmbedding }: { ticketId: number; hasEmbedding: boolean }) {
  const [matches, setMatches] = useState<Match[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc('similar_tickets', { p_ticket_id: ticketId, p_match_count: 3 })
    if (error) setError(error.message)
    else setMatches(data)
  }, [ticketId])

  useEffect(() => {
    if (hasEmbedding) load()
  }, [hasEmbedding, load])

  return (
    <div className="card similar">
      <h2>Similar resolved tickets</h2>
      {!hasEmbedding && <p className="muted">Not available until this ticket is triaged.</p>}
      {error && <p className="error">{error}</p>}
      {hasEmbedding && matches?.length === 0 && <p className="muted">No similar resolved tickets.</p>}
      {matches && matches.length > 0 && (
        <ol>
          {matches.map((m) => (
            <li key={m.id}>
              <a href={`#/tickets/${m.id}`}>#{m.id} {m.subject}</a>{' '}
              <span className="muted">({Math.round(m.similarity * 100)}% match{m.category ? `, ${m.category}` : ''})</span>
              {m.resolution && <p className="body">{m.resolution}</p>}
            </li>
          ))}
        </ol>
      )}
    </div>
  )
}
