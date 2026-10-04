-- Fix (ship as a migration): the customer branch checks ticket OWNERSHIP
-- (customer_id), not assignment. Agents keep posting anywhere; customers still
-- cannot post internal notes or reply on someone else's ticket.
drop policy if exists "messages: reply on tickets you work on" on public.messages;

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
