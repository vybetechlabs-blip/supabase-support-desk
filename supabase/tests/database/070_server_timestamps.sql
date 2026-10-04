-- Clients cannot choose created_at / updated_at on insert. A customer could
-- otherwise future-date a ticket to pin it to the top of the agent list, or
-- backdate a reply. The server sets both to the transaction time (now()).
begin;
select plan(6);

select tests.create_user('ts.cust@test.local');
select tests.create_user('ts.agent@test.local', 'agent');

create temporary table fx (name text primary key, id bigint) on commit drop;
grant select, insert on fx to authenticated;

select tests.authenticate_as('ts.cust@test.local');
with t as (
  insert into public.tickets (subject, body, created_at, updated_at)
  values ('Pinned?', 'future-dated', '2099-01-01', '2099-01-01') returning id
) insert into fx select 'ticket', id from t;
with m as (
  insert into public.messages (ticket_id, body, created_at)
  values ((select id from fx where name = 'ticket'), 'backdated reply', '2000-01-01') returning id
) insert into fx select 'cust_msg', id from m;

select tests.authenticate_as('ts.agent@test.local');
with m as (
  insert into public.messages (ticket_id, body, is_internal, created_at)
  values ((select id from fx where name = 'ticket'), 'backdated note', true, '2000-01-01') returning id
) insert into fx select 'agent_msg', id from m;

reset role;
select is((select created_at from public.tickets where id = (select id from fx where name = 'ticket')), now(),
  'customer cannot future-date a ticket''s created_at');
select is((select updated_at from public.tickets where id = (select id from fx where name = 'ticket')), now(),
  'customer cannot set a ticket''s updated_at');
select is((select created_at from public.messages where id = (select id from fx where name = 'cust_msg')), now(),
  'customer cannot backdate a reply');
select is((select created_at from public.messages where id = (select id from fx where name = 'agent_msg')), now(),
  'agent cannot backdate a message either');

-- The table owner (seed, lab data, migrations) can still write historical timestamps.
insert into public.tickets (customer_id, subject, body, created_at, updated_at)
values (tests.uid('ts.cust@test.local'), 'Seeded', 'historic', '2020-05-01', '2020-05-01');
select is((select created_at from public.tickets where subject = 'Seeded' and customer_id = tests.uid('ts.cust@test.local')),
  '2020-05-01'::timestamptz, 'owner inserts keep an explicit created_at (seed data)');
select is((select updated_at from public.tickets where subject = 'Seeded' and customer_id = tests.uid('ts.cust@test.local')),
  '2020-05-01'::timestamptz, 'owner inserts keep an explicit updated_at (seed data)');

select * from finish();
rollback;
