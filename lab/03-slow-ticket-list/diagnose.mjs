// Scenario 3 evidence: the plan of the exact API request the agent's ticket list
// sends (same select, filter, order and limit as src/components/TicketList.tsx),
// captured through PostgREST with supabase-js .explain(). Needs
// pgrst.db_plan_enabled on the authenticator role (lab/run.mjs sets it locally).
import { clientAs, db, heading, median, executionMs } from '../common/lib.mjs'

const RUNS = 7
const agent = await clientAs('ava.agent@example.com')

function listQuery() {
  return agent
    .from('tickets')
    .select(
      'id, subject, status, category, priority, created_at, updated_at,' +
        ' customer:profiles!tickets_customer_id_fkey(display_name),' +
        ' assignee:profiles!tickets_assignee_id_fkey(display_name)',
    )
    .eq('status', 'open')
    .order('created_at', { ascending: false })
    .limit(50)
}

const sql = db()
heading('Table size and indexes on public.tickets')
const [size] = await sql`select count(*)::int as rows, pg_size_pretty(pg_relation_size('public.tickets')) as heap from public.tickets`
console.log(size)
for (const i of await sql`select indexname, indexdef from pg_indexes where schemaname = 'public' and tablename = 'tickets' order by indexname`) {
  console.log(`  ${i.indexdef}`)
}
await sql.end()

heading('Agent list request through the API, EXPLAIN (ANALYZE, BUFFERS)')
// Warm-up so the first measured run is not paying for a cold cache.
await listQuery().explain({ analyze: true })
const times = []
let firstPlan = ''
for (let i = 0; i < RUNS; i++) {
  const { data, error } = await listQuery().explain({ analyze: true, buffers: true })
  if (error) throw error
  if (i === 0) firstPlan = data
  times.push(executionMs(data))
}
console.log(firstPlan)
heading(`Execution Time over ${RUNS} runs (ms)`)
console.log(times.join(', '))
console.log(`median: ${median(times)} ms`)
