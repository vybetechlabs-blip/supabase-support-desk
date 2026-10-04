// Run a .sql file (multi-statement) or inline SQL against the LOCAL database and print
// every result set and server notice. `supabase db query` runs one statement per call,
// and psql is not required to use this repo, so the lab scripts use this runner.
//
//   node scripts/sql.mjs path/to/file.sql
//   node scripts/sql.mjs -c "select 1"
//
// DATABASE_URL overrides the default local connection string printed by `supabase status`.
import { readFileSync } from 'node:fs'
import postgres from 'postgres'

const url = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres'
const args = process.argv.slice(2)
const text = args[0] === '-c' ? args[1] : readFileSync(args[0], 'utf8')
if (!text) {
  console.error('usage: node scripts/sql.mjs <file.sql> | -c "<sql>"')
  process.exit(2)
}

const sql = postgres(url, {
  max: 1,
  onnotice: (n) => console.log(`NOTICE: ${n.message}`),
})

function printResult(rows) {
  if (!Array.isArray(rows)) return
  if (rows.length === 0) {
    if (rows.command && rows.command !== 'SELECT') console.log(`${rows.command} ${rows.count ?? ''}`.trim())
    else console.log('(0 rows)')
    return
  }
  const cols = Object.keys(rows[0])
  // EXPLAIN output: print the plan lines as-is.
  if (cols.length === 1 && cols[0] === 'QUERY PLAN') {
    for (const r of rows) console.log(r['QUERY PLAN'])
    return
  }
  console.table(rows.map((r) => Object.fromEntries(cols.map((c) => [c, r[c]]))))
}

try {
  const result = await sql.unsafe(text).simple()
  const sets = Array.isArray(result) && Array.isArray(result[0]) ? result : [result]
  for (const rows of sets) printResult(rows)
} catch (err) {
  console.error(`ERROR ${err.code ?? ''}: ${err.message}`)
  process.exitCode = 1
} finally {
  await sql.end()
}
