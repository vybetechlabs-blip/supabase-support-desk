-- Reproduce: the project as the developer described it in their ticket.
-- They "simplified" the messages select policy to "participants of a ticket can
-- read its messages" and dropped the is_internal condition.
drop policy "messages: customers read own public, agents read all" on public.messages;

create policy "messages: ticket participants read"
  on public.messages for select to authenticated
  using (
    (select private.is_agent())
    or ticket_id in (
      select id from public.tickets where customer_id = (select auth.uid())
    )
  );
