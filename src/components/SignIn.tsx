import { useState, type FormEvent } from 'react'
import { supabase } from '../lib/supabase'

export function SignIn() {
  const [mode, setMode] = useState<'sign-in' | 'sign-up'>('sign-in')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [displayName, setDisplayName] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function submit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    const { error } =
      mode === 'sign-in'
        ? await supabase.auth.signInWithPassword({ email, password })
        : await supabase.auth.signUp({ email, password, options: { data: { display_name: displayName } } })
    setBusy(false)
    if (error) setError(error.message)
  }

  return (
    <main className="narrow">
      <h1>Support Desk</h1>
      <form onSubmit={submit} className="card">
        <h2>{mode === 'sign-in' ? 'Sign in' : 'Create a customer account'}</h2>
        {mode === 'sign-up' && (
          <label>
            Your name
            <input value={displayName} onChange={(e) => setDisplayName(e.target.value)} required maxLength={100} />
          </label>
        )}
        <label>
          Email
          <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} required autoComplete="email" />
        </label>
        <label>
          Password
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
            minLength={6}
            autoComplete={mode === 'sign-in' ? 'current-password' : 'new-password'}
          />
        </label>
        {error && <p className="error" role="alert">{error}</p>}
        <button type="submit" disabled={busy}>{mode === 'sign-in' ? 'Sign in' : 'Sign up'}</button>
        <button type="button" className="link" onClick={() => setMode(mode === 'sign-in' ? 'sign-up' : 'sign-in')}>
          {mode === 'sign-in' ? 'New customer? Create an account' : 'Have an account? Sign in'}
        </button>
      </form>
      <p className="muted">Local demo accounts are listed at the top of <code>supabase/seed.sql</code>.</p>
    </main>
  )
}
