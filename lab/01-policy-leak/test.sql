-- Scenario 1 regression test: a customer can never read an internal note.
-- Fails while the leaky policy is in place, passes after fix.sql.
begin;
select plan(3);

select tests.create_user('lab1.customer@test.local');
select tests.create_user('lab1.agent@test.local', 'agent');

create temporary table fx (name text primary key, id bigint) on commit drop;
grant select on fx to authenticated;
with t as (insert into public.tickets (customer_id, subject, body)
           values (tests.uid('lab1.customer@test.local'), 'Leak test', 'x') returning id)
insert into fx select 'ticket', id from t;
insert into public.messages (ticket_id, author_id, body, is_internal) values
  ((select id from fx where name = 'ticket'), tests.uid('lab1.agent@test.local'), 'public reply', false),
  ((select id from fx where name = 'ticket'), tests.uid('lab1.agent@test.local'), 'internal note', true);

select tests.authenticate_as('lab1.customer@test.local');
select is_empty(
  $$ select id from public.messages where is_internal $$,
  'customer reads no internal notes at all'
);
select results_eq(
  $$ select body from public.messages where ticket_id = (select id from fx where name = 'ticket') $$,
  $$ values ('public reply'::text) $$,
  'customer reads only the public reply on their own ticket'
);

select tests.authenticate_as('lab1.agent@test.local');
select results_eq(
  $$ select count(*) from public.messages where ticket_id = (select id from fx where name = 'ticket') $$,
  array[2::bigint],
  'agent still reads both messages'
);

select * from finish();
rollback;
