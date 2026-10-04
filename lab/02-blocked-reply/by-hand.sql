-- Scenario 2 by hand.
-- Open Studio > SQL Editor (http://127.0.0.1:54323) and run ONE STEP AT A TIME.
-- Or let the lab run every step: npm run by-hand -- 2
-- Ticket 9 is one of dana@example.com's own tickets in the seed data.

-- Step 1: reproduce the error, as dana@example.com replying on her own ticket
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from auth.users where email = 'dana@example.com'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into public.messages (ticket_id, body) values (9, 'Any update on this?')
returning id;

-- Step 2: is it a missing table privilege? (that error says "permission denied for table")
select has_table_privilege('authenticated', 'public.messages', 'INSERT') as authenticated_can_insert;

-- Step 3: the insert policies and their WITH CHECK expressions
select policyname, with_check
from pg_policies
where schemaname = 'public' and tablename = 'messages' and cmd = 'INSERT';

-- Step 4: as dana@example.com, evaluate each condition of the customer branch for ticket 9
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from auth.users where email = 'dana@example.com'), 'role', 'authenticated')::text, true);
set local role authenticated;
select (select private.is_agent()) as caller_is_agent,
       9 in (select id from public.tickets where assignee_id = (select auth.uid())) as ticket_assigned_to_caller,
       9 in (select id from public.tickets where customer_id = (select auth.uid())) as ticket_owned_by_caller;
