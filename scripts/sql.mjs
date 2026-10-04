// Run a .sql file or inline SQL against the LOCAL database, one statement at a time
// (like psql), printing every result set, notice and error. `supabase db query` runs
// one statement per call, and psql is not required to use this repo.
//
//   node scripts/sql.mjs path/to/file.sql
//   node scripts/sql.mjs -c "select 1"
//
// Exits 1 if any statement failed. DATABASE_URL overrides the default local
// connection string printed by `supabase status`.
import { readFileSync } from 'node:fs'
import postgres from 'postgres'
import { runStatements } from './lib/sqlrun.mjs'

const url = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres'
const args = process.argv.slice(2)
const text = args[0] === '-c' ? args[1] : args[0] ? readFileSync(args[0], 'utf8') : ''
if (!text) {
  console.error('usage: node scripts/sql.mjs <file.sql> | -c "<sql>"')
  process.exit(2)
}

const sql = postgres(url, {
  max: 1,
  onnotice: (n) => console.log(`NOTICE: ${n.message}`),
})

function printRows(rows) {
  if (!Array.isArray(rows)) return
  if (rows.length === 0) {
    console.log(rows.command && rows.command !== 'SELECT' ? `${rows.command} ${rows.count ?? ''}`.trim() : '(0 rows)')
    return
  }
  const cols = Object.keys(rows[0])
  if (cols.length === 1 && cols[0] === 'QUERY PLAN') {
    for (const r of rows) console.log(r['QUERY PLAN'])
    return
  }
  console.table(rows.map((r) => Object.fromEntries(cols.map((c) => [c, r[c]]))))
}

const errors = await runStatements(sql, text, ({ rows, error }) => {
  if (error) console.error(`ERROR ${error.code ?? ''}: ${error.message}`)
  else printRows(rows)
})
await sql.end()
process.exitCode = errors ? 1 : 0
