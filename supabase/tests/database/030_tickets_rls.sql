begin;
select plan(27);

select tests.create_user('t.cust.a@test.local');
select tests.create_user('t.cust.b@test.local');
select tests.create_user('t.agent@test.local', 'agent');
select tests.create_user('t.agent2@test.local', 'agent');

-- Fixture tickets, created as the table owner (bypasses RLS).
create temporary table fx (name text primary key, id bigint) on commit drop;
grant select on fx to authenticated, anon;
with a as (
  insert into public.tickets (customer_id, subject, body)
  values (tests.uid('t.cust.a@test.local'), 'A ticket', 'body a') returning id
) insert into fx select 'a', id from a;
with b as (
  insert into public.tickets (customer_id, subject, body)
  values (tests.uid('t.cust.b@test.local'), 'B ticket', 'body b') returning id
) insert into fx select 'b', id from b;

-- select ---------------------------------------------------------------------
select tests.authenticate_as('t.cust.a@test.local');
select isnt_empty($$ select id from public.tickets where id = (select id from fx where name = 'a') $$,
  'customer sees their own ticket');
select is_empty($$ select id from public.tickets where id = (select id from fx where name = 'b') $$,
  'customer cannot see another customer''s ticket');

select tests.authenticate_as('t.agent@test.local');
select results_eq($$ select count(*) from public.tickets where id in (select id from fx) $$,
  array[2::bigint], 'agent sees every customer''s tickets');

select tests.as_anon();
select is_empty($$ select id from public.tickets $$, 'signed-out visitor sees no tickets');

-- insert ---------------------------------------------------------------------
select tests.authenticate_as('t.cust.a@test.local');
select lives_ok($$ insert into public.tickets (subject, body) values ('New one', 'help please') $$,
  'customer creates a ticket (customer_id defaults to the caller)');
select throws_ok(
  format($$ insert into public.tickets (customer_id, subject, body) values (%L, 's', 'b') $$, tests.uid('t.cust.b@test.local')),
  '42501', 'new row violates row-level security policy for table "tickets"',
  'customer cannot create a ticket for someone else');
select throws_ok($$ insert into public.tickets (subject, body, category) values ('s', 'b', 'billing') $$,
  '42501', 'new row violates row-level security policy for table "tickets"',
  'customer cannot set category on create');
select throws_ok($$ insert into public.tickets (subject, body, priority) values ('s', 'b', 'urgent') $$,
  '42501', 'new row violates row-level security policy for table "tickets"',
  'customer cannot set priority on create');
select throws_ok($$ insert into public.tickets (subject, body, status) values ('s', 'b', 'resolved') $$,
  '42501', 'new row violates row-level security policy for table "tickets"',
  'customer cannot set status on create');
select throws_ok(
  format($$ insert into public.tickets (subject, body, assignee_id) values ('s', 'b', %L) $$, tests.uid('t.agent@test.local')),
  '42501', 'new row violates row-level security policy for table "tickets"',
  'customer cannot set assignee on create');

select throws_ok(
  format($$ insert into public.tickets (subject, body, embedding) values ('s', 'b', %L) $$,
         '[' || array_to_string(array_fill(0.1::float8, array[384]), ',') || ']'),
  '42501', 'new row violates row-level security policy for table "tickets"',
  'customer cannot set an embedding on create');
select throws_ok($$ insert into public.tickets (subject, body, resolution) values ('s', 'b', 'fixed it myself') $$,
  '42501', 'new row violates row-level security policy for table "tickets"',
  'customer cannot set a resolution on create');
select throws_ok($$ insert into public.tickets (subject, body, triaged_at) values ('s', 'b', now()) $$,
  '42501', 'new row violates row-level security policy for table "tickets"',
  'customer cannot set triaged_at on create (it gates customer-triggered triage)');

select tests.as_anon();
select throws_ok($$ insert into public.tickets (subject, body) values ('s', 'b') $$,
  '42501', null,
  'signed-out visitor cannot create a ticket');

-- update ---------------------------------------------------------------------
-- RLS hides rows from an UPDATE the caller may not perform: no error, zero rows.
select tests.authenticate_as('t.cust.a@test.local');
select is_empty($$ update public.tickets set status = 'resolved' where id = (select id from fx where name = 'a') returning id $$,
  'customer cannot change status on their own ticket');
select is_empty($$ update public.tickets set category = 'billing' where id = (select id from fx where name = 'a') returning id $$,
  'customer cannot change category on their own ticket');
select is_empty($$ update public.tickets set priority = 'urgent' where id = (select id from fx where name = 'a') returning id $$,
  'customer cannot change priority on their own ticket');
select is_empty(
  format($$ update public.tickets set assignee_id = %L where id = (select id from fx where name = 'a') returning id $$, tests.uid('t.agent@test.local')),
  'customer cannot change assignee on their own ticket');

reset role;
select results_eq(
  $$ select status, category, priority, assignee_id from public.tickets where id = (select id from fx where name = 'a') $$,
  $$ values ('open'::text, null::text, null::text, null::uuid) $$,
  'customer''s ticket is unchanged after the denied updates');

select tests.authenticate_as('t.agent@test.local');
select results_eq(
  format($$ update public.tickets set status = 'pending', category = 'bug', priority = 'high', assignee_id = %L
            where id = (select id from fx where name = 'a') returning status, category, priority $$,
         tests.uid('t.agent@test.local')),
  $$ values ('pending'::text, 'bug'::text, 'high'::text) $$,
  'agent assigns the ticket to themselves and changes status, category and priority');
select throws_ok(
  format($$ update public.tickets set assignee_id = %L where id = (select id from fx where name = 'a') $$, tests.uid('t.cust.b@test.local')),
  '42501', 'new row violates row-level security policy for table "tickets"',
  'agent cannot assign a ticket to a customer');
select lives_ok(
  format($$ update public.tickets set assignee_id = %L where id = (select id from fx where name = 'a') $$, tests.uid('t.agent2@test.local')),
  'agent can hand a ticket to another agent');

select tests.as_anon();
select is_empty($$ update public.tickets set status = 'resolved' returning id $$,
  'signed-out visitor cannot update tickets');

-- delete ---------------------------------------------------------------------
select tests.authenticate_as('t.cust.a@test.local');
select is_empty($$ delete from public.tickets where id = (select id from fx where name = 'a') returning id $$,
  'customer cannot delete their ticket');
select tests.authenticate_as('t.agent@test.local');
select is_empty($$ delete from public.tickets where id = (select id from fx where name = 'b') returning id $$,
  'agent cannot delete a ticket');
select tests.as_anon();
select is_empty($$ delete from public.tickets returning id $$,
  'signed-out visitor cannot delete tickets');

reset role;
select results_eq($$ select count(*) from public.tickets where id in (select id from fx) $$,
  array[2::bigint], 'both fixture tickets still exist after the denied deletes');

select * from finish();
rollback;
