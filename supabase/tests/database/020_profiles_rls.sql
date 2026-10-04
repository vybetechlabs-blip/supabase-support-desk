begin;
select plan(13);

select tests.create_user('p.cust.a@test.local');
select tests.create_user('p.cust.b@test.local');
select tests.create_user('p.agent@test.local', 'agent');

-- select ---------------------------------------------------------------------
select tests.authenticate_as('p.cust.a@test.local');
select results_eq(
  format($$ select count(*) from public.profiles where id in (%L, %L, %L) $$,
         tests.uid('p.cust.a@test.local'), tests.uid('p.cust.b@test.local'), tests.uid('p.agent@test.local')),
  array[2::bigint],
  'customer sees own profile and the agent profile'
);
select is_empty(
  format($$ select id from public.profiles where id = %L $$, tests.uid('p.cust.b@test.local')),
  'customer cannot see another customer''s profile'
);

select tests.authenticate_as('p.agent@test.local');
select results_eq(
  format($$ select count(*) from public.profiles where id in (%L, %L, %L) $$,
         tests.uid('p.cust.a@test.local'), tests.uid('p.cust.b@test.local'), tests.uid('p.agent@test.local')),
  array[3::bigint],
  'agent sees every profile'
);

select tests.as_anon();
select is_empty($$ select id from public.profiles $$, 'signed-out visitor sees no profiles');

-- insert ---------------------------------------------------------------------
select tests.authenticate_as('p.cust.a@test.local');
select throws_ok(
  format($$ insert into public.profiles (id, role, display_name) values (%L, 'agent', 'x') $$, gen_random_uuid()),
  '42501', 'new row violates row-level security policy for table "profiles"',
  'customer cannot insert a profile'
);
select tests.authenticate_as('p.agent@test.local');
select throws_ok(
  format($$ insert into public.profiles (id, role, display_name) values (%L, 'customer', 'x') $$, gen_random_uuid()),
  '42501', 'new row violates row-level security policy for table "profiles"',
  'agent cannot insert a profile'
);

-- update ---------------------------------------------------------------------
select tests.authenticate_as('p.cust.a@test.local');
select is_empty(
  format($$ update public.profiles set role = 'agent' where id = %L returning id $$, tests.uid('p.cust.a@test.local')),
  'customer cannot promote themselves to agent'
);
select is_empty(
  format($$ update public.profiles set display_name = 'renamed' where id = %L returning id $$, tests.uid('p.cust.a@test.local')),
  'customer cannot edit their profile through the API'
);
select tests.authenticate_as('p.agent@test.local');
select is_empty(
  format($$ update public.profiles set role = 'agent' where id = %L returning id $$, tests.uid('p.cust.b@test.local')),
  'agent cannot change another user''s role'
);

reset role;
select results_eq(
  format($$ select role, display_name from public.profiles where id = %L $$, tests.uid('p.cust.a@test.local')),
  $$ values ('customer'::text, 'p.cust.a@test.local'::text) $$,
  'customer profile is unchanged after the denied updates'
);

-- delete ---------------------------------------------------------------------
select tests.authenticate_as('p.cust.a@test.local');
select is_empty(
  format($$ delete from public.profiles where id = %L returning id $$, tests.uid('p.cust.a@test.local')),
  'customer cannot delete their profile'
);
select tests.authenticate_as('p.agent@test.local');
select is_empty(
  format($$ delete from public.profiles where id = %L returning id $$, tests.uid('p.cust.b@test.local')),
  'agent cannot delete a profile'
);

reset role;
select results_eq(
  format($$ select count(*) from public.profiles where id in (%L, %L) $$,
         tests.uid('p.cust.a@test.local'), tests.uid('p.cust.b@test.local')),
  array[2::bigint],
  'both profiles still exist after the denied deletes'
);

select * from finish();
rollback;
