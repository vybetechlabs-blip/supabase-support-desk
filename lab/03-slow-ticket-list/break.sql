-- Reproduce: the developer's project never had an index that matches the agent
-- list query (filter by status, newest first). The core migration creates it;
-- the lab removes it to match their database.
drop index if exists public.tickets_status_created_at_idx;
analyze public.tickets;
