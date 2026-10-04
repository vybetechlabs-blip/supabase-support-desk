-- Timestamps are set by the server on insert from the Data API.
--
-- The insert policies did not constrain created_at / updated_at, so a client could
-- future-date a ticket (pinning it to the top of the agent list, which sorts by
-- created_at) or backdate a reply. For the API roles the trigger overwrites both
-- with now(). The table owner (seed data, the troubleshooting lab, migrations)
-- can still write historical timestamps.
-- Updates are already covered: tickets_touch_updated_at sets updated_at on every
-- update, and messages cannot be updated by clients.

create function private.force_insert_timestamps()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- current_user is the role running the INSERT: anon/authenticated for API requests.
  if current_user in ('anon', 'authenticated') then
    new.created_at := now();
    if tg_table_name = 'tickets' then
      new.updated_at := now();
    end if;
  end if;
  return new;
end;
$$;

create trigger tickets_force_insert_timestamps
  before insert on public.tickets
  for each row execute function private.force_insert_timestamps();

create trigger messages_force_insert_timestamps
  before insert on public.messages
  for each row execute function private.force_insert_timestamps();
