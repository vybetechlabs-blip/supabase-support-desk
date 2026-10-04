import { useState, type FormEvent } from 'react'
import { supabase } from '../lib/supabase'
import { navigate } from '../lib/session'
import { triageTicket } from '../lib/triage'

export function NewTicket() {
  const [subject, setSubject] = useState('')
  const [body, setBody] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function submit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    // customer_id defaults to auth.uid(); RLS rejects anything else.
    const { data, error } = await supabase.from('tickets').insert({ subject, body }).select('id').single()
    if (error) {
      setBusy(false)
      setError(error.message)
      return
    }
    // Classification and embedding run in an Edge Function; the ticket exists either way.
    await triageTicket(data.id)
    setBusy(false)
    navigate(`/tickets/${data.id}`)
  }

  return (
    <section className="narrow">
      <h1>New ticket</h1>
      <form onSubmit={submit} className="card">
        <label>
          Subject
          <input value={subject} onChange={(e) => setSubject(e.target.value)} required maxLength={200} />
        </label>
        <label>
          What is happening?
          <textarea value={body} onChange={(e) => setBody(e.target.value)} required maxLength={10000} rows={8} />
        </label>
        {error && <p className="error" role="alert">{error}</p>}
        <button type="submit" disabled={busy}>{busy ? 'Submitting…' : 'Submit ticket'}</button>
      </form>
    </section>
  )
}
