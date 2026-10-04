-- Scenario 2 regression test: customers can reply on their own tickets, and the
-- fix did not open anything else up. Fails while the broken policy is in place.
begin;
select plan(4);

select tests.create_user('lab2.customer@test.local');
select tests.create_user('lab2.other@test.local');
select tests.create_user('lab2.agent@test.local', 'agent');

create temporary table fx (name text primary key, id bigint) on commit drop;
grant select on fx to authenticated;
with t as (insert into public.tickets (customer_id, subject, body)
           values (tests.uid('lab2.customer@test.local'), 'Own ticket', 'x') returning id)
insert into fx select 'own', id from t;
with t as (insert into public.tickets (customer_id, subject, body)
           values (tests.uid('lab2.other@test.local'), 'Other ticket', 'x') returning id)
insert into fx select 'other', id from t;

select tests.authenticate_as('lab2.customer@test.local');
select lives_ok(
  $$ insert into public.messages (ticket_id, body) values ((select id from fx where name = 'own'), 'customer reply') $$,
  'customer can reply on their own (unassigned) ticket'
);
select throws_ok(
  $$ insert into public.messages (ticket_id, body) values ((select id from fx where name = 'other'), 'nosy') $$,
  '42501', null,
  'customer still cannot reply on another customer''s ticket'
);
select throws_ok(
  $$ insert into public.messages (ticket_id, body, is_internal) values ((select id from fx where name = 'own'), 'sneaky', true) $$,
  '42501', null,
  'customer still cannot post an internal note'
);

select tests.authenticate_as('lab2.agent@test.local');
select lives_ok(
  $$ insert into public.messages (ticket_id, body, is_internal) values ((select id from fx where name = 'other'), 'agent note', true) $$,
  'agent still posts on any ticket'
);

select * from finish();
rollback;
