-- Scenario 3 by hand.
-- Open Studio > SQL Editor (http://127.0.0.1:54323) and run ONE STEP AT A TIME.
-- Or let the lab run (and time) every step: npm run by-hand -- 3
--
-- Step 2 is a plain SQL version of the agent's list request. It has no embedded
-- customer/assignee names, so it does less work than the API request that
-- diagnose.mjs plans; TROUBLESHOOTING.md shows both and explains the gap.

-- Step 1: table size and the indexes that exist
select pg_relation_size('public.tickets') / current_setting('block_size')::int as heap_pages,
       (select count(*) from public.tickets) as tickets,
       (select string_agg(indexname, ', ' order by indexname) from pg_indexes
        where schemaname = 'public' and tablename = 'tickets') as indexes;

-- Step 2: as ava.agent@example.com (agent), the plan of the list query
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from auth.users where email = 'ava.agent@example.com'), 'role', 'authenticated')::text, true);
set local role authenticated;
explain (analyze, buffers)
select id, subject, status, created_at
from public.tickets
where status = 'open'
order by created_at desc
limit 50;
