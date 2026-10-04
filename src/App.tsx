import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'

export default function App() {
  const [status, setStatus] = useState('checking…')

  useEffect(() => {
    supabase.auth.getSession().then(({ error }) => {
      setStatus(error ? `error: ${error.message}` : 'connected')
    })
  }, [])

  return (
    <main>
      <h1>Support Desk</h1>
      <p>Supabase: <span data-testid="sb-status">{status}</span></p>
    </main>
  )
}
