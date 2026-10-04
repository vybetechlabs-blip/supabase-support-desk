// Runs a scenario's by-hand.sql the way a reader does: each "-- Step" block is sent
// on its own to the local Studio's SQL endpoint (the one its SQL editor uses; it
// runs as postgres), so `set local` lasts for that step only and the result shown
// is the step's last statement, exactly as in Studio.
//
//   npm run by-hand -- 3              (scenario number or a path to a .sql file)
//   npm run by-hand -- 3 --runs 7     (time each EXPLAIN step: 1 warm-up + 7 runs)
//
// STUDIO_URL overrides http://127.0.0.1:54323.
import { readFileSync, readdirSync } from 'node:fs'
import { median, executionMs } from './lib.mjs'

const STUDIO = process.env.STUDIO_URL ?? 'http://127.0.0.1:54323'
const args = process.argv.slice(2)
const runsAt = args.indexOf('--runs')
const RUNS = runsAt >= 0 ? Number(args[runsAt + 1]) : 0
const target = args[0]
const file = /^\d$/.test(target ?? '')
  ? `lab/${readdirSync('lab').find((d) => d.startsWith(`0${target}-`))}/by-hand.sql`
  : target
if (!file) {
  console.error('usage: npm run by-hand -- <1|2|3|4|file.sql> [--runs N]')
  process.exit(2)
}

// Split into steps: each starts at a line beginning "-- Step".
const steps = []
for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) {
  if (/^-- Step/.test(line)) steps.push({ title: line.replace(/^--\s*/, ''), sql: '' })
  else if (steps.length) steps[steps.length - 1].sql += line + '\n'
}

async function runInStudio(query) {
  const res = await fetch(`${STUDIO}/api/platform/pg-meta/default/query`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ query }),
  })
  const body = await res.json()
  return res.ok ? { rows: body } : { error: body.formattedError ?? body.message ?? JSON.stringify(body) }
}

const isPlan = (rows) => Array.isArray(rows) && rows.length > 0 && 'QUERY PLAN' in rows[0]
const planText = (rows) => rows.map((r) => r['QUERY PLAN']).join('\n')

console.log(`by hand: ${file} (via ${STUDIO}, Studio's SQL endpoint, role postgres)`)
for (const step of steps) {
  console.log(`\n--- ${step.title}`)
  const first = await runInStudio(step.sql)
  if (first.error) {
    console.log(first.error.trimEnd())
    continue
  }
  if (!isPlan(first.rows)) {
    console.table(first.rows)
    continue
  }
  if (!RUNS) {
    console.log(planText(first.rows))
    continue
  }
  // The first run above is the warm-up; time RUNS more.
  const times = []
  let shown = ''
  for (let i = 0; i < RUNS; i++) {
    const r = await runInStudio(step.sql)
    if (r.error) throw new Error(r.error)
    const text = planText(r.rows)
    if (i === 0) shown = text
    times.push(executionMs(text))
  }
  console.log(shown)
  console.log(`Execution Time over ${RUNS} runs after 1 warm-up (ms): ${times.join(', ')}`)
  console.log(`median: ${median(times)} ms`)
}
