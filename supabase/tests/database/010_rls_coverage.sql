-- Structural checks: RLS is on everywhere, every table has a policy for each
-- command, and no policy calls auth.uid() or private.is_agent() unwrapped
-- (an unwrapped call is evaluated once per row instead of once per statement).
begin;
select plan(9);

select is(
  (select count(*) from pg_tables where schemaname = 'public' and not rowsecurity),
  0::bigint,
  'every table in public has row level security enabled'
);

select set_eq(
  $$ select cmd from pg_policies where schemaname = 'public' and tablename = 'profiles' $$,
  array['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
  'profiles has a policy for select, insert, update and delete'
);
select set_eq(
  $$ select cmd from pg_policies where schemaname = 'public' and tablename = 'tickets' $$,
  array['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
  'tickets has a policy for select, insert, update and delete'
);
select set_eq(
  $$ select cmd from pg_policies where schemaname = 'public' and tablename = 'messages' $$,
  array['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
  'messages has a policy for select, insert, update and delete'
);

select is_empty(
  $$ select policyname from pg_policies
     where schemaname = 'public' and roles <> array['authenticated']::name[] $$,
  'every policy applies to authenticated only (anon gets no access)'
);

select is_empty(
  $$ select policyname from pg_policies
     where schemaname = 'public'
       and (coalesce(qual, '') ~ '(?<!SELECT )auth\.uid\(\)'
         or coalesce(with_check, '') ~ '(?<!SELECT )auth\.uid\(\)') $$,
  'no policy calls auth.uid() outside a (select ...) wrapper'
);

select is_empty(
  $$ select policyname from pg_policies
     where schemaname = 'public'
       and (coalesce(qual, '') ~ '(?<!SELECT )private\.is_agent\(\)'
         or coalesce(with_check, '') ~ '(?<!SELECT )private\.is_agent\(\)') $$,
  'no policy calls private.is_agent() outside a (select ...) wrapper'
);

select is(
  (select prosecdef from pg_proc where oid = 'private.is_agent()'::regprocedure),
  true,
  'private.is_agent() is security definer (reads profiles without re-entering its policies)'
);

select is(
  (select has_function_privilege('anon', 'private.is_agent()', 'execute')),
  false,
  'anon cannot execute private.is_agent()'
);

select * from finish();
rollback;
