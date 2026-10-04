// Regenerates src/lib/database.types.ts from the local database schema.
// Writes the file only when generation succeeds: a plain `> file` redirect would
// replace the types with the CLI's error message (for example when Docker is not
// running or not on PATH).
//
//   npm run gen:types
import { execSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'

const target = 'src/lib/database.types.ts'
let types
try {
  types = execSync('npx supabase gen types typescript --local --schema public', {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  })
} catch (err) {
  console.error(`Type generation failed; ${target} left unchanged.`)
  console.error(String(err.stderr || err.stdout || err.message).trim())
  process.exit(1)
}
if (!/export type Database\b/.test(types)) {
  console.error(`Unexpected output from supabase gen types; ${target} left unchanged.`)
  process.exit(1)
}
writeFileSync(target, types)
console.log(`Wrote ${target}.`)
