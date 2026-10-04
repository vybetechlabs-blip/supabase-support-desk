-- Synthetic seed data. Every person, email and ticket here is invented.
-- Emails use example.com (reserved for documentation, RFC 2606).
--
-- Demo sign-in (local stack only): any address below, password `desk-demo-pass`.
--   agents:    ava.agent@example.com, ben.agent@example.com, cleo.agent@example.com
--   customers: dana@example.com, eli@example.com, faye@example.com, gus@example.com,
--              hana@example.com, ivo@example.com, june@example.com, kai@example.com
--
-- The docs do not cover seeding auth users. This inserts into auth.users and
-- auth.identities directly, with the empty-string token columns GoTrue expects
-- for password sign-in. Verified by signing in through the app at CP2.

-- ---------------------------------------------------------------------------
-- Users
-- ---------------------------------------------------------------------------
with people(email, display_name, is_agent) as (
  values
    ('ava.agent@example.com',  'Ava Moreno (Support)',   true),
    ('ben.agent@example.com',  'Ben Okafor (Support)',   true),
    ('cleo.agent@example.com', 'Cleo Varga (Support)',   true),
    ('dana@example.com',       'Dana Whitlock',          false),
    ('eli@example.com',        'Eli Brandt',             false),
    ('faye@example.com',       'Faye Lindqvist',         false),
    ('gus@example.com',        'Gus Teller',             false),
    ('hana@example.com',       'Hana Rook',              false),
    ('ivo@example.com',        'Ivo Castellan',          false),
    ('june@example.com',       'June Abara',             false),
    ('kai@example.com',        'Kai Penrose',            false)
),
ins as (
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change
  )
  select
    '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
    p.email, extensions.crypt('desk-demo-pass', extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', jsonb_build_object('display_name', p.display_name),
    now() - interval '120 days', now() - interval '120 days',
    '', '', '', ''
  from people p
  returning id, email
)
insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select ins.id::text, ins.id,
       jsonb_build_object('sub', ins.id::text, 'email', ins.email, 'email_verified', true),
       'email', now(), now(), now()
from ins;

-- The sign-up trigger made everyone a customer; promote the agents.
update public.profiles p
set role = 'agent'
from auth.users u
where u.id = p.id and u.email like '%.agent@example.com';

-- ---------------------------------------------------------------------------
-- Tickets. The product is a fictional invoicing app called "Tallybook".
-- ---------------------------------------------------------------------------
create temporary table seed_tickets (
  n int, customer text, subject text, body text, category text, priority text,
  status text, agent text, agent_reply text, customer_followup text, internal_note text,
  resolution text, age_days int
) on commit drop;

insert into seed_tickets values
(1,'dana@example.com','Password reset email never arrives','I clicked "forgot password" three times this morning and nothing has arrived, not even in spam. My login email is the same one I am writing from.','account','high','resolved','ava.agent@example.com','Thanks Dana. Our mail provider shows the messages were deferred by your company mail filter. I have re-sent the reset link from our secondary sender; it should arrive within a few minutes.','Got it, that worked. Thank you!','Corporate filter on the customer domain held our transactional sender. Re-sent via secondary.','Reset emails were held by the customer''s corporate mail filter. Re-sent from the secondary sender and asked IT to allowlist our transactional domain.',90),
(2,'eli@example.com','Cannot log in after changing my email address','I updated my account email yesterday and now the app says my credentials are wrong. The old email does not work either.','account','high','resolved','ben.agent@example.com','Hi Eli, the email change was still waiting for confirmation from the new address, so neither address was active for password sign-in. I confirmed it on our side after verifying your identity.','Logged in fine now.','Email change stuck in pending state; confirmed manually after ID check.','Email change was pending confirmation, which blocked both addresses. Confirmed the change after identity verification; customer can sign in with the new email.',84),
(3,'faye@example.com','Two-factor codes rejected','My authenticator app codes are always rejected. I have tried several times and the code is definitely current.','account','urgent','resolved','cleo.agent@example.com','Faye, the clock on your phone was about two minutes off, which makes time-based codes fail. Turning on automatic time in your phone settings should fix it.','You were right, the phone clock was wrong. Works now.',null,'TOTP codes failed because the phone clock had drifted about two minutes. Enabling automatic network time fixed it.',70),
(4,'gus@example.com','Locked out after too many login attempts','I think I typed my password wrong a few times and now it says the account is temporarily locked. How long does that last?','account','normal','resolved','ava.agent@example.com','Hi Gus, the lock lasts 15 minutes after five failed attempts. I have cleared it for you now. If you are unsure of the password, use the reset link instead of retrying.',null,null,'Account lock after five failed attempts; lock lasts 15 minutes. Cleared it manually and pointed the customer to password reset.',41),
(5,'hana@example.com','Want to delete my account','I am closing my business and want my account and data removed. What is the process?','account','low','open',null,null,null,null,null,2),
(6,'ivo@example.com','Charged twice this month','My card statement shows two charges for the same monthly plan on the 3rd. I only have one workspace.','billing','high','resolved','ben.agent@example.com','Ivo, I can see a duplicate charge caused by a retry after a card network timeout. I have refunded the second charge; it takes 5 to 10 business days to appear.','Thanks for the quick refund.','Duplicate from payment retry after network timeout. Refund issued.','Duplicate charge caused by an automatic payment retry after a card network timeout. Refunded the second charge (5 to 10 business days).',66),
(7,'june@example.com','Invoice shows the wrong company address','The receipts you send me still show our old office address. We moved in the spring.','billing','normal','resolved','cleo.agent@example.com','June, receipts use the billing address saved on the payment method, not the workspace profile. Update it under Settings > Billing > Payment method and future receipts will use the new address. I re-issued last month''s receipt with the correct address.',null,null,'Receipts take the address from the payment method, not the workspace profile. Customer updated it under Settings > Billing; past receipt re-issued.',58),
(8,'kai@example.com','Need a refund for unused seats','We removed four seats halfway through the billing period. Will we get credit for the unused time?','billing','normal','resolved','ava.agent@example.com','Kai, seat removals are prorated as account credit, applied to your next invoice automatically. You should see the credit line on the next invoice.','Makes sense, thanks.',null,'Removed seats are prorated as account credit on the next invoice, not refunded to the card.',35),
(9,'dana@example.com','Upgrade did not unlock recurring invoices','I upgraded to the Growth plan an hour ago but the recurring invoices feature is still greyed out.','billing','high','pending','ben.agent@example.com','Hi Dana, I see the upgrade went through. Could you sign out and back in? Plan features load at sign-in.',null,'Plan cache refreshes at sign-in. If still greyed out after re-login, check entitlement sync job.',null,1),
(10,'eli@example.com','Card declined but bank says it is fine','Every time I try to pay the invoice the card is declined. My bank says they see no attempt at all.','billing','urgent','resolved','cleo.agent@example.com','Eli, the attempts were blocked before reaching your bank because the billing postcode did not match the card. Please re-enter the postcode exactly as your bank has it.','That was it, payment went through.',null,'Payment blocked by postcode verification mismatch before reaching the bank. Customer corrected the billing postcode.',50),
(11,'faye@example.com','PDF export cuts off long line items','When I export an invoice to PDF, line item descriptions longer than about two lines are cut off.','bug','normal','resolved','ava.agent@example.com','Faye, this is a known issue with the PDF renderer and long descriptions. A fix shipped today; please export again and it should wrap correctly.','Confirmed, wraps now.','Linked to renderer bug, fixed in today''s release.','PDF renderer truncated long line-item descriptions. Fixed in a release; re-exporting produces wrapped text.',45),
(12,'gus@example.com','Dashboard totals do not match the invoice list','The dashboard says I have 4,210 outstanding but adding up the unpaid invoices gives 4,890.','bug','high','resolved','ben.agent@example.com','Gus, the dashboard excludes invoices in draft status, while the list includes them. Two drafts make up the difference. We are adding a label to the dashboard to make this clear.',null,'Not a calculation bug: drafts excluded from dashboard totals. Raised UX label request.','Dashboard outstanding total excludes draft invoices; the list includes them. Not a calculation bug; label added to clarify.',38),
(13,'hana@example.com','Dates show in the wrong format','All dates in the app are month/day but I am in the UK and expect day/month.','bug','low','resolved','cleo.agent@example.com','Hana, the date format follows the workspace locale, which was set to United States. You can change it under Settings > Workspace > Region.','Changed it, thanks.',null,'Date format follows the workspace locale setting. Changing Settings > Workspace > Region fixed it.',30),
(14,'ivo@example.com','Customer list will not load','The customers page spins forever and never shows anything. Other pages work.','bug','urgent','resolved','ava.agent@example.com','Ivo, one of your customer records had a malformed tax ID that crashed the list view. I corrected the record and the page now loads. We have also fixed the validation that let it through.',null,'Malformed tax ID in one record crashed list serialization. Fixed record and validation.','A malformed tax ID on one customer record crashed the list view. Corrected the record and fixed the input validation.',25),
(15,'june@example.com','Duplicate invoice numbers','Two invoices this week got the same number, INV-1042. Our accountant noticed.','bug','urgent','resolved','ben.agent@example.com','June, two invoices created within the same second could receive the same number. We fixed the numbering to be assigned by the database. I renumbered the second invoice to INV-1043.','Thank you, that is a relief.','Race in number assignment. Moved to DB sequence.','Invoice numbers were assigned in application code and two simultaneous creates collided. Numbering now uses a database sequence; the duplicate was renumbered.',20),
(16,'kai@example.com','Attachments missing from sent invoices','Clients say the invoice emails arrive without the PDF attached.','bug','high','open',null,null,null,null,null,1),
(17,'dana@example.com','Invoice list is very slow','The invoices page takes 10 seconds or more to load now. We have about 30,000 invoices.','performance','high','resolved','cleo.agent@example.com','Dana, the invoice list was sorting all 30,000 invoices on every load. We added an index for your filter and sort, and the page now loads in under a second.','Much faster, thank you.','Missing composite index on (workspace, status, created_at). Added.','Invoice list did a full scan and sort on every load. A composite index on the filter and sort columns brought it under a second.',60),
(18,'eli@example.com','Search takes forever','Searching for a customer name in the search box takes about 8 seconds.','performance','normal','resolved','ava.agent@example.com','Eli, name search was using a pattern match that could not use an index. We switched it to full-text search and it now returns in a fraction of a second.',null,'ILIKE ''%term%'' cannot use btree. Moved to tsvector + GIN.','Customer search used a leading-wildcard pattern match that cannot use an index. Switched to full-text search with a GIN index.',48),
(19,'faye@example.com','Reports page times out','The yearly revenue report fails with a timeout error.','performance','high','resolved','ben.agent@example.com','Faye, the yearly report recalculated every invoice on each request. It now uses a nightly summary table and loads instantly.','Works now.',null,'Yearly report recomputed every invoice per request and hit the statement timeout. Moved to a nightly summary table.',40),
(20,'gus@example.com','App is slow only for my team members','I see normal speed, but my staff say every page is slow when they log in.','performance','normal','resolved','cleo.agent@example.com','Gus, staff accounts were checked against a permissions rule that ran once for every row on each page. We changed it to run once per request and staff pages are now as fast as yours.','Team confirms it is fast now.','Per-row permission lookup in policy. Wrapped in subselect so it runs once per statement.','A permission check ran once per row for staff accounts. Rewriting it to run once per request made staff pages as fast as the owner''s.',28),
(21,'hana@example.com','Mobile app slow to open invoices','Opening an invoice on the phone takes several seconds; on the laptop it is instant.','performance','low','pending','ava.agent@example.com','Hana, could you tell me which phone and app version you use? It is under Settings > About in the app.',null,null,null,3),
(22,'ivo@example.com','Webhook not firing for paid invoices','We set up a webhook for invoice.paid but our server never receives anything.','integration','high','resolved','ben.agent@example.com','Ivo, your endpoint returned a certificate error, so our deliveries failed. Once the certificate on your server was renewed, the retries went through.','Renewed the cert, deliveries arriving.','Endpoint TLS cert expired; our deliveries logged SSL errors.','Webhook deliveries failed because the receiving server''s TLS certificate had expired. Renewing it let the queued retries succeed.',55),
(23,'june@example.com','API returns 401 with a new key','I created a new API key and every request gets 401 Unauthorized.','integration','high','resolved','cleo.agent@example.com','June, the key is sent in the Authorization header but without the "Bearer " prefix. Adding the prefix fixes it.','Yes, that fixed it.',null,'API requests returned 401 because the key was sent without the "Bearer " prefix in the Authorization header.',33),
(24,'kai@example.com','Accounting sync duplicates payments','Every payment shows up twice in our accounting software after the sync runs.','integration','normal','resolved','ava.agent@example.com','Kai, the sync was connected twice, once from each of your two admin accounts. I disconnected the second connection and removed the duplicate entries.',null,'Two OAuth connections to the same ledger. Removed one.','Payments synced twice because two admins had each connected the accounting integration. Removed one connection and the duplicates.',22),
(25,'dana@example.com','API rate limit errors during import','Our nightly import script gets 429 errors after a few hundred requests.','integration','normal','resolved','ben.agent@example.com','Dana, the API allows 100 requests per minute per key. Please use the batch endpoint, which accepts up to 500 invoices per request, and back off when you see a 429.','Batch endpoint works, thanks.',null,'Import hit the 100 requests per minute limit. Switched to the batch endpoint (500 per request) with backoff on 429.',18),
(26,'eli@example.com','Zapier trigger stopped working','Our Zap that creates a task for each new invoice stopped firing last week.','integration','normal','open',null,null,null,null,null,4),
(27,'faye@example.com','How do I add my logo to invoices?','I would like my company logo at the top of every invoice.','how_to','low','resolved','cleo.agent@example.com','Faye, go to Settings > Branding and upload a PNG or SVG. It will appear on all new invoices and PDFs.','Done, looks great.',null,'Logo is set under Settings > Branding (PNG or SVG) and applies to new invoices and PDFs.',75),
(28,'gus@example.com','Can I set up recurring invoices?','I bill some clients the same amount every month. Can the app send these automatically?','how_to','low','resolved','ava.agent@example.com','Gus, yes. Open the invoice, choose Make recurring, pick the schedule, and it will be sent automatically. This needs the Growth plan or above.',null,null,'Recurring invoices: open an invoice, choose Make recurring, set the schedule. Requires Growth plan or above.',62),
(29,'hana@example.com','How do I give my accountant access?','My accountant needs to see invoices and reports but should not be able to change anything.','how_to','normal','resolved','ben.agent@example.com','Hana, invite them under Settings > Team and choose the Viewer role. Viewers can see and export everything but cannot edit.','Perfect.',null,'Invite the accountant under Settings > Team with the Viewer role (read and export only).',47),
(30,'ivo@example.com','How to apply a discount to one line?','I want a 10 percent discount on a single line item, not the whole invoice.','how_to','low','resolved','cleo.agent@example.com','Ivo, click the line item, open More options, and enter the discount there. Invoice-wide discounts are set at the bottom instead.',null,null,'Per-line discounts are under the line item''s More options; invoice-wide discounts are at the bottom of the invoice.',36),
(31,'june@example.com','How to send payment reminders automatically?','Some clients forget to pay. Can reminders go out on their own?','how_to','normal','resolved','ava.agent@example.com','June, turn on Settings > Reminders and choose when they go out, for example 3 days before and 7 days after the due date.','Turned on, thanks.',null,'Automatic payment reminders are enabled under Settings > Reminders with configurable timing around the due date.',15),
(32,'kai@example.com','Export all invoices to a spreadsheet','Our auditor wants every invoice from last year in a spreadsheet.','how_to','normal','pending','ben.agent@example.com','Kai, go to Invoices, filter by last year, and choose Export > CSV. Do you also need line items, or just invoice totals?',null,null,null,2),
(33,'dana@example.com','Feature request: multiple currencies','We started billing clients in euros. Is multi-currency on the roadmap?','other','low','resolved','cleo.agent@example.com','Dana, multi-currency is available today on the Growth plan: set the currency per client under the client''s settings.','Great, found it.',null,'Multi-currency is available on Growth: set the currency on each client.',52),
(34,'eli@example.com','Do you have a data processing agreement?','Our legal team needs a signed data processing agreement before we can continue.','other','normal','resolved','ava.agent@example.com','Eli, you can download and countersign our standard agreement under Settings > Legal. If your team needs changes, reply here and I will route it.',null,'Routed to legal queue template.','The standard data processing agreement is downloadable under Settings > Legal; custom terms are routed to the legal team.',44),
(35,'faye@example.com','Is there a dark mode?','The bright screen is hard on my eyes in the evening.','other','low','open',null,null,null,null,null,5),
(36,'gus@example.com','Invoice emails going to spam','Several clients found our invoice emails in their spam folder.','other','high','resolved','ben.agent@example.com','Gus, your custom sending domain was missing the DKIM record. Once you add the record shown under Settings > Email, deliverability should recover.','Added the record, clients are getting them now.','DKIM missing on custom domain.','Invoice emails landed in spam because the custom sending domain had no DKIM record. Adding it fixed deliverability.',12),
(37,'hana@example.com','Password reset link says expired','I clicked the reset link straight away and it says the link has expired.','account','high','resolved','cleo.agent@example.com','Hana, your email security scanner opens links before you do, which uses up the one-time link. I sent a reset code instead, which you can type in.','The code worked.','Link prefetch by mail scanner consumed OTP.','The mail security scanner pre-opened the one-time reset link, consuming it. Sent a typed reset code instead.',9),
(38,'ivo@example.com','Slow page when filtering invoices by client','Filtering the invoice list by a client name takes much longer than the unfiltered list.','performance','normal','open',null,null,null,null,null,1),
(39,'june@example.com','Webhook signatures do not verify','The signature header on your webhooks never matches what we compute.','integration','high','resolved','ben.agent@example.com','June, the signature is computed over the raw request body. Your framework parses JSON first and re-serializes it, which changes the bytes. Verify against the raw body.','Using the raw body fixed it.',null,'Webhook signature mismatch because the receiver verified a re-serialized JSON body. Verifying against the raw request body fixed it.',7),
(40,'kai@example.com','Two-factor setup QR code will not scan','The QR code on the two-factor setup page will not scan in my authenticator app.','account','normal','resolved','ava.agent@example.com','Kai, use the "enter key manually" link under the QR code and type the setup key into your app. Some apps struggle with the QR on high-contrast mode.','Manual key worked.',null,'QR code would not scan with high-contrast mode on; entering the setup key manually worked.',5);

-- Category and priority are as a human agent set them. Embeddings are not seeded:
-- run `npm run embed:backfill` (calls the triage Edge Function) after a reset.
insert into public.tickets (customer_id, subject, body, status, category, priority, assignee_id, resolution, created_at, updated_at)
select
  cu.id, s.subject, s.body, s.status, s.category, s.priority, ag.id, s.resolution,
  now() - make_interval(days => s.age_days),
  now() - make_interval(days => s.age_days)
from seed_tickets s
join auth.users cu on cu.email = s.customer
left join auth.users ag on ag.email = s.agent
order by s.n;

-- Conversation: agent reply, optional customer follow-up, optional internal note.
insert into public.messages (ticket_id, author_id, body, is_internal, created_at)
select t.id, ag.id, s.agent_reply, false, t.created_at + interval '2 hours'
from seed_tickets s
join public.tickets t on t.subject = s.subject
join auth.users ag on ag.email = s.agent
where s.agent_reply is not null
union all
select t.id, t.customer_id, s.customer_followup, false, t.created_at + interval '5 hours'
from seed_tickets s
join public.tickets t on t.subject = s.subject
where s.customer_followup is not null
union all
select t.id, ag.id, s.internal_note, true, t.created_at + interval '3 hours'
from seed_tickets s
join public.tickets t on t.subject = s.subject
join auth.users ag on ag.email = s.agent
where s.internal_note is not null;
