-- Triage no longer calls the model when category and priority are both already
-- set (by an agent or the seed); it still stores the embedding. Record that
-- outcome as 'skipped'.
alter table public.tickets drop constraint tickets_triage_outcome_check;
alter table public.tickets
  add constraint tickets_triage_outcome_check
  check (triage_outcome in ('classified', 'no_key', 'failed', 'skipped'));
