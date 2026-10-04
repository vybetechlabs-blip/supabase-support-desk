-- Reproduce: the developer's tickets select policy calls auth.uid() and the role
-- helper directly instead of wrapping them in (select ...). Same logic, same
-- results; only the evaluation strategy differs.
drop policy "tickets: customers read own, agents read all" on public.tickets;

create policy "tickets: customers read own, agents read all"
  on public.tickets for select to authenticated
  using (
    customer_id = auth.uid()
    or private.is_agent()
  );
