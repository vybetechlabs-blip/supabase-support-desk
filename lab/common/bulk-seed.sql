-- Lab data for scenarios 3 and 4: 1,000 extra synthetic customers and 50,000 tickets
-- spread over two years. Deterministic (setseed) so plans are comparable between runs.
-- Every name and address is generated; emails use example.com.
select setseed(0.42);

insert into auth.users (id, email, aud, role, raw_user_meta_data, created_at, updated_at)
select gen_random_uuid(),
       format('lab.customer.%s@example.com', lpad(g::text, 4, '0')),
       'authenticated', 'authenticated',
       jsonb_build_object('display_name', format('Lab Customer %s', g)),
       now(), now()
from generate_series(1, 1000) g;

create temporary table lab_customers as
select row_number() over (order by p.id) as n, p.id
from public.profiles p join auth.users u on u.id = p.id
where u.email like 'lab.customer.%';

-- Status mix of a desk that has been running a while: most tickets resolved.
insert into public.tickets (customer_id, subject, body, status, category, priority, created_at, updated_at)
select c.id,
       format('Lab ticket %s', g),
       'Synthetic ticket body generated for the troubleshooting lab.',
       case when r < 0.06 then 'open' when r < 0.12 then 'pending' else 'resolved' end,
       (array['account', 'billing', 'bug', 'performance', 'integration', 'how_to', 'other'])[1 + floor(random() * 7)::int],
       (array['low', 'normal', 'high', 'urgent'])[1 + floor(random() * 4)::int],
       ts, ts
from (
  select g, random() as r, now() - random() * interval '730 days' as ts, 1 + floor(random() * 1000)::int as cn
  from generate_series(1, 50000) g
) x
join lab_customers c on c.n = x.cn;

-- ANALYZE samples 300 x (largest statistics target) rows. At the default target
-- (100) that is 30,000 of the 50,040 rows, picked at random, so the planner's
-- estimates (cost, estimated rows) shifted on every lab run. A target of 200 makes
-- the sample 60,000 rows, i.e. the whole table, so the estimates are the same on
-- every run and match TROUBLESHOOTING.md. It also applies to autovacuum's analyze.
alter table public.tickets alter column status set statistics 200;

analyze public.profiles;
analyze public.tickets;

select count(*) as tickets_total,
       count(*) filter (where status = 'open') as open,
       count(*) filter (where status = 'pending') as pending,
       count(*) filter (where status = 'resolved') as resolved
from public.tickets;
