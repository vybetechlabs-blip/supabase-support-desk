-- Row Level Security for every public table.
--
-- Role check design
-- -----------------
-- private.is_agent() reads public.profiles. It is SECURITY DEFINER, so the read
-- runs as the function owner and does not re-enter the profiles policies
-- (no recursive policy evaluation). Every policy calls it wrapped in a
-- sub-select, `(select private.is_agent())`, which Postgres plans as an InitPlan:
-- it runs once per statement, not once per row. Same for `(select auth.uid())`.
--
-- Why not a JWT claim set by a custom access token hook? The claim only changes
-- when the token refreshes, so a demoted agent keeps agent access until then.
-- A table lookup cached per statement is current on every query and needs no
-- hook configuration.
--
-- Every table has a policy for select, insert, update and delete. Operations
-- that no client may perform get an explicit `false` policy so the intent is
-- visible in pg_policies and covered by a test.

create function private.is_agent()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'agent'
  );
$$;

-- Used only in single-row write checks (assigning a ticket).
create function private.is_agent_id(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = p_user_id and role = 'agent'
  );
$$;

revoke all on function private.is_agent(), private.is_agent_id(uuid) from public, anon;
grant usage on schema private to authenticated;
grant execute on function private.is_agent(), private.is_agent_id(uuid) to authenticated;

alter table public.profiles enable row level security;
alter table public.tickets  enable row level security;
alter table public.messages enable row level security;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
-- Customers see themselves and agents (to show who replied), never other customers.
create policy "profiles: read own, agents, or all if agent"
  on public.profiles for select to authenticated
  using (
    id = (select auth.uid())
    or role = 'agent'
    or (select private.is_agent())
  );

-- Profiles are created by the sign-up trigger and promoted by an operator.
create policy "profiles: no client inserts"
  on public.profiles for insert to authenticated
  with check (false);

-- Blocks self-promotion to agent.
create policy "profiles: no client updates"
  on public.profiles for update to authenticated
  using (false) with check (false);

create policy "profiles: no client deletes"
  on public.profiles for delete to authenticated
  using (false);

-- ---------------------------------------------------------------------------
-- tickets
-- ---------------------------------------------------------------------------
create policy "tickets: customers read own, agents read all"
  on public.tickets for select to authenticated
  using (
    customer_id = (select auth.uid())
    or (select private.is_agent())
  );

-- A new ticket belongs to the caller and arrives untriaged. Category, priority,
-- assignee and embedding are set only by an agent or by the triage function.
create policy "tickets: create own, untriaged"
  on public.tickets for insert to authenticated
  with check (
    customer_id = (select auth.uid())
    and status = 'open'
    and category is null
    and priority is null
    and assignee_id is null
    and embedding is null
    and resolution is null
    and triaged_at is null
  );

-- Only agents update tickets. Customers cannot change status, category,
-- priority or assignee by calling the API directly. Assignee must be an agent.
create policy "tickets: agents update"
  on public.tickets for update to authenticated
  using ((select private.is_agent()))
  with check (
    (select private.is_agent())
    and (assignee_id is null or private.is_agent_id(assignee_id))
  );

create policy "tickets: no client deletes"
  on public.tickets for delete to authenticated
  using (false);

-- ---------------------------------------------------------------------------
-- messages
-- ---------------------------------------------------------------------------
create policy "messages: customers read own public, agents read all"
  on public.messages for select to authenticated
  using (
    (select private.is_agent())
    or (
      is_internal = false
      and ticket_id in (
        select id from public.tickets where customer_id = (select auth.uid())
      )
    )
  );

create policy "messages: agents post anywhere, customers reply on own tickets"
  on public.messages for insert to authenticated
  with check (
    author_id = (select auth.uid())
    and (
      (select private.is_agent())
      or (
        is_internal = false
        and ticket_id in (
          select id from public.tickets where customer_id = (select auth.uid())
        )
      )
    )
  );

-- Messages are an append-only conversation log.
create policy "messages: no client updates"
  on public.messages for update to authenticated
  using (false) with check (false);

create policy "messages: no client deletes"
  on public.messages for delete to authenticated
  using (false);
