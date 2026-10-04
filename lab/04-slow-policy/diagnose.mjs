// Scenario 4 evidence: the same count is fast in the SQL editor (table owner, no
// RLS) and slow from the app (agent, RLS). Compare both plans, then count how many
// times the policy's role helper runs for one request.
import { clientAs, db, heading, median, executionMs } from '../common/lib.mjs'

const RUNS = 7
const agent = await clientAs('ava.agent@example.com')
const { data: { user } } = await agent.auth.getUser()

// "How many billing tickets?" as a client would ask it: an exact count plus a
// one-row page. (A head:true request has no response body, so .explain() needs a
// GET; the count part of the plan is the same.)
const countBilling = () =>
  agent.from('tickets').select('id', { count: 'exact' }).eq('category', 'billing').limit(1)

const sql = db()

heading('Same question in the SQL editor (role postgres, RLS bypassed)')
const ownerTimes = []
let ownerPlan = ''
for (let i = 0; i < RUNS + 1; i++) {
  const rows = await sql.unsafe(`explain (analyze, buffers) select count(*) from public.tickets where category = 'billing'`)
  const text = rows.map((r) => r['QUERY PLAN']).join('\n')
  if (i === 1) ownerPlan = text
  if (i > 0) ownerTimes.push(executionMs(text)) // first run is a warm-up
}
console.log(ownerPlan)
console.log(`Execution Time over ${RUNS} runs (ms): ${ownerTimes.join(', ')}`)
console.log(`median: ${median(ownerTimes)} ms`)

heading('From the app as agent ava.agent@example.com (API request, RLS applies)')
const { count } = await countBilling()
console.log(`API count result: ${count}`)
await countBilling().explain({ analyze: true }) // warm-up
const apiTimes = []
let apiPlan = ''
for (let i = 0; i < RUNS; i++) {
  const { data, error } = await countBilling().explain({ analyze: true, buffers: true })
  if (error) throw error
  if (i === 0) apiPlan = data
  apiTimes.push(executionMs(data))
}
console.log(apiPlan)
console.log(`Execution Time over ${RUNS} runs (ms): ${apiTimes.join(', ')}`)
console.log(`median: ${median(apiTimes)} ms`)

heading('Policy on public.tickets for SELECT (pg_policies)')
for (const p of await sql`select policyname, qual from pg_policies where schemaname = 'public' and tablename = 'tickets' and cmd = 'SELECT'`) {
  console.log(`${p.policyname}\n  USING ${p.qual}`)
}

heading('How many times does private.is_agent() run for ONE count, as the agent?')
const calls = await sql.begin(async (tx) => {
  await tx`set local track_functions = 'all'`
  await tx`select set_config('request.jwt.claims', ${JSON.stringify({ sub: user.id, role: 'authenticated' })}, true)`
  await tx`set local role authenticated`
  const [c] = await tx`select count(*)::int as n from public.tickets where category = 'billing'`
  await tx`reset role`
  const [f] = await tx`select coalesce(sum(calls), 0)::int as calls from pg_stat_xact_user_functions where schemaname = 'private' and funcname = 'is_agent'`
  throw Object.assign(new Error('rollback'), { result: { rows_counted: c.n, is_agent_calls: f.calls } })
}).catch((e) => e.result)
console.log(calls)
await sql.end()
