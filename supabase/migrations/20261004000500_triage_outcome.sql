-- Record what the classifier did on the ticket itself.
--
-- triaged_at only says triage ran; it stays the once-per-ticket gate that stops
-- customers re-triggering model calls, and it is set whatever the outcome.
-- triage_outcome says what happened, so an agent can tell a failed or skipped
-- classification from a ticket that simply has no category yet:
--   classified  the model returned a category and priority
--   no_key      no ANTHROPIC_API_KEY configured, so no model call was made
--   failed      the model call failed (API error, network error, refusal, bad output)

alter table public.tickets
  add column triage_outcome text
  check (triage_outcome in ('classified', 'no_key', 'failed'));

-- Customers create tickets untriaged; that now includes the outcome.
drop policy "tickets: create own, untriaged" on public.tickets;

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
    and triage_outcome is null
  );
