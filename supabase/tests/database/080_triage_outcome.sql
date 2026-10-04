-- tickets.triage_outcome records what the classifier did, separately from
-- triaged_at (which stays the once-per-ticket gate for customer-triggered runs).
begin;
select plan(4);

select has_column('public', 'tickets', 'triage_outcome', 'tickets has a triage_outcome column');
select col_is_null('public', 'tickets', 'triage_outcome', 'triage_outcome is empty until triage runs');

select tests.create_user('to.cust@test.local');
select tests.authenticate_as('to.cust@test.local');
select throws_ok(
  $$ insert into public.tickets (subject, body, triage_outcome) values ('s', 'b', 'classified') $$,
  '42501', 'new row violates row-level security policy for table "tickets"',
  'customer cannot set triage_outcome on create'
);

reset role;
select throws_ok(
  $$ insert into public.tickets (customer_id, subject, body, triage_outcome)
     values (tests.uid('to.cust@test.local'), 's', 'b', 'guessed') $$,
  '23514', null,
  'triage_outcome only accepts the known outcomes'
);

select * from finish();
rollback;
