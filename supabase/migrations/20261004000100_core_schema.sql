-- Core schema: profiles, tickets, messages.
-- RLS policies live in the next migration so the access model can be read on its own.

create extension if not exists vector with schema extensions;

-- Helper functions live in a schema that the Data API does not expose.
create schema if not exists private;

-- ---------------------------------------------------------------------------
-- profiles: one row per auth user
-- ---------------------------------------------------------------------------
create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  role         text not null default 'customer' check (role in ('customer', 'agent')),
  display_name text not null check (char_length(display_name) between 1 and 100),
  created_at   timestamptz not null default now()
);

comment on column public.profiles.role is
  'customer or agent. Never set from user-supplied metadata; agents are promoted by an operator.';

-- New sign-ups always become customers. The role is NOT read from raw_user_meta_data,
-- because the client controls that field at sign-up.
create function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, role, display_name)
  values (
    new.id,
    'customer',
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), split_part(new.email, '@', 1), 'user')
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- ---------------------------------------------------------------------------
-- tickets
-- ---------------------------------------------------------------------------
create table public.tickets (
  id           bigint generated always as identity primary key,
  customer_id  uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  subject      text not null check (char_length(subject) between 1 and 200),
  body         text not null check (char_length(body) between 1 and 10000),
  status       text not null default 'open' check (status in ('open', 'pending', 'resolved')),
  category     text check (category in ('account', 'billing', 'bug', 'performance', 'integration', 'how_to', 'other')),
  priority     text check (priority in ('low', 'normal', 'high', 'urgent')),
  assignee_id  uuid references public.profiles (id) on delete set null,
  -- gte-small (Supabase.ai built-in) returns 384 dimensions.
  embedding    extensions.vector(384),
  -- Short summary an agent writes when resolving; shown in similar-ticket suggestions.
  resolution   text check (char_length(resolution) <= 2000),
  triaged_at   timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index tickets_customer_id_idx on public.tickets (customer_id);
create index tickets_assignee_id_idx on public.tickets (assignee_id);
-- Agent ticket list: filter by status, newest first.
create index tickets_status_created_at_idx on public.tickets (status, created_at desc);

create function private.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger tickets_touch_updated_at
  before update on public.tickets
  for each row execute function private.touch_updated_at();

-- ---------------------------------------------------------------------------
-- messages: replies and internal notes
-- ---------------------------------------------------------------------------
create table public.messages (
  id          bigint generated always as identity primary key,
  ticket_id   bigint not null references public.tickets (id) on delete cascade,
  author_id   uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 10000),
  is_internal boolean not null default false,
  created_at  timestamptz not null default now()
);

create index messages_ticket_id_created_at_idx on public.messages (ticket_id, created_at);
create index messages_author_id_idx on public.messages (author_id);

-- ---------------------------------------------------------------------------
-- Live updates: Postgres Changes. Realtime checks each event against the
-- subscriber's RLS policies, so customers never receive internal notes.
-- ---------------------------------------------------------------------------
alter publication supabase_realtime add table public.tickets, public.messages;
