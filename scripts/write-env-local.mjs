// Writes .env.local for the browser app from the running local stack.
// Only the API URL and the PUBLISHABLE key are written; the secret key is never
// touched. Refuses to overwrite an existing .env.local unless --force is given.
//
//   npm run env:local
import { execSync } from 'node:child_process'
import { existsSync, writeFileSync } from 'node:fs'

if (existsSync('.env.local') && !process.argv.includes('--force')) {
  console.error('.env.local already exists; leaving it alone (use --force to rewrite it).')
  process.exit(1)
}

let status
try {
  status = execSync('npx supabase status -o env', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
} catch {
  console.error('Could not read `npx supabase status`. Is the local stack running? (npx supabase start)')
  process.exit(1)
}

const vars = Object.fromEntries(
  status
    .split(/\r?\n/)
    .filter((l) => /^[A-Z_]+=/.test(l))
    .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '')]),
)
if (!vars.API_URL || !vars.PUBLISHABLE_KEY) {
  console.error('`supabase status` did not report API_URL and PUBLISHABLE_KEY.')
  process.exit(1)
}

writeFileSync(
  '.env.local',
  `VITE_SUPABASE_URL=${vars.API_URL}\nVITE_SUPABASE_PUBLISHABLE_KEY=${vars.PUBLISHABLE_KEY}\n`,
)
console.log('Wrote .env.local (VITE_SUPABASE_URL, VITE_SUPABASE_PUBLISHABLE_KEY).')
