-- public.similar_tickets respects the caller's access rights.
begin;
select plan(9);

select tests.create_user('s.cust.a@test.local');
select tests.create_user('s.cust.b@test.local');
select tests.create_user('s.agent@test.local', 'agent');

-- Unit vector pointing mostly along axis i, tilted toward axis j by weight w.
create function pg_temp.vec(i int, j int, w float8) returns extensions.vector
language sql immutable as $$
  select (
    select array_agg(case when k = i then 1.0 / sqrt(1 + w * w)
                          when k = j then w / sqrt(1 + w * w)
                          else 0 end order by k)
    from generate_series(1, 384) k
  )::extensions.vector(384)
$$;

create temporary table fx (name text primary key, id bigint) on commit drop;
grant select on fx to authenticated, anon;

-- Source: customer A's open ticket along axis 1.
with t as (insert into public.tickets (customer_id, subject, body, embedding)
           values (tests.uid('s.cust.a@test.local'), 'source', 'x', pg_temp.vec(1, 2, 0)) returning id)
insert into fx select 'src', id from t;
-- A's resolved ticket, very close to the source.
with t as (insert into public.tickets (customer_id, subject, body, status, resolution, embedding)
           values (tests.uid('s.cust.a@test.local'), 'A near', 'x', 'resolved', 'fixed A', pg_temp.vec(1, 2, 0.1)) returning id)
insert into fx select 'a_near', id from t;
-- B's resolved ticket, also close (but not as close).
with t as (insert into public.tickets (customer_id, subject, body, status, resolution, embedding)
           values (tests.uid('s.cust.b@test.local'), 'B near', 'x', 'resolved', 'fixed B', pg_temp.vec(1, 2, 0.5)) returning id)
insert into fx select 'b_near', id from t;
-- B's resolved ticket, unrelated (orthogonal).
with t as (insert into public.tickets (customer_id, subject, body, status, resolution, embedding)
           values (tests.uid('s.cust.b@test.local'), 'B far', 'x', 'resolved', 'fixed far', pg_temp.vec(3, 4, 0)) returning id)
insert into fx select 'b_far', id from t;
-- B's OPEN ticket identical to the source: must never be suggested (not resolved).
with t as (insert into public.tickets (customer_id, subject, body, embedding)
           values (tests.uid('s.cust.b@test.local'), 'B open twin', 'x', pg_temp.vec(1, 2, 0)) returning id)
insert into fx select 'b_open', id from t;
-- B's ticket used as a source by customer A (whom it does not belong to).
with t as (insert into public.tickets (customer_id, subject, body, embedding)
           values (tests.uid('s.cust.b@test.local'), 'B source', 'x', pg_temp.vec(1, 2, 0)) returning id)
insert into fx select 'b_src', id from t;

-- Only fixture rows carry these vectors, but seed rows could gain embeddings later,
-- so every assertion is restricted to fixture ids.
select tests.authenticate_as('s.agent@test.local');
select results_eq(
  $$ select s.id from public.similar_tickets((select id from fx where name = 'src'), 10) s
     where s.id in (select id from fx) $$,
  $$ select id from fx where name in ('a_near', 'b_near', 'b_far') order by array_position(array['a_near','b_near','b_far'], name) $$,
  'agent gets every resolved match, most similar first'
);
select ok(
  (select s.similarity from public.similar_tickets((select id from fx where name = 'src'), 10) s
   where s.id = (select id from fx where name = 'a_near')) > 0.99,
  'similarity is cosine similarity (near-identical vectors score above 0.99)'
);
select is_empty(
  $$ select s.id from public.similar_tickets((select id from fx where name = 'src'), 10) s
     where s.id in (select id from fx where name in ('src', 'b_open')) $$,
  'results exclude the source ticket and tickets that are not resolved'
);
select results_eq(
  $$ select resolution from public.similar_tickets((select id from fx where name = 'src'), 1) $$,
  $$ values ('fixed A'::text) $$,
  'match_count limits the result and each row carries its resolution'
);

select tests.authenticate_as('s.cust.a@test.local');
select results_eq(
  $$ select s.id from public.similar_tickets((select id from fx where name = 'src'), 10) s $$,
  $$ select id from fx where name = 'a_near' $$,
  'customer gets only their own resolved tickets (RLS applies inside the function)'
);
select is_empty(
  $$ select * from public.similar_tickets((select id from fx where name = 'b_src'), 10) $$,
  'customer asking about another customer''s ticket gets nothing'
);

select tests.as_anon();
select throws_ok(
  $$ select * from public.similar_tickets(1, 5) $$,
  '42501', null,
  'signed-out visitor cannot call similar_tickets'
);

reset role;
select is(
  (select prosecdef from pg_proc where oid = 'public.similar_tickets(bigint, int)'::regprocedure),
  false,
  'similar_tickets is security invoker'
);
select is(
  (select has_function_privilege('anon', 'public.similar_tickets(bigint, int)', 'execute')),
  false,
  'anon has no execute privilege on similar_tickets'
);

select * from finish();
rollback;
