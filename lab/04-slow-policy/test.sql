-- Scenario 4 regression test: an agent query over 50,000 tickets evaluates the
-- role lookup once per statement, not once per row, and still returns the same
-- rows. Fails with the unwrapped policy, passes after fix.sql.
-- Needs lab/common/bulk-seed.sql loaded.
begin;
select plan(3);

select ok((select count(*) from public.tickets) >= 50000, 'precondition: at least 50,000 tickets loaded');

create temporary table expected as
  select count(*) as n from public.tickets where category = 'billing';
create temporary table observed (n bigint);
grant select on expected to authenticated;
grant insert, select on observed to authenticated;

-- Count function calls made in this transaction (pg_stat_xact_user_functions).
set local track_functions = 'all';

select tests.create_user('lab4.agent@test.local', 'agent');
select tests.authenticate_as('lab4.agent@test.local');
insert into observed select count(*) from public.tickets where category = 'billing';
reset role;

select results_eq(
  $$ select n from observed $$,
  $$ select n from expected $$,
  'agent sees every billing ticket (policy logic unchanged)'
);
select cmp_ok(
  (select coalesce(sum(calls), 0)::bigint from pg_stat_xact_user_functions
   where schemaname = 'private' and funcname = 'is_agent'),
  '<=', 2::bigint,
  'private.is_agent() runs once per statement, not once per row'
);

select * from finish();
rollback;
