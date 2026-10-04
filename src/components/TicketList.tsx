import { useCallback, useEffect, useState } from 'react'
import { supabase, STATUSES, CATEGORIES, PRIORITIES, type Profile } from '../lib/supabase'
import { useRealtime } from '../lib/realtime'

type Row = {
  id: number
  subject: string
  status: string
  category: string | null
  priority: string | null
  created_at: string
  updated_at: string
  customer: { display_name: string } | null
  assignee: { display_name: string } | null
}

const PAGE_SIZE = 50

export function TicketList({ profile }: { profile: Profile }) {
  const isAgent = profile.role === 'agent'
  const [status, setStatus] = useState<string>(isAgent ? 'open' : '')
  const [category, setCategory] = useState('')
  const [priority, setPriority] = useState('')
  const [mine, setMine] = useState(false)
  const [rows, setRows] = useState<Row[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loaded, setLoaded] = useState(false)

  const load = useCallback(async () => {
    // RLS decides which rows come back: customers get their own tickets, agents get all.
    let q = supabase
      .from('tickets')
      .select(
        'id, subject, status, category, priority, created_at, updated_at,' +
          ' customer:profiles!tickets_customer_id_fkey(display_name),' +
          ' assignee:profiles!tickets_assignee_id_fkey(display_name)',
      )
      .order('created_at', { ascending: false })
      .limit(PAGE_SIZE)
    if (status) q = q.eq('status', status)
    if (category) q = q.eq('category', category)
    if (priority) q = q.eq('priority', priority)
    if (mine) q = q.eq('assignee_id', profile.id)
    const { data, error } = await q
    setLoaded(true)
    if (error) setError(error.message)
    else {
      setError(null)
      setRows(data as unknown as Row[])
    }
  }, [status, category, priority, mine, profile.id])

  useEffect(() => {
    load()
  }, [load])

  useRealtime('ticket-list', [{ table: 'tickets', event: '*' }], load)

  return (
    <section>
      <h1>{isAgent ? 'Tickets' : 'My tickets'}</h1>
      <div className="filters">
        <label>
          Status
          <select value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="">All</option>
            {STATUSES.map((s) => <option key={s}>{s}</option>)}
          </select>
        </label>
        {isAgent && (
          <>
            <label>
              Category
              <select value={category} onChange={(e) => setCategory(e.target.value)}>
                <option value="">All</option>
                {CATEGORIES.map((c) => <option key={c}>{c}</option>)}
              </select>
            </label>
            <label>
              Priority
              <select value={priority} onChange={(e) => setPriority(e.target.value)}>
                <option value="">All</option>
                {PRIORITIES.map((p) => <option key={p}>{p}</option>)}
              </select>
            </label>
            <label className="inline">
              <input type="checkbox" checked={mine} onChange={(e) => setMine(e.target.checked)} /> Assigned to me
            </label>
          </>
        )}
      </div>
      {error && <p className="error" role="alert">{error}</p>}
      {loaded && rows.length === 0 && !error && <p className="muted">No tickets.</p>}
      {rows.length > 0 && (
        <table className="tickets">
          <thead>
            <tr>
              <th>#</th>
              <th>Subject</th>
              {isAgent && <th>Customer</th>}
              <th>Status</th>
              {isAgent && <th>Category</th>}
              {isAgent && <th>Priority</th>}
              {isAgent && <th>Assignee</th>}
              <th>Created</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((t) => (
              <tr key={t.id}>
                <td>{t.id}</td>
                <td><a href={`#/tickets/${t.id}`}>{t.subject}</a></td>
                {isAgent && <td>{t.customer?.display_name}</td>}
                <td><span className={`badge status-${t.status}`}>{t.status}</span></td>
                {isAgent && <td>{t.category ?? <span className="muted">untriaged</span>}</td>}
                {isAgent && <td>{t.priority && <span className={`badge priority-${t.priority}`}>{t.priority}</span>}</td>}
                {isAgent && <td>{t.assignee?.display_name ?? <span className="muted">—</span>}</td>}
                <td>{new Date(t.created_at).toLocaleString()}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}
