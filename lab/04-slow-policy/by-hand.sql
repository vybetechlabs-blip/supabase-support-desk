-- Scenario 4 by hand.
-- Open Studio > SQL Editor (http://127.0.0.1:54323) and run ONE STEP AT A TIME.
-- Or let the lab run (and time) every step: npm run by-hand -- 4

-- Step 1: the count as the table owner (the SQL editor's default; RLS bypassed)
explain (analyze, buffers)
select count(*) from public.tickets where category = 'billing';

-- Step 2: the same count as ava.agent@example.com (agent), with minimal JWT claims
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from auth.users where email = 'ava.agent@example.com'), 'role', 'authenticated')::text, true);
set local role authenticated;
explain (analyze, buffers)
select count(*) from public.tickets where category = 'billing';

-- Step 3: the same count with claims the size of a real session token.
-- A real access token carries about a dozen claims (email, app_metadata,
-- user_metadata, amr, session_id, ...). This builds a token-shaped set from the
-- user's row, so the per-row cost matches what the API sees.
select set_config('request.jwt.claims', json_build_object(
  'iss', 'http://127.0.0.1:54321/auth/v1', 'sub', u.id, 'aud', 'authenticated',
  'exp', extract(epoch from now())::int + 3600, 'iat', extract(epoch from now())::int,
  'email', u.email, 'phone', '', 'app_metadata', u.raw_app_meta_data,
  'user_metadata', u.raw_user_meta_data, 'role', 'authenticated', 'aal', 'aal1',
  'amr', json_build_array(json_build_object('method', 'password', 'timestamp', extract(epoch from now())::int)),
  'session_id', gen_random_uuid(), 'is_anonymous', false)::text, true)
from auth.users u where u.email = 'ava.agent@example.com';
set local role authenticated;
explain (analyze, buffers)
select count(*) from public.tickets where category = 'billing';

-- Step 4: as the agent, how many times does private.is_agent() run for that one count?
set local track_functions = 'all';
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from auth.users where email = 'ava.agent@example.com'), 'role', 'authenticated')::text, true);
set local role authenticated;
select count(*) from public.tickets where category = 'billing';
reset role;
select coalesce(sum(calls), 0) as is_agent_calls from pg_stat_xact_user_functions
where schemaname = 'private' and funcname = 'is_agent';

-- Step 5: the select policy on tickets
select policyname, qual from pg_policies
where schemaname = 'public' and tablename = 'tickets' and cmd = 'SELECT';
