-- Fix (ship as a migration): customers read only public replies on their own
-- tickets; agents read everything. The is_internal check sits next to the
-- ownership check, inside the customer branch.
drop policy if exists "messages: ticket participants read" on public.messages;

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
