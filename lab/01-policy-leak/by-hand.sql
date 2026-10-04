-- Scenario 1 by hand.
-- Open Studio > SQL Editor (http://127.0.0.1:54323) and run ONE STEP AT A TIME
-- (paste a step, or select its lines and run the selection). Studio runs the text
-- as one transaction and shows the result of the last statement, so `set local`
-- lasts only for that run. Or let the lab run every step: npm run by-hand -- 1
--
-- The SQL editor connects as postgres, which bypasses RLS. Steps that say
-- "as <user>" first set that user's JWT claims and then switch to the
-- authenticated role: the same identity the API uses for a signed-in request.

-- Step 1: as dana@example.com (customer), count the internal notes she can read
-- (always one row, so an empty result cannot be mistaken for the previous statement's)
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from auth.users where email = 'dana@example.com'), 'role', 'authenticated')::text, true);
set local role authenticated;
select count(*) as internal_notes_visible,
       string_agg(format('ticket %s: %s', ticket_id, left(body, 40)), ' | ' order by ticket_id) as notes
from public.messages
where is_internal;

-- Step 2: the select policy that decided it
select policyname, qual
from pg_policies
where schemaname = 'public' and tablename = 'messages' and cmd = 'SELECT';
