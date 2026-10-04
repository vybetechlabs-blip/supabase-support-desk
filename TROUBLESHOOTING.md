# Troubleshooting lab

Four problems that show up in real Supabase support queues, reproduced on this
project's local stack. Each one is written as a reply to the developer who
reported it: what we ran, what the output showed, why that pointed to the cause,
the fix as a migration, and a test that fails before the fix and passes after.
Each scenario ends with steps you can run yourself in Studio's SQL editor.

## How the numbers were measured

Every plan, count and timing below is copied from one recorded run on
2026-10-04 (`npm run lab -- all`, started 04:31 UTC). The complete logs are in
[`lab/evidence/2026-10-04/`](lab/evidence/2026-10-04/). Each number carries a tag
saying how it was measured:

| Tag | What was run | How timings were taken |
|---|---|---|
| **[API]** | `lab/0N-*/diagnose.mjs`: the request the app sends, through the Data API (PostgREST), signed in as the user, plan captured with supabase-js `.explain({ analyze: true, buffers: true })` | 1 warm-up, then 7 runs; median reported, all 7 listed |
| **[by hand]** | `lab/0N-*/by-hand.sql`: the steps in the "Reproduce it by hand" sections, each sent on its own to the local Studio's SQL endpoint, `/api/platform/pg-meta/default/query` (we checked in the browser that the SQL editor's Run button posts there; it runs as `postgres`) | same: 1 warm-up, then 7 runs |
| **[count]** | a row count or function-call count | single run; these do not vary |

Timings depend on the machine (these came from a Windows 11 workstation running
Docker Desktop 4.93.0 and Postgres 17.11). Expect your timings to differ; plan
shapes, row counts, call counts and buffer counts should match, with one
exception explained in scenario 3 (about 55 extra buffers the first time a
statement runs in a new database session).

**[API] and [by hand] numbers measure different queries.** The API request
includes everything PostgREST adds (embedded resources, JSON aggregation, the
full JWT claims of a real session). The by-hand SQL is the smallest query that
shows the problem. Each scenario says what the difference is.

## Run it yourself

You need the local stack running (`npx supabase start`) and `.env.local` filled
in (see the README). Then:

```bash
npm run lab -- 1     # or 2, 3, 4, or all
```

Each run **resets the local database first** (it wipes local data), then:

1. loads the 50,000-ticket lab data set (scenarios 3 and 4 only, `lab/common/bulk-seed.sql`)
2. applies `break.sql`, which puts the database into the state the developer reported
3. runs `diagnose.mjs` ([API] evidence) and `by-hand.sql` ([by hand] evidence)
4. runs `test.sql` with pgTAP and requires it to **fail**
5. applies `fix.sql`, the migration we would hand back
6. repeats step 3, then runs `test.sql` and requires it to **pass**

Output goes to the console and to `lab/out/<scenario>.log`. To restore the demo
data afterwards: `npm run test:db` (or `npx supabase db reset`), then
`npm run embed:backfill`.

To capture [API] plans, the lab turns on PostgREST's plan output for the local
database only
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

### Running SQL as an app user

Studio's SQL editor connects as `postgres`, which bypasses RLS, so a plain query
there tells you nothing about what a user can see. Every "as <user>" step below
starts with the same two lines. They set that user's JWT claims and switch to
the `authenticated` role, the identity the API uses for a signed-in request:

```sql
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from auth.users where email = 'dana@example.com'), 'role', 'authenticated')::text, true);
set local role authenticated;
-- your query here
```

Run **one step at a time**: paste a step on its own, or select its lines and run
the selection. Studio runs the editor's text as one transaction and shows the
result of the last statement, so `set local role` lasts for that run only.
`npm run by-hand -- N` runs the same steps for you through the same endpoint.

---

## 1. "A customer just quoted one of our internal notes back to us"

> We added internal notes for agents last week. Today a customer replied quoting
> a note that only agents should see. We use RLS on `messages`. What happened?

### What we ran

The first question is whether the database really returns the notes to the
customer, or whether the leak is somewhere in your frontend. So we queried
exactly as the customer's browser does: publishable key, signed in as the
customer (`lab/01-policy-leak/diagnose.mjs`, [API]):

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
ownership check, so agents still read everything. After the fix the same request
returns `rows returned: 9, of which is_internal = true: 0` [API].

Realtime follows the same policy. With the correct policy in place, a customer's
subscription to `messages` does not receive internal-note events at all (checked
with a raw Postgres Changes listener in the customer's browser during the app's
own testing; not part of this lab run).

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

After the fix the same file passes.

### Reproduce it by hand (`lab/01-policy-leak/by-hand.sql`)

Load the broken state: `npx supabase db reset`, then
`npm run sql -- lab/01-policy-leak/break.sql`. In Studio's SQL editor:

1. **As dana@example.com, count the internal notes she can read** (step 1 of the
   file). You should see `internal_notes_visible = 3`, on tickets 1, 9 and 17
   [count]. A customer session gets them from the database itself.
2. **Read the select policy** (step 2). The `qual` column is the `USING` clause
   above, with no `is_internal`.
3. Apply the fix (`npm run sql -- lab/01-policy-leak/fix.sql`) and run step 1
   again: `internal_notes_visible = 0` [count].

You can also see it in the app: sign in as Dana in the broken state and open
ticket #1. The note appears with an "internal note" badge.

---

## 2. "Customers can't reply on their own tickets: 403"

> Since yesterday's deploy, customers get an error when they reply to a ticket.
> Agents can still post. We didn't change the app code, only some policies.

### What we ran, step by step (`lab/02-blocked-reply/diagnose.mjs`, [API])

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
whole expression at once, run each piece with the same identity the API uses,
inside a transaction that is rolled back:

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

After the fix the same client request returns `HTTP 201 Created` [API].

### How we proved it (`lab/02-blocked-reply/test.sql`)

The test checks the repair and also that the repair did not open anything else:
a customer still cannot reply on someone else's ticket or post an internal
note. Before the fix:

```
# Failed test 1: "customer can reply on their own (unassigned) ticket"
#     died: 42501: new row violates row-level security policy for table "messages"
```

After the fix all four assertions pass.

### Reproduce it by hand (`lab/02-blocked-reply/by-hand.sql`)

Load the broken state: `npx supabase db reset`, then
`npm run sql -- lab/02-blocked-reply/break.sql`. In Studio's SQL editor:

1. **As dana@example.com, insert a reply on ticket 9** (step 1). Studio shows
   `ERROR: 42501: new row violates row-level security policy for table "messages"`.
2. **Check the grant** (step 2): `authenticated_can_insert = true`.
3. **Read the insert policies** (step 3): the customer branch tests
   `tickets.assignee_id`.
4. **As Dana, evaluate the customer branch for ticket 9** (step 4):
   `caller_is_agent = false`, `ticket_assigned_to_caller = false`,
   `ticket_owned_by_caller = true`.
5. Apply the fix (`npm run sql -- lab/02-blocked-reply/fix.sql`) and run step 1
   again. It now returns the new message's `id`. Studio commits it, so this
   leaves one real reply in your local data.

In the app: sign in as Dana in the broken state, open ticket #9 and send a
reply. The error appears in red under the reply box.

---

## 3. "The agent ticket list keeps getting slower"

> Our agents' main screen lists open tickets, newest first, 50 at a time. It was
> instant at launch and it gets a little slower every week.

### What we ran (`lab/03-slow-ticket-list/diagnose.mjs`, [API])

The lab loads 50,000 tickets (50,040 with the seed; 2,920 open) and removes the
index that the app's migrations normally create, to match your database. Then
it asks PostgREST for the plan of the **exact request the app sends**, signed in
as an agent:

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
The key nodes of the plan [API] (the nodes for the two embedded names are
summarised in the comment; they are in the evidence log):

```
Aggregate  (cost=8756.67..8756.69 rows=1 width=144) (actual time=12.377..12.382 rows=1 loops=1)
  Buffers: shared hit=3994
  ->  Limit  (cost=8756.29..8756.42 rows=50 width=125) (actual time=12.157..12.171 rows=50 loops=1)
        ->  Sort  (cost=8756.00..8759.69 rows=1476 width=125) (actual time=12.156..12.164 rows=50 loops=1)
              Sort Method: top-N heapsort  Memory: 44kB
              ...
                          ->  Seq Scan on tickets  (cost=0.00..1864.60 rows=1476 width=93) (actual time=0.183..5.471 rows=2920 loops=1)
                                Rows Removed by Filter: 47120
                                Buffers: shared hit=1117
              ... (customer and assignee name lookups: Buffers: shared hit=2877)
Planning Time: 0.531 ms
Execution Time: 12.480 ms
```

Execution time [API], 7 runs (ms): 12.48, 13.091, 12.178, 11.551, 11.957, 11.889,
12.896. **Median 12.178 ms.**

### Why that points to the cause

- `Seq Scan on tickets` with `Rows Removed by Filter: 47120`: to show 50 rows,
  Postgres read every ticket and threw away 47,120 of them.
- Then it looked up the customer and assignee names for all 2,920 open tickets
  (2,877 buffers) and sorted them (`top-N heapsort`) only to keep 50.
- Buffers: 3,994 pages touched for one screen of results: 1,117 for the scan
  (the table is 1,114 pages) and 2,877 for the name lookups.

The work grows with the size of the whole table, not with the 50 rows on
screen, which matches "a little slower every week". 12 ms at 50,040 rows is not
slow yet in absolute terms; we did not measure larger tables, so we can only say
the cost scales with the number of rows scanned.

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

### After the fix [API]

```
Aggregate  (cost=337.18..337.20 rows=1 width=144) (actual time=0.734..0.737 rows=1 loops=1)
  Buffers: shared hit=206
  ->  Limit  (cost=1.86..336.93 rows=50 width=125) (actual time=0.294..0.577 rows=50 loops=1)
        ...
                    ->  Index Scan using tickets_status_created_at_idx on tickets  (cost=0.41..3061.60 rows=1479 width=93) (actual time=0.170..0.217 rows=50 loops=1)
                          Index Cond: (status = 'open'::text)
                          Buffers: shared hit=56
Planning Time: 0.331 ms
Execution Time: 0.800 ms
```

Execution time [API], 7 runs (ms): 0.8, 0.879, 0.755, 0.698, 0.724, 0.747, 0.76.
**Median 0.755 ms**, down from 12.178 ms. The scan reads 50 rows instead of
50,040, the sort is gone, the name lookups run 50 times instead of 2,920, and the
request touches 206 buffers instead of 3,994.

### How we proved it (`lab/03-slow-ticket-list/test.sql`)

The test plans the list query as an agent (so RLS is included) and checks the
plan shape, which is stable, rather than a timing, which is not. Before the fix:

```
# Failed test 2: "agent list query does not sequentially scan tickets"
#     Unexpected records:
#         ("        ->  Seq Scan on tickets  (cost=0.00..1864.60 rows=1476 width=61)")
# Failed test 3: "agent list query reads the (status, created_at desc) index"
```

After the fix all three assertions pass.

### Reproduce it by hand (`lab/03-slow-ticket-list/by-hand.sql`)

Load the broken state: `npx supabase db reset`, then
`npm run sql -- lab/common/bulk-seed.sql` and
`npm run sql -- lab/03-slow-ticket-list/break.sql`. In Studio's SQL editor:

1. **Table size and indexes** (step 1): `heap_pages = 1114`, `tickets = 50040`,
   indexes `tickets_assignee_id_idx, tickets_customer_id_idx, tickets_pkey`
   [count].
2. **As ava.agent@example.com, plan the list query** (step 2). This is plain SQL:
   it selects four columns and has no embedded names, so it does less work than
   the API request above. You should see [by hand]:

   ```
   Limit  (cost=1913.92..1914.05 rows=50 width=40) (actual time=7.749..7.757 rows=50 loops=1)
     Buffers: shared hit=1172
     ...  (InitPlan for the role check: Buffers: shared hit=55)
     ->  Sort  (cost=1913.63..1917.32 rows=1476 width=40) (actual time=7.748..7.752 rows=50 loops=1)
           Sort Method: top-N heapsort  Memory: 31kB
           ->  Seq Scan on tickets  (cost=0.00..1864.60 rows=1476 width=40) (actual time=0.360..7.317 rows=2920 loops=1)
                 Rows Removed by Filter: 47120
                 Buffers: shared hit=1169
   Execution Time: 7.793 ms
   ```

   Execution time [by hand], 7 runs (ms): 7.793, 7.166, 12.217, 7.509, 7.533,
   7.07, 7.115. **Median 7.509 ms.**

   Why the scan shows 1,169 buffers here and 1,117 in the [API] plan: the table
   is 1,114 pages either way. The role check (`(select private.is_agent())`)
   runs once per statement, and the first time it runs in a **new database
   session**, Postgres reads about 55 pages of system catalog to load metadata
   into that session's cache; those reads are counted under the scan. The plan
   above came from a request that Studio's endpoint ran in a new session (the
   InitPlan line shows the 55); the [API] request reused a warm session.
   `lab/common/probes.mjs` shows the effect directly
   ([`probes.log`](lab/evidence/2026-10-04/probes.log)): the same statement read
   1,173 buffers on its first run in a new session and 1,117 on every repeat.
3. Apply the fix (`npm run sql -- lab/03-slow-ticket-list/fix.sql`) and run step 2
   again [by hand]: `Index Scan using tickets_status_created_at_idx` with
   `rows=50` and no Sort node, `Buffers: shared hit=109`. Execution time 7 runs
   (ms): 0.561, 0.656, 0.693, 0.544, 0.549, 0.567, 0.6. **Median 0.567 ms.**

---

## 4. "Fast in the SQL editor, slow in the app"

> Our agents' dashboard shows how many billing tickets there are. The same
> count runs in about 5 ms in the SQL editor but takes around 150 ms in the app.
> Same data, same query.

### What we ran (`lab/04-slow-policy/diagnose.mjs`)

"Same query, different speed" between the SQL editor and the app usually means
it is not the same query. The SQL editor connects as `postgres`, which bypasses
RLS; the app runs as `authenticated`, and every policy is added to the query.
So we ran both and compared.

As the table owner (role `postgres`, the SQL editor's identity):

```
Aggregate  (cost=1757.52..1757.53 rows=1 width=8) (actual time=5.239..5.240 rows=1 loops=1)
  Buffers: shared hit=1114
  ->  Seq Scan on tickets  (cost=0.00..1739.50 rows=7206 width=0) (actual time=0.009..4.971 rows=7220 loops=1)
        Filter: (category = 'billing'::text)
        Rows Removed by Filter: 42820
Execution Time: 5.264 ms
```

7 runs on a direct connection (ms): 5.264, 5.517, 5.972, 5.416, 5.46, 5.588,
5.389. **Median 5.46 ms.**

From the app, signed in as an agent, through the API [API]
(`select('id', { count: 'exact' }).eq('category', 'billing').limit(1)`):

```
Aggregate  (cost=15512.97..15512.99 rows=1 width=144) (actual time=159.121..159.122 rows=1 loops=1)
  Buffers: shared hit=22779
    ->  Aggregate  (cost=15506.52..15506.53 rows=1 width=8) (actual time=158.962..158.963 rows=1 loops=1)
          ->  Seq Scan on tickets tickets_1  (cost=0.00..15500.50 rows=2407 width=0) (actual time=0.111..157.834 rows=7220 loops=1)
                Filter: ((category = 'billing'::text) AND ((customer_id = (COALESCE(NULLIF(current_setting('request.jwt.claim.sub'::text, true), ''::text), ((NULLIF(current_setting('request.jwt.claims'::text, true), ''::text))::jsonb ->> 'sub'::text)))::uuid) OR private.is_agent()))
                Rows Removed by Filter: 42820
  ...
Execution Time: 159.183 ms
```

7 runs (ms): 159.183, 160.756, 146.081, 147.166, 150.391, 150.374, 150.148.
**Median 150.374 ms**, about 28 times the table owner's 5.46 ms.

### What it showed, and why that points to the policy

Both plans scan the same 50,040 rows and keep the same 7,220. The difference is
in the `Filter` line of the app's plan: the policy was added to the query, and
`private.is_agent()` appears **inside the per-row filter**. Compare scenario 3's
plan, where the role check shows up as `(InitPlan 2).col1`, a value computed
once and reused. The buffer count tells the same story: 22,779 buffers for the
app's request against 1,114 for the table owner, because every row's role check
looks up the caller in `profiles`.

The policy explains why:

```
tickets: customers read own, agents read all
  USING ((customer_id = auth.uid()) OR private.is_agent())
```

Two things happen to these calls:

- `auth.uid()` is a small SQL function, so Postgres inlined it: the
  `COALESCE(NULLIF(current_setting(...` text in the filter is its body. It reads
  the request's JWT claims and parses them as JSON, for every row.
- `private.is_agent()` is `SECURITY DEFINER`, so it cannot be inlined. It runs
  as a separate function call, which reads the claims again and looks up the
  caller in `profiles`, for every row that reaches it. For an agent,
  `customer_id = auth.uid()` is false on almost every row, so the OR evaluates
  the role check each time.

To confirm, we counted calls for one request with `track_functions = 'all'` and
`pg_stat_xact_user_functions` [count]:

```
{ rows_counted: 7220, is_agent_calls: 7220 }
```

One role lookup per row. The answer never changes within a request, so 7,219
of those calls were wasted.

Because the claims are parsed on every row, the cost also depends on the size of
the JWT. A real session token's claims are 460 bytes here (email, app_metadata,
user_metadata, amr, session_id and more), against 69 bytes for a two-field
claims object ([`probes.log`](lab/evidence/2026-10-04/probes.log)). The by-hand steps below show the same
count taking about 86 ms with a two-field claims object and about 151 ms with
token-sized claims.

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

### After the fix [API]

```
Aggregate  (cost=1874.73..1874.75 rows=1 width=144) (actual time=6.618..6.621 rows=1 loops=1)
  Buffers: shared hit=1122
    ->  Aggregate  (cost=1873.91..1873.92 rows=1 width=8) (actual time=6.425..6.426 rows=1 loops=1)
          ->  Seq Scan on tickets tickets_1  (cost=0.00..1864.60 rows=3606 width=0) (actual time=0.123..6.126 rows=7220 loops=1)
                Filter: (((customer_id = (InitPlan 1).col1) OR (InitPlan 2).col1) AND (category = 'billing'::text))
                Rows Removed by Filter: 42820
  ...
Execution Time: 6.672 ms
```

7 runs (ms): 6.672, 6.818, 6.214, 6.614, 6.192, 5.981, 6.348. **Median 6.348 ms**,
down from 150.374 ms and within 1 ms of the table owner (median 5.356 ms in the
same after-fix pass). Buffers: 1,122 instead of 22,779. Call count:
`{ rows_counted: 7220, is_agent_calls: 1 }` [count].

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

### Reproduce it by hand (`lab/04-slow-policy/by-hand.sql`)

Load the broken state: `npx supabase db reset`, then
`npm run sql -- lab/common/bulk-seed.sql` and
`npm run sql -- lab/04-slow-policy/break.sql`. In Studio's SQL editor:

| Step | What it runs | Broken policy [by hand] | After the fix [by hand] |
|---|---|---|---|
| 1 | count as the table owner | median **6.308 ms**, 1,114 buffers | median 6.375 ms |
| 2 | count as the agent, minimal claims (`sub`, `role`) | median **85.943 ms**, 22,831 buffers, `private.is_agent()` in the Filter line | median 7.429 ms, 1,175 buffers, `(InitPlan 2).col1` in the Filter line |
| 3 | count as the agent, token-sized claims built from the user's row | median **151.015 ms**, 22,831 buffers | median 7.611 ms |
| 4 | calls to `private.is_agent()` for one count | `is_agent_calls = 7220` [count] | `is_agent_calls = 1` [count] |
| 5 | the select policy | `((customer_id = auth.uid()) OR private.is_agent())` | `((customer_id = ( SELECT auth.uid() AS uid)) OR ( SELECT private.is_agent() AS is_agent))` |

All 7 runs (ms) for each timed step:

- Step 1 broken: 6.59, 6.263, 6.134, 6.308, 6.381, 6.189, 6.497. After fix: 6.416, 6.375, 6.618, 6.479, 6.202, 6.11, 5.985.
- Step 2 broken: 85.076, 86.279, 85.747, 88.898, 85.943, 89.213, 85.269. After fix: 12.087, 7.447, 7.647, 6.836, 7.368, 7.429, 7.043.
- Step 3 broken: 189.519, 148.704, 148.322, 151.015, 156.427, 157.039, 150.194. After fix: 7.611, 7.638, 7.57, 7.66, 7.54, 7.176, 7.877.

Step 3 lands near the [API] number because it matches what the API does:
token-sized claims, parsed per row. Step 2 is faster only because its claims are
tiny; the policy is equally broken in both.
