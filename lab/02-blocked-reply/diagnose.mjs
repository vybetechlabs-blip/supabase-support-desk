// Scenario 2 evidence: reproduce the client error, rule out a missing grant, find
// the insert policy, then evaluate each of its conditions as the affected user.
import { clientAs, db, heading } from '../common/lib.mjs'

const email = 'dana@example.com'
const customer = await clientAs(email)
const { data: { user } } = await customer.auth.getUser()

// Her first ticket that is not resolved (any of hers would do: the bug is ownership vs assignment).
const { data: tickets, error: tErr } = await customer
  .from('tickets')
  .select('id, subject, status, assignee_id')
  .order('id')
if (tErr) throw tErr
const ticket = tickets.find((t) => t.status !== 'resolved') ?? tickets[0]
console.log(`customer ${email} (${user.id}) replies on her own ticket #${ticket.id} "${ticket.subject}" (assignee_id: ${ticket.assignee_id ?? 'null'})`)

heading('1. What the client receives')
const res = await customer.from('messages').insert({ ticket_id: ticket.id, body: 'Any update on this?' })
console.log(`HTTP ${res.status} ${res.statusText}`)
console.log(JSON.stringify(res.error, null, 2))

const sql = db()

heading('2. Is it a missing table privilege? (that would say "permission denied for table")')
const [priv] = await sql`select has_table_privilege('authenticated', 'public.messages', 'INSERT') as authenticated_can_insert`
console.log(priv)

heading('3. INSERT policies on public.messages (pg_policies)')
const policies = await sql`
  select policyname, permissive, roles::text, with_check from pg_policies
  where schemaname = 'public' and tablename = 'messages' and cmd = 'INSERT'`
for (const p of policies) console.log(`${p.policyname}  ${p.permissive} roles=${p.roles}\n  WITH CHECK ${p.with_check}`)

heading('4. Each condition of the WITH CHECK, evaluated as the customer for the row she sent')
// Same identity the API uses: role authenticated + her JWT claims, inside a rolled-back transaction.
const parts = await sql.begin(async (tx) => {
  await tx`select set_config('request.jwt.claims', ${JSON.stringify({ sub: user.id, role: 'authenticated' })}, true)`
  await tx`set local role authenticated`
  const [row] = await tx`
    select
      (select auth.uid()) = ${user.id}::uuid                                   as author_is_caller,
      false = false                                                            as not_internal,
      (select private.is_agent())                                              as caller_is_agent,
      ${ticket.id}::bigint in (select id from public.tickets
                               where assignee_id = (select auth.uid()))        as ticket_assigned_to_caller,
      ${ticket.id}::bigint in (select id from public.tickets
                               where customer_id = (select auth.uid()))        as ticket_owned_by_caller`
  throw Object.assign(new Error('rollback'), { row })
}).catch((e) => e.row)
console.log(parts)
await sql.end()
