# T7 owner steps: email through Brevo (E0, E1, E3 and the settings for the invite email)

For Raphael. These are dashboard clicks only; nothing here needs code. **Never paste a key into chat, into a file, or into GitHub.** Type or paste each key only into the box named below, then close the page. Brevo and Supabase rename menu items now and then: if a name below is slightly different, pick the closest one.

Order: **A** (Brevo) → **B** (DEV Supabase) → **C** (Vercel, Preview) → test on DEV → **D** (LIVE Supabase, quiet hour) → **E** (Vercel, Production) → **F** (invite email, after the T7.2 branch is on `dev`).
Files to paste from: `docs/orchestrator/t7/` (the three Supabase auth emails and the optional Brevo invite template).

## A. Brevo (once)

1. Sign in at brevo.com with the TutorDeck account. Top right: the account name → check it says the TutorDeck account (not a personal one).
2. **Senders, domains & dedicated IPs** (left menu or the account menu) → **Senders** → **Add a sender**. Name `TutorDeck`, email `noreply@tutordeck.com.sg` → Save. The domain is already authenticated, so it should show as active at once. If Brevo emails a code to that address, read it from the mailbox that receives mail for `tutordeck.com.sg`.
3. Same page → **Domains**: `tutordeck.com.sg` should show **Authenticated** (SPF, DKIM) and DMARC. If DMARC says "not found", add the record Brevo shows (policy `p=none` is fine for now).
4. Top right account menu → **SMTP & API**.
   - **SMTP** tab: note the **SMTP server** (`smtp-relay.brevo.com`), **Port** (`587`) and **Login** (a long address like `xxxx@smtp-brevo.com`; this is not a secret). Click **Generate a new SMTP key**, name it `supabase-dev`, **copy it once**, keep the tab open. Later repeat for `supabase-live`.
   - **API keys** tab → **Generate a new API key**, name `tutordeck-api-dev`. Do the same for `tutordeck-api-live`. Two keys on purpose: a leaked preview key can't send as production.
5. Check the plan: **free = about 300 emails a day and a "Sent with Brevo" footer** on every email, auth emails included. Fine for launch. Upgrade (about US$9 a month, no footer) before the first big centre goes live.

## B. DEV Supabase (project `tuzxsqkfzrjssnpcoale`): SMTP, emails, links

Supabase dashboard → project `tuzxsqkfzrjssnpcoale` (the dummy-data one; check the name at the top).

1. **Authentication → Emails → SMTP Settings** → turn on **Enable custom SMTP**:
   - Sender email `noreply@tutordeck.com.sg`
   - Sender name `TutorDeck`
   - Host `smtp-relay.brevo.com`
   - Port `587`
   - Username: the **Login** from Brevo step A4
   - Password: the SMTP key `supabase-dev` (**you** paste it here)
   - **Save**. Supabase may send a test; if it shows an error, re-check the login/key.
2. **Authentication → Rate Limits**: set emails sent per hour to about **30** on DEV (LIVE: 60 later).
3. **Authentication → Emails → Templates**. For each of the three, open the template, set **Subject**, replace **Message body** with the file's HTML (everything below its first comment), **Save**:
   | Template | Subject | File |
   |---|---|---|
   | Confirm signup | Confirm your TutorDeck account | `supabase-confirm-signup.html` |
   | Reset password | Reset your TutorDeck password | `supabase-reset-password.html` |
   | Magic link | Your TutorDeck sign-in link | `supabase-magic-link.html` |
   Leave `{{ .ConfirmationURL }}` exactly as written.
4. **Authentication → URL Configuration**: Site URL = the dev preview address (the Vercel `dev` URL). Redirect URLs must include the preview pattern (`https://*-<your-vercel-team>.vercel.app/**`, check the team name in Vercel) plus the preview's own address. The app uses `/confirmed`, `/reset` and `/home`; **the invite email also lands on `/reset?welcome=1`, which this pattern already covers**.
5. **Link life (24 hours).** Authentication → **Sign In / Providers → Email** (or **Authentication → Emails**, depending on the dashboard version) → **Email OTP expiration** = `86400` seconds (24 h, Supabase's maximum). This is what the invite email's "expires in 24 hours" refers to. Do the same on LIVE in D.
6. Optional on DEV: **Confirm email** can now be switched **on** (README says it was off only because there was no email sender).
7. **Test on DEV:** open the dev preview, sign up with a new address you control → the email comes from "TutorDeck <noreply@tutordeck.com.sg>", is not in spam, the button lands on `/confirmed`. Then "Forgot password" → the link lands on `/reset`: a weak password such as `abc123` is refused with the checklist, a good one works. In Brevo → **Transactional → Logs** you should see both sends.

## C. Vercel, Preview environment (so the invite email works on the dev preview)

Vercel → project `tutordeck` → **Settings → Environment Variables**. For each: type the **Name**, paste the **Value**, choose only the environments listed, **Save**. Then **redeploy** the preview (Deployments → the latest `dev` deployment → ⋯ → Redeploy) because variables are read when a deployment is built.

| Name | Value | Environment | Secret? |
|---|---|---|---|
| `BREVO_API_KEY` | the DEV key `tutordeck-api-dev` | **Preview** only | yes |
| `SUPABASE_URL` | `https://tuzxsqkfzrjssnpcoale.supabase.co` | Preview | no |
| `SUPABASE_SERVICE_ROLE_KEY` | DEV project's service-role key (Supabase → Project Settings → API) | Preview | yes (Sensitive) |
| `INVITE_TEST_ALLOW` | your own test addresses, comma separated, e.g. `me@gmail.com,@mydomain.com` (a leading `@` = a whole domain) | Preview | no |
| `BREVO_INVITE_TEMPLATE_ID` | optional, only if you made the Brevo template (F3) | Preview | no |

The Preview/DEV rule: **a preview only emails `@tutordeck.com.sg` addresses and the `INVITE_TEST_ALLOW` list.** Any other address is saved as an invite but not emailed (the screen says "This test site doesn't email real people"). If `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` already exist for Preview with DEV values (billing uses them), leave them.

## D. LIVE Supabase (project `rnjvswkejbrhbaytutai`), quiet hour, owner's own address first

Same as B, on the LIVE project, with these differences:
- Before changing anything, **write down the current SMTP/template settings** (screenshot) so you can revert.
- SMTP password = the SMTP key `supabase-live`. Rate limit about 60 an hour. **Keep the bot check (Turnstile) on**: it protects the daily Brevo quota.
- Site URL `https://www.tutordeck.com.sg`. Redirect URLs: `https://www.tutordeck.com.sg/**`, `https://tutordeck.com.sg/**`, `https://tutordeck.vercel.app/**`.
- Same three templates; same 24 h OTP expiration.
- **Test once:** "Forgot password" on www.tutordeck.com.sg with your own email → email arrives from TutorDeck → link → set a password that meets the checklist. Brevo → Transactional → Logs shows it.

## E. Vercel, Production (only when invites should work on the live site)

Same table as C, **Production environment**, LIVE values: `BREVO_API_KEY` = `tutordeck-api-live`, `SUPABASE_URL` = `https://rnjvswkejbrhbaytutai.supabase.co`, `SUPABASE_SERVICE_ROLE_KEY` = the LIVE project's key. No `INVITE_TEST_ALLOW` there (it is ignored in Production anyway). These three are also on the billing go-live checklist in CLAUDE.md (they can be set once for both). Do **not** set this until the `invites` migration has been run on LIVE (G).

## F. The invite email (after the T7.2 branch is merged to `dev`)

1. **DEV database:** the migration `db/migration_invites.sql` must be applied to the DEV project (Supabase DEV → SQL editor → paste the file → Run). It only adds one table and two functions. Until it is applied, the people list simply shows no Resend button.
2. Redeploy the dev preview (C). Sign in as the demo centre owner (`db/seed_dev_demo.sql` logins, password in `db/seed_dev_demo.sql`) → Organisation → Users and permissions → **Invite someone** with a `@tutordeck.com.sg` address (or one on your allow-list) → the email arrives → button → choose a password → you land on My lessons.
3. **Optional Brevo template** (lets you edit the wording without a deploy): Brevo → **Transactional → Email templates → New template**, sender `noreply@tutordeck.com.sg`, "Paste your code", paste `docs/orchestrator/t7/invite-email.brevo.html` (below its first comment), set the Subject from that comment, **Save and activate**. Copy the template number into `BREVO_INVITE_TEMPLATE_ID`. Skip it and the server sends the same wording from code.
4. **Resend:** in the people list an invite that is still waiting shows "Invited N days ago", an amber "Link expired, send a new one" after 24 hours, and a **Resend invite** button. Limits: one email per invite per 10 minutes, five per invite per day. Each send is in the audit log (Audit log tab, table `org_invite_mail_log`; it never contains the address or link).

## G. When shipping to `main` (owner says ship)

1. Run `db/migration_invites.sql` on **LIVE** in the Supabase SQL editor **before** the code reaches `main` (it needs `migration_org_foundation.sql` on LIVE first: the org migrations are not on LIVE yet).
2. Set the Production variables in E.
3. Then the usual dev → main PR.

## What I did not do and cannot do for you
Create the Brevo sender or keys, paste any key anywhere, change Supabase or Vercel settings, or send any email. Everything above is yours to click.

## H. Emails to families: invoices, receipts, reminders (T7.3; after the `claude/t7-3-invoice-email` branch is on `dev`)

Nothing is emailed to a family until a **centre** switches it on (Settings > Invoicing > "Email invoices to parents"; default off).
1. **DEV database:** run `db/migration_invoice_email.sql` (after `migration_tutor_moves.sql`). LIVE: only at ship time, before the code reaches `main`.
2. **Vercel variables** (Settings > Environment Variables). Already set for invites/billing: `BREVO_API_KEY` (Production = live key, Preview = DEV key), `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `CRON_SECRET`, `INVITE_TEST_ALLOW` (Preview). **New:**
   | Name | Value | Environment | Secret? |
   |---|---|---|---|
   | `BREVO_WEBHOOK_SECRET` | any random string of 16+ characters | Production and Preview | yes |
   | `EMAIL_LINK_ORIGIN` | optional: `https://www.tutordeck.com.sg` once that domain is live (invoice links in emails point there; default is the address staff used, or tutordeck.vercel.app for the daily job) | Production | no |
   | `EMAIL_PLATFORM_DAILY_CAP` | optional: default 250 (Brevo free = 300 a day for everything). Raise only after upgrading Brevo; never above 300 | Production | no |
3. **Brevo webhook (bounces):** Brevo > Transactional > Settings > Webhooks > Add: URL `https://<site>/api/brevo-webhook?s=<BREVO_WEBHOOK_SECRET>` (or the header `Authorization: Bearer <secret>` if Brevo offers it), events: hard bounce, blocked, invalid email, spam, error. Without it bounces are only seen when Brevo refuses an address at send time.
4. **Daily job:** `vercel.json` runs `/api/email-cron` at 01:00 UTC (09:00 Singapore), production only. Vercel Hobby allows once a day; staff pressing Send, or opening Money > Email, also sends what is queued right away (within the caps). On Pro you can change the schedule to hourly.
5. **Test on DEV:** make a demo centre's guardian email `you@tutordeck.com.sg`, switch email on (staff sends), press **Email invoice** on an invoice, check Money > Email and the send log.
