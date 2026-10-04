-- The allowed path for profile creation (the sign-up trigger) and seed sanity.
begin;
select plan(5);

-- A client controls raw_user_meta_data at sign-up. Claiming "agent" there must not work.
insert into auth.users (id, email, raw_user_meta_data, aud, role)
values ('00000000-0000-0000-0000-00000000a001', 'claims.agent@test.local',
        '{"role": "agent", "display_name": "Mallory Test"}', 'authenticated', 'authenticated');

select results_eq(
  $$ select role, display_name from public.profiles where id = '00000000-0000-0000-0000-00000000a001' $$,
  $$ values ('customer'::text, 'Mallory Test'::text) $$,
  'sign-up creates a customer profile and ignores a role claimed in user metadata'
);

insert into auth.users (id, email, aud, role)
values ('00000000-0000-0000-0000-00000000a002', 'noname@test.local', 'authenticated', 'authenticated');
select results_eq(
  $$ select display_name from public.profiles where id = '00000000-0000-0000-0000-00000000a002' $$,
  $$ values ('noname'::text) $$,
  'display name falls back to the email local part'
);

-- Seed loaded (supabase/seed.sql).
select results_eq($$ select count(*) from public.profiles p join auth.users u on u.id = p.id
                     where p.role = 'agent' and u.email like '%@example.com' $$,
  array[3::bigint], 'seed has three agents');
select results_eq($$ select count(*) from public.tickets t join auth.users u on u.id = t.customer_id
                     where u.email like '%@example.com' $$,
  array[40::bigint], 'seed has forty tickets');
select is_empty($$ select t.id from public.tickets t where t.status = 'resolved' and t.resolution is null
                   and t.customer_id in (select id from auth.users where email like '%@example.com') $$,
  'every seeded resolved ticket has a resolution');

select * from finish();
rollback;
