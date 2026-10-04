// Runs one lab scenario end to end on the LOCAL stack and records everything:
//
//   reset -> (bulk seed) -> break -> diagnose -> by-hand SQL -> test (must FAIL)
//         -> fix -> diagnose -> by-hand SQL -> test (must PASS)
//
// diagnose.mjs gathers evidence through the API (supabase-js, as the app does).
// by-hand.sql is the SQL a reader runs in Studio's SQL editor, one step at a time;
// lab/common/by-hand.mjs sends each step to Studio's own SQL endpoint. For scenarios
// 3 and 4 the EXPLAIN steps are timed (1 warm-up + 7 runs), so both sets of numbers
// come from the same database state.
//
//   npm run lab -- 1        (or 2, 3, 4, all)
//
// WARNING: starts with `supabase db reset`, which wipes the local database.
// Output goes to the console and to lab/out/<scenario>.log (git-ignored).
import { spawnSync } from 'node:child_process'
import { mkdirSync, writeFileSync, readdirSync } from 'node:fs'

const SCENARIOS = {
  1: { dir: '01-policy-leak', bulk: false, timed: false },
  2: { dir: '02-blocked-reply', bulk: false, timed: false },
  3: { dir: '03-slow-ticket-list', bulk: true, timed: true },
  4: { dir: '04-slow-policy', bulk: true, timed: true },
}

const arg = process.argv[2] ?? 'all'
const which = arg === 'all' ? Object.keys(SCENARIOS) : [arg]
if (!which.every((k) => SCENARIOS[k])) {
  console.error(`usage: npm run lab -- <1|2|3|4|all>  (scenarios: ${readdirSync('lab').filter((d) => /^\d\d-/.test(d)).join(', ')})`)
  process.exit(2)
}

mkdirSync('lab/out', { recursive: true })

function run(cmd, args) {
  // One command string through the shell (npx is a .cmd on Windows). Arguments here are
  // fixed strings from this file, never user input.
  const r = spawnSync([cmd, ...args].join(' '), { encoding: 'utf8', shell: true, maxBuffer: 64 * 1024 * 1024 })
  return { code: r.status, out: (r.stdout ?? '') + (r.stderr ?? '') }
}

let failures = 0
for (const n of which) {
  const { dir, bulk, timed } = SCENARIOS[n]
  const base = `lab/${dir}`
  const log = []
  const say = (s) => {
    console.log(s)
    log.push(s)
  }
  const step = (title, cmd, args, { show = true } = {}) => {
    say(`\n##### ${title}\n$ ${[cmd, ...args].join(' ')}`)
    const r = run(cmd, args)
    if (show) say(r.out.trimEnd())
    say(`(exit ${r.code})`)
    return r
  }
  const testArgs = ['supabase', 'test', 'db', '--local', 'supabase/tests/database/000_setup_helpers.sql', `${base}/test.sql`]

  say(`# Lab scenario ${n}: ${dir}  (${new Date().toISOString()})`)
  const reset = step('Reset local database', 'npx', ['supabase', 'db', 'reset', '--local'], { show: false })
  if (reset.code !== 0) throw new Error('db reset failed')
  if (bulk) step('Load 50,000 lab tickets', 'node', ['scripts/sql.mjs', 'lab/common/bulk-seed.sql'])
  // Lets supabase-js .explain() return plans for API requests. Local only; scoped to
  // this database, so the next `db reset` removes it. Never enable this in production.
  step('Enable API query plans (local lab only)', 'node', [
    'scripts/sql.mjs', '-c',
    `"alter role authenticator in database postgres set pgrst.db_plan_enabled to 'true'"`,
  ])
  step('Reload PostgREST config', 'node', ['scripts/sql.mjs', '-c', `"notify pgrst, 'reload config'"`])
  await new Promise((r) => setTimeout(r, 2000))

  const byHand = (when) =>
    step(`BY HAND (${when}): by-hand.sql step by step through Studio's SQL endpoint${timed ? ', EXPLAIN steps timed (1 warm-up + 7 runs)' : ''}`,
      'node', ['lab/common/by-hand.mjs', `${base}/by-hand.sql`, ...(timed ? ['--runs', '7'] : [])])

  if (step('BREAK: reproduce the reported state', 'node', ['scripts/sql.mjs', `${base}/break.sql`]).code !== 0) throw new Error('break.sql failed')
  step('DIAGNOSE (before fix)', 'node', [`${base}/diagnose.mjs`])
  byHand('before fix')
  const before = step('TEST (before fix, expected to FAIL)', 'npx', testArgs)
  if (step('FIX: apply the fix migration', 'node', ['scripts/sql.mjs', `${base}/fix.sql`]).code !== 0) throw new Error('fix.sql failed')
  step('DIAGNOSE (after fix)', 'node', [`${base}/diagnose.mjs`])
  byHand('after fix')
  const after = step('TEST (after fix, expected to PASS)', 'npx', testArgs)

  const ok = before.code !== 0 && after.code === 0
  say(`\n# RESULT scenario ${n}: test before fix ${before.code !== 0 ? 'FAILED (expected)' : 'PASSED (unexpected!)'}, after fix ${after.code === 0 ? 'PASSED' : 'FAILED (unexpected!)'} -> ${ok ? 'OK' : 'NOT OK'}`)
  if (!ok) failures++
  writeFileSync(`lab/out/${dir}.log`, log.join('\n') + '\n')
}
process.exit(failures ? 1 : 0)
