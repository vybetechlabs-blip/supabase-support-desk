// Embed every ticket that has no embedding yet by calling the `triage` Edge Function
// as a seeded agent. Uses the publishable key and a normal user session only:
// the function itself does the privileged write.
//
//   npm run embed:backfill
//
// Reads VITE_SUPABASE_URL / VITE_SUPABASE_PUBLISHABLE_KEY from .env.local.
// Agent login defaults to the local seed account (see supabase/seed.sql).
import { readFileSync } from 'node:fs'
import { createClient } from '@supabase/supabase-js'

const env = Object.fromEntries(
  readFileSync('.env.local', 'utf8')
    .split(/\r?\n/)
    .filter((l) => l.includes('=') && !l.startsWith('#'))
    .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '')]),
)
const supabase = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_PUBLISHABLE_KEY, {
  auth: { persistSession: false },
})

const email = process.env.AGENT_EMAIL ?? 'ava.agent@example.com'
const password = process.env.AGENT_PASSWORD ?? 'desk-demo-pass'
const { error: signInError } = await supabase.auth.signInWithPassword({ email, password })
if (signInError) {
  console.error(`sign-in as ${email} failed: ${signInError.message}`)
  process.exit(1)
}

const { data: tickets, error } = await supabase.from('tickets').select('id').is('embedding', null).order('id')
if (error) {
  console.error(error.message)
  process.exit(1)
}
console.log(`${tickets.length} tickets without an embedding`)

const counts = {}
for (const { id } of tickets) {
  const { data, error } = await supabase.functions.invoke('triage', { body: { ticket_id: id, force: true } })
  if (error) {
    const detail = error.context ? await error.context.text().catch(() => '') : ''
    console.error(`ticket ${id}: ${error.message} ${detail}`)
    process.exitCode = 1
    continue
  }
  counts[data.classifier ?? data.skipped] = (counts[data.classifier ?? data.skipped] ?? 0) + 1
  if (data.embedding_dimensions !== undefined && data.embedding_dimensions !== 384) {
    console.error(`ticket ${id}: unexpected embedding size ${data.embedding_dimensions}`)
    process.exitCode = 1
  }
}
console.log('done:', counts)
