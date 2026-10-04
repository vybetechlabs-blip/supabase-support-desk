# Supabase Support Desk

A small support desk built on Supabase: customers file tickets, agents answer them,
and every new ticket is triaged by an Edge Function that stores an embedding and
classifies it. The agent view suggests similar resolved tickets with their
resolutions. [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) is a lab of four reproducible
Supabase problems (row level security and query performance), each with a diagnosis,
a fix and a test.

> Status: the full setup guide, architecture notes and walkthrough are still being
> written. The section below describes ticket triage as it behaves today.

## Ticket triage

When a customer submits a ticket, the app calls the `triage` Edge Function
(`supabase/functions/triage/`) with the customer's session. The function:

1. reads the ticket through the caller's row level security (a customer can only
   triage their own ticket, an agent any ticket);
2. stores a 384-dimension embedding from `gte-small`, the embedding model built into
   Supabase Edge Functions (no key needed);
3. asks Claude Haiku 4.5 (`claude-haiku-4-5`) for a category and a priority, if
   `ANTHROPIC_API_KEY` is set, and fills in whichever of the two is still empty.
   It never overwrites a value an agent already set.

Agents see a **Triage** box on each ticket with a **Run triage** / **Re-run triage**
button. Only agents can re-run it; for customers the function returns 403.

**With `ANTHROPIC_API_KEY` set** (in `supabase/functions/.env`, then restart the
local stack), a new ticket arrives classified. Observed on the local stack on
2026-10-04:

- A customer filed "Billed for 12 seats but we only have 9 users". It was stored
  as `billing` / `high` about a second after it was created, with its embedding.
- An agent cleared the category and priority of "Attachments missing from sent
  invoices" and pressed **Re-run triage**. The Triage box reported
  "Classified by claude-haiku-4-5: bug / high", and the ticket's fields updated.

**Without the key**, triage still stores the embedding, so similar-ticket
suggestions work, but category and priority stay "untriaged" for an agent to set.
The Triage box says so. There is no keyword-based guess.

**When the classifier call fails**, the ticket is still created and still gets
its embedding. Observed on 2026-10-04 with the functions served using an invalid
key (Anthropic answered `401 authentication_error`):

- The customer's new ticket was created and opened normally; the customer sees
  nothing about the failure.
- The function answered 200 with `classifier: "error"` and
  `note: "Anthropic API 401"`. The ticket got its 384-dimension embedding, its
  category and priority stayed empty, and it was marked triaged.
- Similar-ticket suggestions worked, because they only need the embedding.
- An agent's **Re-run triage** showed "Embedding stored. Classification failed
  (Anthropic API 401)." After the normal key was restored, the same button
  classified the ticket.

Nothing retries automatically: a ticket triaged during an outage keeps empty
fields until an agent sets them or presses **Re-run triage**.

Tests for this path: `npm run test:unit` (the classification step with fake
clients: API error, network error, refusal, unusable output) and
`npm run check:triage-failure` (end to end against a functions server started
with an invalid key; instructions at the top of
`scripts/check-triage-failure.mjs`).
