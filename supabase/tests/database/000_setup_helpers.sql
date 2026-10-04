-- Test helpers. This file runs first (files run in name order) and is the only
-- one that commits: it installs pgTAP and a `tests` schema into the LOCAL
-- database. Nothing here is part of the migrations; `supabase db reset` wipes it.
--
-- The helpers do what the Supabase docs describe for RLS tests: switch to the
-- `authenticated` role and set `request.jwt.claims`, which auth.uid() reads.

create extension if not exists pgtap with schema extensions;

drop schema if exists tests cascade;
create schema tests;
grant usage on schema tests to anon, authenticated;

-- Creates an auth user (the sign-up trigger creates the profile) and returns its id.
create function tests.create_user(p_email text, p_role text default 'customer', p_name text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, raw_user_meta_data, aud, role)
  values (v_id, p_email, jsonb_build_object('display_name', coalesce(p_name, p_email)), 'authenticated', 'authenticated');
  if p_role = 'agent' then
    update public.profiles set role = 'agent' where id = v_id;
  end if;
  return v_id;
end;
$$;

create function tests.uid(p_email text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$ select id from auth.users where email = p_email $$;

-- Act as a signed-in user for the rest of the transaction.
create function tests.authenticate_as(p_email text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid := tests.uid(p_email);
begin
  if v_id is null then
    raise exception 'tests.authenticate_as: no user %', p_email;
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email)::text, true);
  perform set_config('role', 'authenticated', true);
end;
$$;

-- Act as a signed-out visitor (publishable key, no session).
create function tests.as_anon()
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('role', 'anon', true);
end;
$$;

grant execute on all functions in schema tests to anon, authenticated;

select plan(1);
select has_schema('tests', 'test helpers installed');
select * from finish();
