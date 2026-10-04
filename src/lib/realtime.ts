import { useEffect, useRef } from 'react'
import { supabase } from './supabase'

type Change = { table: 'tickets' | 'messages'; event: 'INSERT' | 'UPDATE' | '*'; filter?: string }

// Subscribes to Postgres Changes and calls onChange for each event. Realtime checks
// every event against this user's RLS policies before sending it, so a customer
// never receives another customer's ticket or an internal note.
export function useRealtime(channelName: string, changes: Change[], onChange: () => void) {
  const callback = useRef(onChange)
  useEffect(() => {
    callback.current = onChange
  })

  const key = JSON.stringify(changes)
  useEffect(() => {
    let channel = supabase.channel(channelName)
    for (const c of JSON.parse(key) as Change[]) {
      channel = channel.on(
        'postgres_changes',
        { event: c.event, schema: 'public', table: c.table, ...(c.filter ? { filter: c.filter } : {}) },
        () => callback.current(),
      )
    }
    channel.subscribe()
    return () => {
      supabase.removeChannel(channel)
    }
  }, [channelName, key])
}
