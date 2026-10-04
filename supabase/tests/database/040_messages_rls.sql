begin;
select plan(19);

select tests.create_user('m.cust.a@test.local');
select tests.create_user('m.cust.b@test.local');
select tests.create_user('m.agent@test.local', 'agent');

create temporary table fx (name text primary key, id bigint) on commit drop;
grant select on fx to authenticated, anon;

with t as (
  insert into public.tickets (customer_id, subject, body)
  values (tests.uid('m.cust.a@test.local'), 'A ticket', 'body a') returning id
) insert into fx select 'ticket_a', id from t;
with t as (
  insert into public.tickets (customer_id, subject, body)
  values (tests.uid('m.cust.b@test.local'), 'B ticket', 'body b') returning id
) insert into fx select 'ticket_b', id from t;

with m as (
  insert into public.messages (ticket_id, author_id, body, is_internal)
  values ((select id from fx where name = 'ticket_a'), tests.uid('m.agent@test.local'), 'public reply on A', false) returning id
) insert into fx select 'a_public', id from m;
with m as (
  insert into public.messages (ticket_id, author_id, body, is_internal)
  values ((select id from fx where name = 'ticket_a'), tests.uid('m.agent@test.local'), 'internal note on A', true) returning id
) insert into fx select 'a_internal', id from m;
with m as (
  insert into public.messages (ticket_id, author_id, body, is_internal)
  values ((select id from fx where name = 'ticket_b'), tests.uid('m.agent@test.local'), 'public reply on B', false) returning id
) insert into fx select 'b_public', id from m;

-- select ---------------------------------------------------------------------
select tests.authenticate_as('m.cust.a@test.local');
select isnt_empty($$ select id from public.messages where id = (select id from fx where name = 'a_public') $$,
  'customer sees public replies on their own ticket');
select is_empty($$ select id from public.messages where id = (select id from fx where name = 'a_internal') $$,
  'customer never sees internal notes, even on their own ticket');
select is_empty($$ select id from public.messages where id = (select id from fx where name = 'b_public') $$,
  'customer cannot see messages on another customer''s ticket');

select tests.authenticate_as('m.agent@test.local');
select results_eq($$ select count(*) from public.messages where id in (select id from fx where name like 'a_%' or name like 'b_%') $$,
  array[3::bigint], 'agent sees every message, including internal notes');

select tests.as_anon();
select is_empty($$ select id from public.messages $$, 'signed-out visitor sees no messages');

-- insert ---------------------------------------------------------------------
select tests.authenticate_as('m.cust.a@test.local');
select lives_ok($$ insert into public.messages (ticket_id, body) values ((select id from fx where name = 'ticket_a'), 'customer reply') $$,
  'customer replies on their own ticket');
select throws_ok($$ insert into public.messages (ticket_id, body) values ((select id from fx where name = 'ticket_b'), 'nosy') $$,
  '42501', 'new row violates row-level security policy for table "messages"',
  'customer cannot reply on another customer''s ticket');
select throws_ok($$ insert into public.messages (ticket_id, body, is_internal) values ((select id from fx where name = 'ticket_a'), 'sneaky', true) $$,
  '42501', 'new row violates row-level security policy for table "messages"',
  'customer cannot post an internal note');
select throws_ok(
  format($$ insert into public.messages (ticket_id, author_id, body) values ((select id from fx where name = 'ticket_a'), %L, 'spoofed') $$, tests.uid('m.agent@test.local')),
  '42501', 'new row violates row-level security policy for table "messages"',
  'customer cannot post as someone else');

select tests.authenticate_as('m.agent@test.local');
select lives_ok($$ insert into public.messages (ticket_id, body, is_internal) values ((select id from fx where name = 'ticket_b'), 'agent note', true) $$,
  'agent adds an internal note on any ticket');
select lives_ok($$ insert into public.messages (ticket_id, body) values ((select id from fx where name = 'ticket_b'), 'agent reply') $$,
  'agent replies on any ticket');
select throws_ok(
  format($$ insert into public.messages (ticket_id, author_id, body) values ((select id from fx where name = 'ticket_a'), %L, 'spoofed') $$, tests.uid('m.cust.a@test.local')),
  '42501', 'new row violates row-level security policy for table "messages"',
  'agent cannot post as a customer');

select tests.as_anon();
select throws_ok($$ insert into public.messages (ticket_id, body) values ((select id from fx where name = 'ticket_a'), 'anon') $$,
  '42501', null, 'signed-out visitor cannot post a message');

-- update ---------------------------------------------------------------------
select tests.authenticate_as('m.cust.a@test.local');
select is_empty($$ update public.messages set body = 'edited' where ticket_id = (select id from fx where name = 'ticket_a') returning id $$,
  'customer cannot edit messages');
select tests.authenticate_as('m.agent@test.local');
select is_empty($$ update public.messages set is_internal = false where id = (select id from fx where name = 'a_internal') returning id $$,
  'agent cannot edit messages (cannot expose an internal note by flipping the flag)');

-- delete ---------------------------------------------------------------------
select tests.authenticate_as('m.cust.a@test.local');
select is_empty($$ delete from public.messages where ticket_id = (select id from fx where name = 'ticket_a') returning id $$,
  'customer cannot delete messages');
select tests.authenticate_as('m.agent@test.local');
select is_empty($$ delete from public.messages where id = (select id from fx where name = 'a_internal') returning id $$,
  'agent cannot delete messages');

reset role;
select results_eq(
  $$ select body, is_internal from public.messages where id = (select id from fx where name = 'a_internal') $$,
  $$ values ('internal note on A'::text, true) $$,
  'internal note is unchanged after the denied update and delete');
select results_eq($$ select count(*) from public.messages where id in (select id from fx where name in ('a_public', 'a_internal', 'b_public')) $$,
  array[3::bigint], 'fixture messages still exist');

select * from finish();
rollback;
