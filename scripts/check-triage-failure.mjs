// End-to-end check of triage when the classifier call fails.
//
// Serve the functions with an env file whose ANTHROPIC_API_KEY is invalid (keep the
// file outside the repo; --env-file replaces supabase/functions/.env for that run):
//
//   echo ANTHROPIC_API_KEY=invalid-key-for-failure-test > ../triage-failure.env
//   npx supabase functions serve --env-file ../triage-failure.env
//
// then, in another terminal:  npm run check:triage-failure
// Stop the serve command and restart the stack (npx supabase stop, npx supabase start)
// to go back to the normal functions env afterwards.
//
// Expects: ticket creation succeeds, triage answers 200 with classifier "error",
// the ticket gets its 384-dimension embedding, category and priority stay empty,
// and an agent's re-run reports the same failure.
import { readFileSync } from 'node:fs'
import { createClient } from '@supabase/supabase-js'
import postgres from 'postgres'

const env = Object.fromEntries(
  readFileSync('.env.local', 'utf8')
    .split(/\r?\n/)
    .filter((l) => l.includes('=') && !l.startsWith('#'))
    .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '')]),
)
const PASSWORD = 'desk-demo-pass' // local seed value, see supabase/seed.sql
const DB_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres'

async function signIn(email) {
  const client = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } })
  const { error } = await client.auth.signInWithPassword({ email, password: PASSWORD })
  if (error) throw new Error(`sign-in as ${email}: ${error.message}`)
  return client
}

let failures = 0
function check(label, ok, detail) {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? `  (${detail})` : ''}`)
  if (!ok) failures++
}

const customer = await signIn('gus@example.com')
const { data: ticket, error: insertError } = await customer
  .from('tickets')
  .insert({ subject: 'Triage failure check', body: `Created by scripts/check-triage-failure.mjs at ${new Date().toISOString()}.` })
  .select('id')
  .single()
check('customer creates a ticket', !insertError && ticket?.id, insertError?.message ?? `ticket #${ticket?.id}`)
if (insertError) process.exit(1)

const first = await customer.functions.invoke('triage', { body: { ticket_id: ticket.id } })
check('triage answers 200 for the customer', !first.error, first.error?.message)
check('classifier reports a failure, not a classification', first.data?.classifier === 'error', JSON.stringify(first.data))

const sql = postgres(DB_URL, { max: 1 })
const [row] = await sql`
  select category, priority, triaged_at is not null as triaged,
         case when embedding is null then null else vector_dims(embedding) end as dims
  from public.tickets where id = ${ticket.id}`
await sql.end()
check('ticket still exists', !!row)
check('embedding stored (384 dimensions)', row?.dims === 384, `dims=${row?.dims}`)
check('category and priority left empty', row?.category === null && row?.priority === null, `${row?.category} / ${row?.priority}`)
check('ticket marked triaged', row?.triaged === true)

const agent = await signIn('ava.agent@example.com')
const rerun = await agent.functions.invoke('triage', { body: { ticket_id: ticket.id, force: true } })
check('agent re-run reports the failure', !rerun.error && rerun.data?.classifier === 'error', JSON.stringify(rerun.data))

console.log(failures ? `\n${failures} check(s) failed` : '\nall checks passed')
process.exit(failures ? 1 : 0)
