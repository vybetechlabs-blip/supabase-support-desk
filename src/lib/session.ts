import { useEffect, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase, type Profile } from './supabase'

export type SessionState =
  | { status: 'loading' }
  | { status: 'signed-out' }
  | { status: 'signed-in'; session: Session; profile: Profile }
  | { status: 'error'; message: string }

// Tracks the auth session and loads the caller's profile (which carries the role).
export function useSession(): SessionState {
  const [state, setState] = useState<SessionState>({ status: 'loading' })

  useEffect(() => {
    let cancelled = false

    async function load(session: Session | null) {
      if (!session) {
        if (!cancelled) setState({ status: 'signed-out' })
        return
      }
      const { data, error } = await supabase.from('profiles').select('*').eq('id', session.user.id).single()
      if (cancelled) return
      if (error) setState({ status: 'error', message: error.message })
      else setState({ status: 'signed-in', session, profile: data })
    }

    supabase.auth.getSession().then(({ data }) => load(data.session))
    const { data: sub } = supabase.auth.onAuthStateChange((event, session) => {
      // Token refreshes do not change the profile; avoid a needless reload.
      if (event === 'TOKEN_REFRESHED') return
      // Defer the query: supabase-js warns against awaiting calls inside this callback.
      setTimeout(() => load(session), 0)
    })
    return () => {
      cancelled = true
      sub.subscription.unsubscribe()
    }
  }, [])

  return state
}

// Minimal hash router: #/ (list), #/new, #/tickets/123
export function useRoute(): string {
  const [route, setRoute] = useState(() => window.location.hash.slice(1) || '/')
  useEffect(() => {
    const onChange = () => setRoute(window.location.hash.slice(1) || '/')
    window.addEventListener('hashchange', onChange)
    return () => window.removeEventListener('hashchange', onChange)
  }, [])
  return route
}

export function navigate(path: string) {
  window.location.hash = path
}
