import { supabase } from './lib/supabase'
import { useRoute, useSession, navigate } from './lib/session'
import { SignIn } from './components/SignIn'
import { TicketList } from './components/TicketList'
import { NewTicket } from './components/NewTicket'
import { TicketDetail } from './components/TicketDetail'

export default function App() {
  const state = useSession()
  const route = useRoute()

  if (state.status === 'loading') return <main><p>Loading…</p></main>
  if (state.status === 'error') return <main><p className="error">Could not load your profile: {state.message}</p></main>
  if (state.status === 'signed-out') return <SignIn />

  const { profile } = state
  const isAgent = profile.role === 'agent'
  const ticketMatch = route.match(/^\/tickets\/(\d+)$/)

  return (
    <>
      <header className="topbar">
        <a href="#/" className="brand">Support Desk</a>
        <span className="who">
          {profile.display_name} · <span className={`role role-${profile.role}`}>{profile.role}</span>
        </span>
        {!isAgent && <button onClick={() => navigate('/new')}>New ticket</button>}
        <button className="secondary" onClick={() => supabase.auth.signOut().then(() => navigate('/'))}>Sign out</button>
      </header>
      <main>
        {ticketMatch ? (
          <TicketDetail ticketId={Number(ticketMatch[1])} profile={profile} />
        ) : route === '/new' && !isAgent ? (
          <NewTicket />
        ) : (
          <TicketList profile={profile} />
        )}
      </main>
    </>
  )
}
