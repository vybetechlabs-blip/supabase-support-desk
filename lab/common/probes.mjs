// Two small measurements that TROUBLESHOOTING.md relies on:
//
// 1. First run in a new database session reads extra (catalog) buffers.
//    Runs scenario 4's step 2 (a count as the agent, RLS applied) three times on
//    one connection, then twice on a second, new connection, and prints the scan
//    node's buffer count each time. Works in any lab state: category is never indexed.
// 2. Size of a real session token's JWT claims (payload only; the token is never printed).
//
//   node lab/common/probes.mjs
import { readFileSync } from 'node:fs'
import postgres from 'postgres'
import { clientAs, DB_URL } from './lib.mjs'

const file = readFileSync('lab/04-slow-policy/by-hand.sql', 'utf8')
const step2 = '--' + file.split('-- Step 2:')[1].split('-- Step 3:')[0]

function scanBuffers(result) {
  const sets = Array.isArray(result[0]) ? result : [result]
  const plan = sets.find((r) => r.length && 'QUERY PLAN' in r[0]).map((r) => r['QUERY PLAN'])
  const i = plan.findIndex((l) => l.includes('Seq Scan'))
  return plan.slice(i + 1).find((l) => l.includes('Buffers')).trim()
}

console.log('1. Seq Scan buffers for scenario 4 step 2, by session and run')
for (const session of ['A', 'B (new connection)']) {
  const sql = postgres(DB_URL, { max: 1, onnotice: () => {} })
  const runs = session === 'A' ? 3 : 2
  for (let n = 1; n <= runs; n++) {
    console.log(`  session ${session}, run ${n}: ${scanBuffers(await sql.unsafe(step2).simple())}`)
  }
  await sql.end()
}
const [{ pages }] = await (async () => {
  const sql = postgres(DB_URL, { max: 1 })
  const r = await sql`select pg_relation_size('public.tickets') / current_setting('block_size')::int as pages`
  await sql.end()
  return r
})()
console.log(`  table heap pages: ${pages}`)

console.log('\n2. JWT claims of a real session for ava.agent@example.com')
const agent = await clientAs('ava.agent@example.com')
const { data: { session } } = await agent.auth.getSession()
const claims = JSON.parse(Buffer.from(session.access_token.split('.')[1], 'base64url').toString())
console.log(`  claim keys: ${Object.keys(claims).join(', ')}`)
console.log(`  size: ${JSON.stringify(claims).length} bytes`)
console.log(`  minimal claims used in by-hand step 2: ${JSON.stringify({ sub: claims.sub, role: 'authenticated' }).length} bytes`)
