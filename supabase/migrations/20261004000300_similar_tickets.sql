-- Similar resolved tickets for the agent view.
--
-- SECURITY INVOKER (the default, stated explicitly): the function runs as the
-- caller, so the tickets policies apply to both the source ticket and every
-- candidate. A customer only ever gets their own resolved tickets back; asking
-- about someone else's ticket returns nothing.
--
-- Embeddings come from gte-small with normalize: true, so inner product equals
-- cosine similarity. `<#>` returns the NEGATIVE inner product (the docs call it
-- the fastest operator for normalized vectors), hence the minus sign.
-- No vector index yet: at this data size an exact scan is fast and fully correct
-- with the status filter and RLS. Scale notes: README.md, "Limitations".

create function public.similar_tickets(p_ticket_id bigint, p_match_count int default 5)
returns table (id bigint, subject text, category text, resolution text, similarity double precision)
language sql
stable
security invoker
set search_path = ''
as $$
  select t.id, t.subject, t.category, t.resolution,
         -(t.embedding operator(extensions.<#>) src.embedding) as similarity
  from public.tickets t
  cross join (
    select embedding from public.tickets where id = p_ticket_id and embedding is not null
  ) src
  where t.status = 'resolved'
    and t.id <> p_ticket_id
    and t.embedding is not null
  order by t.embedding operator(extensions.<#>) src.embedding
  limit least(greatest(p_match_count, 1), 20);
$$;

revoke execute on function public.similar_tickets(bigint, int) from public, anon;
grant execute on function public.similar_tickets(bigint, int) to authenticated;
