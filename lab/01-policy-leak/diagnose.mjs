// Scenario 1 evidence: query exactly as the customer's browser would, then read
// the policy that produced the result.
import { clientAs, db, heading } from '../common/lib.mjs'

const customer = await clientAs('dana@example.com')

heading('As customer dana@example.com (publishable key + her session): messages on her tickets')
const { data: rows, error } = await customer
  .from('messages')
  .select('id, ticket_id, is_internal, body')
  .order('ticket_id')
if (error) throw error
const internal = rows.filter((r) => r.is_internal)
console.log(`rows returned: ${rows.length}, of which is_internal = true: ${internal.length}`)
for (const r of internal) console.log(`  LEAK? ticket ${r.ticket_id}, message ${r.id}: ${r.body.slice(0, 70)}`)

heading('Direct question: can this customer select any internal note?')
const { count, error: countError } = await customer
  .from('messages')
  .select('id', { count: 'exact', head: true })
  .eq('is_internal', true)
if (countError) throw countError
console.log(`count of is_internal rows visible to the customer: ${count}`)

heading('Select policies on public.messages (pg_policies)')
const sql = db()
const policies = await sql`
  select policyname, roles::text, qual from pg_policies
  where schemaname = 'public' and tablename = 'messages' and cmd = 'SELECT'`
for (const p of policies) console.log(`${p.policyname}  roles=${p.roles}\n  USING ${p.qual}`)
await sql.end()
