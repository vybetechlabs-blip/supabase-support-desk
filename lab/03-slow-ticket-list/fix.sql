-- Fix (ship as a migration): a composite index whose column order matches the
-- query: equality filter first (status), then the sort key in the sort direction
-- (created_at desc). Postgres can then read the newest 50 rows for one status
-- straight from the index and stop, with no sort.
--
-- On a large production table, build it without blocking writes:
--   create index concurrently ... (run it outside a transaction block, so not
--   inside a migration that the tooling wraps in a transaction).
create index if not exists tickets_status_created_at_idx
  on public.tickets (status, created_at desc);
analyze public.tickets;
