-- Fix (ship as a migration): wrap both function calls in a sub-select. Postgres
-- then plans each as an InitPlan, evaluated once per statement, and the result is
-- reused for every row. private.is_agent() is SECURITY DEFINER, so it cannot be
-- inlined; without the wrapper it runs (and queries profiles) once per row.
drop policy "tickets: customers read own, agents read all" on public.tickets;

create policy "tickets: customers read own, agents read all"
  on public.tickets for select to authenticated
  using (
    customer_id = (select auth.uid())
    or (select private.is_agent())
  );
