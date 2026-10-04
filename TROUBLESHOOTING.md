# Troubleshooting lab

Four problems that show up in real Supabase support queues, reproduced on this
project's local stack. Each one is written as a reply to the developer who
reported it: what we ran, what the output showed, why that pointed to the cause,
the fix as a migration, and a test that fails before the fix and passes after.

Every plan, count and timing below is copied from the run of 2026-10-04. The
complete logs of that run are committed in
[`lab/evidence/2026-10-04/`](lab/evidence/2026-10-04/). Your own numbers will
differ by machine; the plan shapes and call counts should not.

## Run it yourself

You need the local stack running (`npx supabase start`) and `.env.local` filled
in (see the README). Then:

```bash
npm run lab -- 1     # or 2, 3, 4, or all
```

Each run **resets the local database first** (it wipes local data), then:

1. loads the 50,000-ticket lab data set (scenarios 3 and 4 only, `lab/common/bulk-seed.sql`)
2. applies `break.sql`, which puts the database into the state the developer reported
3. runs `diagnose.mjs`, the evidence gathering described below
4. runs `test.sql` with pgTAP and requires it to **fail**
5. applies `fix.sql`, the migration we would hand back
6. runs `diagnose.mjs` again, then `test.sql`, and requires it to **pass**

Output goes to the console and to `lab/out/<scenario>.log`.

To run the plans through the API the way scenarios 3 and 4 do, the lab turns on
PostgREST's plan output for the local database only
(`alter role authenticator in database postgres set pgrst.db_plan_enabled to 'true'`).
The next `supabase db reset` removes it. Do not turn it on in production; the
Supabase docs ("Debugging performance issues") explain how to restrict it if you
ever need it there.

| # | Reported problem | Cause | Fix |
|---|---|---|---|
| 1 | Customers can see our internal notes | Select policy lost its `is_internal = false` condition | Put the condition back inside the customer branch |
| 2 | Customers get a 403 when they reply | Insert policy checks assignment instead of ownership | Check `customer_id`, not `assignee_id` |
| 3 | Agent ticket list gets slower every week | No index matches "filter by status, newest first" | Composite index `(status, created_at desc)` |
| 4 | Fast in the SQL editor, slow in the app | Policy calls the role helper once per row | Wrap the calls in `(select ...)` |

---

## 1. "A customer just quoted one of our internal notes back to us"

> We added internal notes for agents last week. Today a customer replied quoting
> a note that only agents should see. We use RLS on `messages`. What happened?

### What we ran

The first question is whether the database really returns the notes to the
customer, or whether the leak is somewhere in your frontend. So we queried
exactly as the customer's browser does: publishable key, signed in as the
customer (`lab/01-policy-leak/diagnose.mjs`).

```
=== As customer dana@example.com (publishable key + her session): messages on her tickets ===
rows returned: 12, of which is_internal = true: 3
  LEAK? ticket 1, message 59: Corporate filter on the customer domain held our transactional sender.
  LEAK? ticket 9, message 62: Plan cache refreshes at sign-in. If still greyed out after re-login, c
  LEAK? ticket 17, message 67: Missing composite index on (workspace, status, created_at). Added.

=== Direct question: can this customer select any internal note? ===
count of is_internal rows visible to the customer: 3
```

### What it showed, and why that points to the policy

The API handed internal notes to a signed-in customer. The frontend is not
involved: any customer with your publishable key can run that query from a
browser console. Since RLS decides which rows a role can read, the next stop
is the select policy:

```
=== Select policies on public.messages (pg_policies) ===
messages: ticket participants read  roles={authenticated}
  USING (( SELECT private.is_agent() AS is_agent) OR (ticket_id IN ( SELECT tickets.id
   FROM tickets
  WHERE (tickets.customer_id = ( SELECT auth.uid() AS uid)))))
```

Read the `USING` clause as a customer: "you are an agent, OR the message
belongs to one of your tickets." Nothing mentions `is_internal`. When the
policy was simplified to "participants can read the ticket's messages", the
internal-note condition went with it. Postgres combines permissive policies
with OR, so if you ever have two select policies, check both: one loose policy
is enough to leak.

### The fix (`lab/01-policy-leak/fix.sql`)

```sql
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
```

The `is_internal = false` sits inside the customer branch, next to the
ownership check, so agents still read everything.

Realtime follows the same policy. With the fix in place, a customer's
subscription to `messages` does not receive internal-note events at all (we
checked this with a raw listener in the browser during the app's own testing).

### How we proved it (`lab/01-policy-leak/test.sql`)

Before the fix:

```
# Failed test 1: "customer reads no internal notes at all"
#     Unexpected records:
#         (76)
# Failed test 2: "customer reads only the public reply on their own ticket"
#     Results differ beginning at row 2:
#         have: ("internal note")
#         want: NULL
```

After the fix the same file passes, and diagnose shows
`rows returned: 9, of which is_internal = true: 0`.

---

## 2. "Customers can't reply on their own tickets: 403"

> Since yesterday's deploy, customers get an error when they reply to a ticket.
> Agents can still post. We didn't change the app code, only some policies.

### What we ran, step by step (`lab/02-blocked-reply/diagnose.mjs`)

**1. Reproduce what the client sees.** Signed in as the customer, insert a reply
on her own ticket #9:

```
HTTP 403 Forbidden
{
  "code": "42501",
  "details": null,
  "hint": null,
  "message": "new row violates row-level security policy for table \"messages\""
}
```

Two details narrow it down. `42501` is Postgres "insufficient privilege", and
the message names RLS and the table: a row was offered and a policy's
`WITH CHECK` rejected it. (PostgREST returns 403 for this when the request has a
user session; without a session it would be 401.)

**2. Rule out a missing grant.** A missing table privilege also raises `42501`,
but with the text "permission denied for table messages". To be sure:

```
{ authenticated_can_insert: true }
```

The role may insert, so a policy is refusing the row.

**3. Read the insert policies.**

```
messages: reply on tickets you work on  PERMISSIVE roles={authenticated}
  WITH CHECK ((author_id = ( SELECT auth.uid() AS uid)) AND (( SELECT private.is_agent() AS is_agent) OR ((is_internal = false) AND (ticket_id IN ( SELECT tickets.id
   FROM tickets
  WHERE (tickets.assignee_id = ( SELECT auth.uid() AS uid)))))))
```

**4. Evaluate each condition as that customer.** Instead of reasoning about the
whole expression at once, run each piece with the same identity the API uses:
`set local role authenticated` plus her JWT claims in
`request.jwt.claims`, inside a transaction that is rolled back.

```
{
  author_is_caller: true,
  not_internal: true,
  caller_is_agent: false,
  ticket_assigned_to_caller: false,
  ticket_owned_by_caller: true
}
```

### Why that points to the cause

A customer passes the check only through the second branch, and that branch
asks whether the ticket is **assigned to** the caller. Customers are never
assignees, so the condition is false for every customer reply. The line we
would expect, "ticket is **owned by** the caller", is true. Agents are
unaffected because `caller_is_agent` short-circuits the OR, which is why only
customers noticed.

### The fix (`lab/02-blocked-reply/fix.sql`)

```sql
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
```

### How we proved it (`lab/02-blocked-reply/test.sql`)

The test checks the repair and also that the repair did not open anything else:
a customer still cannot reply on someone else's ticket or post an internal
note. Before the fix:

```
# Failed test 1: "customer can reply on their own (unassigned) ticket"
#     died: 42501: new row violates row-level security policy for table "messages"
```

After the fix all four assertions pass, and the same client request returns
`HTTP 201 Created`.

---

## 3. "The agent ticket list keeps getting slower"

> Our agents' main screen lists open tickets, newest first, 50 at a time. It was
> instant at launch and it gets a little slower every week.

### What we ran (`lab/03-slow-ticket-list/diagnose.mjs`)

The lab loads 50,000 tickets (2,920 open) and removes the index that the app's
migrations normally create, to match your database. Then it asks PostgREST for
the plan of the **exact request the app sends**, signed in as an agent, using
supabase-js:

```js
agent.from('tickets')
  .select('id, subject, status, category, priority, created_at, updated_at,' +
          ' customer:profiles!tickets_customer_id_fkey(display_name),' +
          ' assignee:profiles!tickets_assignee_id_fkey(display_name)')
  .eq('status', 'open')
  .order('created_at', { ascending: false })
  .limit(50)
  .explain({ analyze: true, buffers: true })
```

Planning through the API matters: it includes your RLS policies and the joins
PostgREST adds for embedded resources, which a hand-written query in the SQL
editor would leave out.

### What the plan showed

Indexes on `tickets` at the time: primary key, `customer_id`, `assignee_id`.
The key nodes of the plan (the profile-lookup nodes for the two embedded names
are omitted here; they are in the evidence log):

```
Aggregate  (cost=8820.07..8820.09 rows=1 width=144) (actual time=15.931..15.935 rows=1 loops=1)
  Buffers: shared hit=3994
  ->  Limit  (cost=8819.69..8819.82 rows=50 width=125) (actual time=15.784..15.794 rows=50 loops=1)
        ->  Sort  (cost=8819.40..8823.17 rows=1508 width=125) (actual time=15.783..15.790 rows=50 loops=1)
              Sort Key: tickets.created_at DESC
              Sort Method: top-N heapsort  Memory: 44kB
              ...
                          ->  Seq Scan on tickets  (cost=0.00..1864.60 rows=1508 width=93) (actual time=0.162..7.076 rows=2920 loops=1)
                                Filter: (((customer_id = (InitPlan 1).col1) OR (InitPlan 2).col1) AND (status = 'open'::text))
                                Rows Removed by Filter: 47120
Planning Time: 0.385 ms
Execution Time: 16.002 ms
```

Execution time over 7 runs (ms): 16.002, 16.334, 14.143, 13.949, 14.637,
14.628, 13.736. **Median 14.628 ms.**

### Why that points to the cause

- `Seq Scan on tickets` with `Rows Removed by Filter: 47120`: to show 50 rows,
  Postgres read every ticket and threw away 47,120 of them.
- Then it joined profile names for all 2,920 open tickets and sorted them
  (`top-N heapsort`) only to keep 50.
- Buffers: 3,994 pages touched for one screen of results.

The work grows with the size of the whole table, not with the 50 rows on screen.
That is exactly "a little slower every week". 15 ms at 50,000 rows is not slow
yet in absolute terms; the trend is the problem, and the same plan at a few
million rows would take seconds.

The RLS part of the filter is not the cost here: `(InitPlan 1)` and
`(InitPlan 2)` mean `auth.uid()` and the role check are each evaluated once for
the whole statement (scenario 4 shows what it looks like when they are not).

### The fix (`lab/03-slow-ticket-list/fix.sql`)

```sql
create index if not exists tickets_status_created_at_idx
  on public.tickets (status, created_at desc);
analyze public.tickets;
```

Column order follows the query: the equality filter first (`status`), then the
sort key in the sort direction. Postgres can then walk the index for one
status, newest first, and stop after 50 rows. On a busy production table, build
it with `create index concurrently` so writes are not blocked; that statement
cannot run inside a transaction block, so run it outside a migration that your
tooling wraps in a transaction.

### After the fix

```
Aggregate  (cost=337.95..337.97 rows=1 width=144) (actual time=0.646..0.648 rows=1 loops=1)
  Buffers: shared hit=206
  ->  Limit  (cost=1.86..337.70 rows=50 width=125) (actual time=0.288..0.505 rows=50 loops=1)
        ...
                    ->  Index Scan using tickets_status_created_at_idx on tickets  (cost=0.41..3043.75 rows=1469 width=93) (actual time=0.164..0.203 rows=50 loops=1)
                          Index Cond: (status = 'open'::text)
                          Filter: ((customer_id = (InitPlan 1).col1) OR (InitPlan 2).col1)
Planning Time: 0.333 ms
Execution Time: 0.710 ms
```

Execution time over 7 runs (ms): 0.71, 0.693, 0.953, 0.995, 0.718, 1.015,
0.723. **Median 0.723 ms**, down from 14.628 ms. The scan reads 50 rows instead
of 50,040, the sort is gone, and 206 buffers instead of 3,994.

### How we proved it (`lab/03-slow-ticket-list/test.sql`)

The test plans the list query as an agent (so RLS is included) and checks the
plan shape, which is stable, rather than a timing, which is not. Before the fix:

```
# Failed test 2: "agent list query does not sequentially scan tickets"
#     Unexpected records:
#         ("        ->  Seq Scan on tickets  (cost=0.00..1864.60 rows=1508 width=61)")
# Failed test 3: "agent list query reads the (status, created_at desc) index"
```

After the fix all three assertions pass.

---

## 4. "Fast in the SQL editor, slow in the app"

> Our agents' dashboard shows how many billing tickets there are. The same
> count runs in about 5 ms in the SQL editor but takes 150 to 200 ms in the app.
> Same data, same query.

### What we ran (`lab/04-slow-policy/diagnose.mjs`)

"Same query, different speed" between the SQL editor and the app usually means
it is not the same query. The SQL editor connects as `postgres`, which bypasses
RLS; the app runs as `authenticated`, and every policy is added to the query.
So we ran both and compared.

In the SQL editor (role `postgres`):

```
Aggregate  (cost=1757.56..1757.57 rows=1 width=8) (actual time=5.276..5.277 rows=1 loops=1)
  ->  Seq Scan on tickets  (cost=0.00..1739.50 rows=7222 width=0) (actual time=0.008..5.002 rows=7220 loops=1)
        Filter: (category = 'billing'::text)
        Rows Removed by Filter: 42820
Execution Time: 5.299 ms
```

7 runs (ms): 5.299, 5.499, 5.347, 5.472, 5.331, 5.502, 5.559. **Median 5.472 ms.**

From the app, signed in as an agent, through the API
(`select('id', { count: 'exact' }).eq('category', 'billing').limit(1)`
with `.explain({ analyze: true, buffers: true })`):

```
Aggregate  (cost=15512.97..15512.99 rows=1 width=144) (actual time=202.574..202.576 rows=1 loops=1)
  InitPlan 1
    ->  Aggregate  (cost=15506.53..15506.54 rows=1 width=8) (actual time=202.363..202.363 rows=1 loops=1)
          ->  Seq Scan on tickets tickets_1  (cost=0.00..15500.50 rows=2412 width=0) (actual time=0.114..200.945 rows=7220 loops=1)
                Filter: ((category = 'billing'::text) AND ((customer_id = (COALESCE(NULLIF(current_setting('request.jwt.claim.sub'::text, true), ''::text), ((NULLIF(current_setting('request.jwt.claims'::text, true), ''::text))::jsonb ->> 'sub'::text)))::uuid) OR private.is_agent()))
                Rows Removed by Filter: 42820
  ->  Limit  (cost=0.00..6.43 rows=1 width=8) (actual time=0.204..0.205 rows=1 loops=1)
        ...
Execution Time: 202.619 ms
```

7 runs (ms): 202.619, 167.282, 147.131, 152.513, 151.774, 147.813, 144.817.
**Median 151.774 ms**, about 28 times the SQL editor.

### What it showed, and why that points to the policy

Both plans scan the same 50,040 rows and keep the same 7,220. The difference is
in the `Filter` line of the app's plan: the policy was added to the query, and
`private.is_agent()` appears **inside the per-row filter**. Compare scenario 3's
plan, where the role check shows up as `(InitPlan 2).col1`, a value computed
once and reused.

The policy explains why:

```
tickets: customers read own, agents read all
  USING ((customer_id = auth.uid()) OR private.is_agent())
```

Two things happen to these calls:

- `auth.uid()` is a small SQL function, so Postgres inlined it: the
  `COALESCE(NULLIF(current_setting(...` text in the filter is its body,
  evaluated for every row. Cheap, but repeated.
- `private.is_agent()` is `SECURITY DEFINER`, so it cannot be inlined. It runs
  as a separate function call, which looks up the caller in `profiles`, for
  every row that reaches it. For an agent, `customer_id = auth.uid()` is false on
  almost every row, so the OR evaluates the role check each time.

To confirm, we counted calls for one request with `track_functions = 'all'` and
`pg_stat_xact_user_functions`:

```
{ rows_counted: 7220, is_agent_calls: 7220 }
```

One role lookup per row. The answer never changes within a request, so 7,219
of those calls were wasted.

### The fix (`lab/04-slow-policy/fix.sql`)

```sql
drop policy "tickets: customers read own, agents read all" on public.tickets;

create policy "tickets: customers read own, agents read all"
  on public.tickets for select to authenticated
  using (
    customer_id = (select auth.uid())
    or (select private.is_agent())
  );
```

Same logic, same rows. Wrapping each call in `(select ...)` lets Postgres plan
it as an InitPlan, run it once per statement, and reuse the value for every
row. This is the pattern the Supabase RLS performance guide recommends for
`auth.uid()`, `auth.jwt()` and security definer helpers.

### After the fix

```
Aggregate  (cost=1874.76..1874.78 rows=1 width=144) (actual time=6.132..6.135 rows=1 loops=1)
  InitPlan 3
    ->  Aggregate  (cost=1873.93..1873.94 rows=1 width=8) (actual time=5.958..5.959 rows=1 loops=1)
          InitPlan 1
            ->  Result  (cost=0.00..0.03 rows=1 width=16) (actual time=0.008..0.009 rows=1 loops=1)
          InitPlan 2
            ->  Result  (cost=0.00..0.26 rows=1 width=1) (actual time=0.102..0.102 rows=1 loops=1)
          ->  Seq Scan on tickets tickets_1  (cost=0.00..1864.60 rows=3615 width=0) (actual time=0.115..5.661 rows=7220 loops=1)
                Filter: (((customer_id = (InitPlan 1).col1) OR (InitPlan 2).col1) AND (category = 'billing'::text))
                Rows Removed by Filter: 42820
  ...
Execution Time: 6.182 ms
```

7 runs (ms): 6.182, 6.285, 6.51, 6.293, 6.668, 7.172, 6.229. **Median 6.293 ms**,
down from 151.774 ms and within 1 ms of the SQL editor (median 5.516 ms in the
same after-fix run). Call count: `{ rows_counted: 7220, is_agent_calls: 1 }`.

There is still a sequential scan, because nothing indexes `category`. That is a
separate question (scenario 3's kind); this fix removes the RLS overhead.

### How we proved it (`lab/04-slow-policy/test.sql`)

The test counts calls instead of timing, so it gives the same answer on any
machine. Before the fix:

```
# Failed test 3: "private.is_agent() runs once per statement, not once per row"
#     '7220'
#         <=
#     '2'
```

After the fix all three assertions pass, including one that checks the agent
still sees every billing ticket (the rewrite changed the speed, not the result).

This project's main test suite would have caught the broken policy before it
shipped: `supabase/tests/database/010_rls_coverage.sql` fails if any policy
calls `auth.uid()` or `private.is_agent()` outside a `(select ...)` wrapper.
