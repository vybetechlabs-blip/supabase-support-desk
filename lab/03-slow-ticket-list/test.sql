-- Scenario 3 regression test: with the lab's 50,000 tickets, the agent list query
-- is served by an index and never scans the whole table.
-- Fails without the index, passes after fix.sql. Needs lab/common/bulk-seed.sql loaded.
begin;
select plan(3);

select ok((select count(*) from public.tickets) >= 50000, 'precondition: at least 50,000 tickets loaded');

-- Text plan lines for a query, planned as the current role (so RLS is included).
create function pg_temp.plan_lines(q text) returns setof text language plpgsql as $$
declare line text;
begin
  for line in execute 'explain ' || q loop
    return next line;
  end loop;
end $$;

select tests.create_user('lab3.agent@test.local', 'agent');
select tests.authenticate_as('lab3.agent@test.local');

select is_empty(
  $$ select l from pg_temp.plan_lines($q$
       select id, subject, status, category, priority, created_at, updated_at
       from public.tickets where status = 'open'
       order by created_at desc limit 50 $q$) l
     where l ~ 'Seq Scan on tickets' $$,
  'agent list query does not sequentially scan tickets'
);
select isnt_empty(
  $$ select l from pg_temp.plan_lines($q$
       select id, subject, status, category, priority, created_at, updated_at
       from public.tickets where status = 'open'
       order by created_at desc limit 50 $q$) l
     where l ~ 'Index Scan using tickets_status_created_at_idx' $$,
  'agent list query reads the (status, created_at desc) index'
);

select * from finish();
rollback;
