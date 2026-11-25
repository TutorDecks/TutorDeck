# T7 plan: transactional email through Brevo

Branch `claude/t7-plan`. Plan only: no product code, no SQL, no Brevo/Supabase changes. Written 2026-11-25 from the code (CLAUDE.md, README, `assets/js/org.js`, `login.html`, `reset.html`, `assets/js/password-rules.js`, `db/migration_org_foundation.sql`, `api/*`).

## Summary
- Owner decided: **Brevo**, sender **noreply@tutordeck.com.sg**. The domain is already authenticated in Brevo; the sender entry for that address does not exist yet (step 0 below).
- Two separate jobs, shipped separately:
  1. **Supabase auth emails** (confirm sign-up, reset password, magic link) go out through Brevo's SMTP. This is **settings only, no code**, done by the owner on both Supabase projects (DEV first).
  2. **Tutor/staff invite email**: a new server function `api/send-invite.js` calls Brevo's transactional API after `org_invite` succeeds. Needs code, one small migration, tests.
- Recommended invite link: **reuse `/reset` with a "welcome" variant**, with the link made by Supabase's own recovery flow (not `inviteUserByEmail`). Reason: no account has to exist before the invite, and "already has an account" needs no special case.
- Today nothing sends email except Supabase's built-in sender (rate-limited, testing only). `org.js` says "Invite emails come with the email provider (coming soon)".
- Two gaps found in the code that this plan must fix, otherwise invites do not work end to end: (a) `org_claim_invites()` is only called on the `/org` page, so an invited tutor who goes straight to `/tutor` is never linked; (b) `reset.html` accepts any password of 6+ characters and ignores `password-rules.js`, so the new-password page is weaker than sign-up and Supabase's rules.
- Reminders and remarks emails are out of scope; section 3 lists what they need.
- Needs from the owner: 5 decisions at the bottom.

## 0. Brevo account, owner does once (the connector can't)
1. Brevo → Senders, domains & dedicated IPs → **Senders** → add `noreply@tutordeck.com.sg`, name **TutorDeck**. Brevo sends a verification email to that address, so the mailbox must receive mail (or Brevo shows the DNS path for domain-authenticated senders; the domain is already verified, so adding the sender should activate at once).
2. Add a real **reply-to** the owner reads (e.g. support@ or the owner's own address) in each email, because noreply@ is not read.
3. Brevo → SMTP & API → **SMTP** tab: copy the SMTP login. Create **one SMTP key** named `supabase-dev` and a second named `supabase-live`. Then **API keys**: create `tutordeck-api-dev` and `tutordeck-api-live` (two keys, so a leaked preview key can't send as production). Never paste any of these in chat or in a file.
4. Check the plan's daily send limit (free Brevo is about 300 emails/day, which covers launch; it also adds a "Sent with Brevo" footer on the free plan, so decide whether that is acceptable for auth emails).

## 1. Supabase auth emails via Brevo SMTP (both projects)
Do **DEV (`tuzxsqkfzrjssnpcoale`) first**, test, then **LIVE (`rnjvswkejbrhbaytutai`)**. LIVE has real users; do it at a quiet hour, and keep the old setting noted so it can be reverted.

Owner steps in Supabase (per project) → **Authentication → Emails → SMTP Settings** → turn on Custom SMTP:
| Field | Value |
|---|---|
| Sender email | `noreply@tutordeck.com.sg` |
| Sender name | `TutorDeck` |
| Host | `smtp-relay.brevo.com` (Brevo shows it on its SMTP tab; confirm there) |
| Port | `587` |
| Username | the SMTP login Brevo shows (not the account email password) |
| Password | the SMTP key from step 0.3. **The owner types it into Supabase themselves.** |

Then:
- **Rate limits** (Authentication → Rate Limits): once custom SMTP is on, Supabase raises the email cap from its tiny built-in default. Set to something sane, e.g. 30 per hour on DEV and 60 per hour on LIVE (sign-ups + resets). Keep the bot check (Turnstile) on LIVE; it is what protects the Brevo daily quota.
- **Templates** (Authentication → Emails → Templates): edit **Confirm signup**, **Reset password**, **Magic link** (and **Change email**, **Invite user** for completeness). Wording rules: subject starts with "TutorDeck", plain words, one teal button, no logo hosting needed (text header "TutorDeck" in ink #13233F, button teal #0F766E, ground #FAF9F6, Manrope with Arial fallback because email clients ignore web fonts). Suggested subjects: "Confirm your TutorDeck account", "Reset your TutorDeck password", "Your TutorDeck sign-in link". Body = one sentence + button using `{{ .ConfirmationURL }}` + "If you didn't ask for this, ignore this email." + reply-to line. Keep the same HTML on both projects (copy/paste), because there is no per-project difference.
- **Redirect URLs** (Authentication → URL Configuration): Site URL `https://www.tutordeck.com.sg` (LIVE) / the dev preview URL (DEV). Allow-list on LIVE: `https://www.tutordeck.com.sg/**`, `https://tutordeck.com.sg/**`, `https://tutordeck.vercel.app/**`. On DEV add the Vercel preview pattern (`https://*-tutordecks.vercel.app/**`, check the team slug in Vercel). The code uses `/confirmed` (sign-up), `/reset` (password) and `/home`.
- **Sender reputation**: SPF, DKIM and DMARC are already set for the domain (the orchestrator confirmed DNS). Add a DMARC policy of `p=none` with a report address if there isn't one yet, and tighten later.
- **Test** (DEV): sign up with a new address → email arrives from "TutorDeck <noreply@tutordeck.com.sg>", not spam → link lands on `/confirmed`. Forgot password → link lands on `/reset`. Check Brevo → Transactional → Logs shows the three sends. Then repeat once on LIVE with the owner's own address.
- Side effect to tell the owner: with working SMTP, "Confirm email" can be turned **on** on DEV (README says it is off there so previews work).

What exists vs must be built: Supabase calls already exist in `login.html` (`signUp` with `emailRedirectTo`, `resetPasswordForEmail`). **Nothing to build** here except fixing `reset.html` password rules (step B1 below).

## 2. Tutor / staff invite email

### What exists
- `org_invite(org, email, name, role, perms, employment)` (owner only) inserts a `memberships` row with `status='invited'`, `user_id` null; refuses a second invite of the same email in the same org.
- `org_claim_invites()` links a confirmed email to its pending rows. It is only called in `org.js` `init()`. `detectRole()` and `/tutor` never call it.
- No email is sent. `org.js` line 326 shows "coming soon".

### What must be built
1. **`api/send-invite.js`** (Vercel function, same pattern as `api/billing.js`: bearer token → `L.getUser` → check **the caller is owner of that org** using the user's own token so row-level security applies, as `billing.js` already does). POST `{ membership_id }`. It never accepts an email address from the browser: it reads the membership row (email, name, role, org name) itself, so the endpoint cannot be used to mail arbitrary addresses.
2. Called by `org.js` right after `org_invite` returns the new id (fire and forget with a visible result: "Invite emailed to x" or "Saved, but the email didn't send. [Resend]").
3. **The link.** Server creates a recovery link for the invited email with Supabase's Auth admin API (`generate_link`, type `recovery`; needs `SUPABASE_SERVICE_ROLE_KEY`, already a server-side env var for billing/delete-account) and puts that URL in the Brevo email. If no account exists yet, the function first creates the user (admin `create user`, email confirmed, random password nobody knows) so the recovery link works. Redirect target: `/reset?welcome=1`.
4. **Brevo call**: `POST https://api.brevo.com/v3/smtp/email` with header `api-key` from `process.env.BREVO_API_KEY`, `sender {name: "TutorDeck", email: "noreply@tutordeck.com.sg"}`, `replyTo`, `to`, and either `templateId` + `params` (editable in Brevo) or inline HTML. Recommend **a Brevo template** (the connector can create and preview it; the owner can edit wording without a deploy), params: `name`, `centre`, `role`, `inviter`, `link`, `expiry`.
5. **What the email says** (plain words):
   Subject: "{{inviter}} invited you to {{centre}} on TutorDeck"
   Body: "Hi {{name}}, {{inviter}} has added you as a {{role}} at {{centre}}. Tap the button to choose a password and see your lessons." [Set my password] "This link works once and expires in 24 hours. If it has expired, ask {{inviter}} to resend. Not expecting this? Ignore this email."
   Never include students, fees, or any data in the email.

### Landing page: compare and recommend
| Option | How | Good | Bad |
|---|---|---|---|
| **A. `/reset?welcome=1` (recommended)** | recovery link, same page, welcome wording ("Welcome to {centre}. Choose a password.") | one page for both new and existing accounts; no second flow to test; works when the person already has an account (they just pick a new password or ignore the mail and sign in) | recovery tokens expire fast (default 1 h; raise to 24 h in Supabase → Auth → Sessions/email OTP expiry, max 24 h) |
| B. Supabase `inviteUserByEmail` | Supabase's own Invite email and link | built-in | fails (error) if the user already exists; uses Supabase's template, not Brevo's; two code paths |
Recommend **A**. On success the page says "Password set. Taking you to your lessons" and goes to `/home` (Home already sends tutor-only logins to `/tutor`) instead of "Go to sign in", because the recovery session is already a signed-in session.
- **Password rules**: `reset.html` must load `assets/js/password-rules.js` and use `PasswordRules.problems()` (8+ characters, lower, upper, number, symbol) with the same "Still needed" wording as `login.html`, plus the known-breach check `login.html` already does (`pwnedCount`). Today it only checks 6 characters, so Supabase would reject some choices with a generic error. Welcome and reset share this code.
- **Linking to the centre**: after the session exists, the page (and also `TL.requireAuth` for every page) calls `org_claim_invites()`. The email must match: Supabase gives a confirmed email because the link itself proves the mailbox.
- **Already has an account**: the same email is claimed by `org_claim_invites` on any sign-in. The invite email still goes out with the same link; the page works either way. If they ignore the link and just sign in, they are still linked. A tutor who is also a solo tutor ends up in "both" mode (existing behaviour).
- **Different email on sign-in**: if the person signs up with another address, nothing is linked (by design: email proves identity). Owner fixes by re-inviting the right address.
- **Resend / expire**: a **Resend** button on an `invited` row in the people list (owner only). Rules: a new link every time (old ones are invalidated by Supabase when a new one is issued), at most **1 resend per 10 minutes and 5 per day per invite** (counted in a small table, see section 5), link valid 24 h, the invite row itself does not expire but the owner can cancel it (existing "Off" toggle; `status='disabled'` rows are not emailed and are not claimed).
- **Security**
  - `BREVO_API_KEY` only as a Vercel env var set by the owner. Production = live key, Preview = DEV key (two separate keys, same variable name; same split the billing checklist already requires). The function **refuses with 503 if the variable is missing**, never falls back to anything.
  - Preview/DEV uses `SUPABASE_URL` DEV values (existing rule), and the DEV Brevo key. To avoid mailing real people from a preview, in non-production the function sends only to addresses ending in `@tutordeck.com.sg` or on an allow-list env var `INVITE_TEST_ALLOW` (non-secret), otherwise it logs "skipped (preview)" and returns ok. (Decision 4.)
  - No secrets in code, logs or the audit log; log only the membership id and Brevo's message id. Do not echo the recovery link in logs or in the API response.
  - Owner-only check uses the caller's token (row-level security), then service role only to create the link.
  - Rate limit per owner (5 invites/min) and per org (resends above) so a hijacked owner session cannot spam.
  - Brevo "from" is fixed in code; the browser cannot choose it.
  - Footer: "TutorDeck Pte. Ltd., Singapore" and a plain-words "why you got this" line (PDPA).

## 3. Later (not now): what each needs
- **Missed-remarks reminders to tutors** (`remarks.required`, `remarks.deadline_hours`): a daily job like `api/billing-cron.js` (add a second `vercel.json` cron, `CRON_SECRET`), a query "lessons marked attended with no remark past the deadline, per tutor, not yet reminded", a `reminders_sent` log table (dedupe), a Brevo template, and the centre's setting that turns it on (`soon` option in the wizard flips to live). Tutors need an email on file (invite email is stored on `memberships`).
- **Remarks to parents**: guardian email addresses (`guardians` table exists), a per-centre consent/opt-out, a send queue, unsubscribe link, and a centre-chosen "send automatically vs staff approves first" setting (product principle: the centre decides). Needs Brevo transactional **events/webhook** (delivered, bounced, spam) to a signed `api/brevo-webhook.js`.
- **Invoice emails to parents** is a different task (T4); the same `api/_brevo-lib.js` helper should be reused.

## 4. What the Brevo connector (orchestrator chat) can do vs the owner
| Connector can (after naming the account and getting a yes) | Owner must do |
|---|---|
| Read the sender and domain list (`senders_get_senders`, `domains_get_domains`) to confirm step 0 done | Create/verify the `noreply@` sender; click Brevo's verification email |
| Create the **invite template** as a draft, preview it, send a **test** to named addresses | Create SMTP keys and API keys; paste the SMTP key into Supabase; set `BREVO_API_KEY` in Vercel (Production and Preview, different keys) |
| Read send logs/stats to confirm deliveries | Edit Supabase SMTP, rate limits, templates, redirect URLs (on DEV and LIVE) |
| Build the HTML for the three Supabase auth templates for copy/paste | Decide the sender footer/plan (free plan adds a Brevo footer), approve first LIVE send |
| Never: see API or SMTP keys, change Supabase or Vercel settings | Raise the Supabase OTP/link expiry to 24 h |

## 5. Database and tests (database first)
Migration `db/migration_invite_email.sql` (apply to DEV first; LIVE only when shipping to main, after `org_foundation`):
- `org_invite_mail_log(id, membership_id references memberships on delete cascade, org_id, sent_at, brevo_message_id, status)`, RLS on, **no policies for anyone** (only the server function with the service role reads/writes). `on delete cascade`, so `org_delete_solo` and account deletion stay covered by the existing rule for `org_id` tables.
- `org_invite_mail_allowed(membership_id)` returning true/false (owner only, `security definer`, pinned search_path): membership is `invited`, not disabled, last mail > 10 minutes ago, fewer than 5 today. The function calls it with the **user's** token so the rule is enforced in SQL, not only in JS.
- Make `org_claim_invites()` callable from `TL.requireAuth` (no change to the function; it is already safe and idempotent), and confirm it is **granted to `authenticated`** after `function_lockdown`.
- Optionally `org_resend_invite(membership_id)` instead of re-calling `org_invite` (which refuses a duplicate with "Already invited").
Tests (per case, `bash tests/sql/run.sh` plus Node unit tests for pure code):
- SQL: owner may; staff/tutor/other-org owner/anonymous may not; disabled invite blocked; 2nd mail within 10 min blocked; 6th mail in a day blocked; claim works after confirmed email, **does not** claim for an unconfirmed email or a different email; claim skips a membership already held; cascade delete cleans the log.
- Node (`tests/invite-email.test.js`): request builder produces the Brevo body with fixed sender and no secret; missing `BREVO_API_KEY` → 503; non-owner → 403; unknown membership → 404; preview host with a non-allowed address → skipped; recovery link never appears in the response or log lines; Brevo 4xx/5xx → clear error and the invite row remains.
- `tests/password-rules.test.js` extended for the `reset.html` use; browser check that `/reset?welcome=1` shows the welcome wording and the same rule list as sign-up.

## 6. Small shippable steps (each: done means, owner click-through)
| # | Step | Done means | Owner click-through |
|---|---|---|---|
| E0 | Owner creates the sender + keys (section 0) | Sender shows "Verified" in Brevo | Brevo → Senders shows noreply@tutordeck.com.sg verified |
| E1 | DEV Supabase SMTP + 3 templates (section 1) | Mail from "TutorDeck" arrives for sign-up and reset on DEV | Sign up a test address on the dev preview; open the email; link works |
| E2 | `reset.html` uses `password-rules.js` + pwned check; keeps `/reset` behaviour | Weak passwords refused with the same "Still needed" list as sign-up | Request a reset on DEV, try `abc123` (refused), then a good one (works) |
| E3 | LIVE Supabase SMTP + templates (owner, quiet hour) | One real reset email from the owner's own account | Forgot password on www.tutordeck.com.sg with the owner's email |
| E4 | Migration `invite_email` on DEV + SQL tests | `tests/sql/run.sh` green incl. new cases | none (developer) |
| E5 | `api/send-invite.js`, Brevo template, `BREVO_API_KEY` (Preview=DEV key); `org.js` sends after invite; claim in `requireAuth`; Resend button; `/reset?welcome=1` | Invite to a test address emails once; link → set password → lands on My lessons | On the dev preview as the demo centre owner: invite your own second email as a tutor → open email → set password → you see "My lessons" |
| E6 | Ship: run migration on LIVE (SELECT preview, explicit yes), set LIVE `BREVO_API_KEY` + `SUPABASE_SERVICE_ROLE_KEY`, then dev → main PR when the owner says ship | Production invite works | Invite a real second address once |
Order: E0 → E1 → E2 (can ship alone) → E3; E4/E5 can run in parallel with E3. E6 only after the centre menu work (T12) puts the people list in front of owners.

## 7. Risks and decisions for the owner
1. **Landing page: reuse `/reset?welcome=1` with a Supabase recovery link (recommended) or Supabase's own invite link?** Recommendation: reuse `/reset`; it covers "already has an account" with no extra flow.
2. **Link life: raise Supabase's email-link expiry to 24 h (recommended) or keep 1 h?** An invite opened the next morning would otherwise fail; 24 h is Supabase's maximum. Resend covers the rest.
3. **Brevo plan:** the free plan puts a Brevo footer on emails and caps about 300/day. Recommendation: start free for launch, upgrade (about US$9/month, no footer) before the first centre with 400 students goes live.
4. **Preview safety:** previews only email `@tutordeck.com.sg` addresses and an allow-list (recommended), or send to anyone using the DEV key? Recommendation: allow-list; a demo invite to a real parent/tutor from a test deploy would be embarrassing.
5. **Who is the reply-to** (a monitored address) and whether the centre's own name should appear as the sender display name ("Alpha Tuition via TutorDeck <noreply@tutordeck.com.sg>"). Recommendation: yes, centre name in the display name, address stays fixed.

Risk notes: LIVE SMTP switch is the only step that touches real users; do it on DEV first and keep the old setting noted. Bounced/typo invite addresses are silent until Brevo webhooks exist (section 3), so the people list shows "Invited" with the **Resend** button, and the owner can fix the address by re-inviting. A Gmail sender entry already in Brevo is unrelated and must not be used as the From address.
