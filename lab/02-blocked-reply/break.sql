-- Reproduce: the developer rebuilt the messages insert policy while adding ticket
-- assignment and reused the "tickets you work on" condition for everyone.
-- Agents can still post. Customers can no longer reply on their own tickets.
drop policy "messages: agents post anywhere, customers reply on own tickets" on public.messages;

create policy "messages: reply on tickets you work on"
  on public.messages for insert to authenticated
  with check (
    author_id = (select auth.uid())
    and (
      (select private.is_agent())
      or (
        is_internal = false
        and ticket_id in (
          select id from public.tickets where assignee_id = (select auth.uid())
        )
      )
    )
  );
