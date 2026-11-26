> **SUPERSEDED by T31a (2026-11-26): do NOT do section A below.** Centres no longer pay through Stripe (they are invoiced by TutorDeck and pay by PayNow), so the S$0.50 centre price in Stripe is **no longer needed**, in the sandbox or in LIVE. The solo prices (`solo_pro_monthly`, `solo_pro_yearly`) are unchanged. Only section B (the DEV database step, `db/migration_fee_050.sql`) still applies, and the "price_mismatch" check in section C no longer exists (the monthly job does not call Stripe). The text below is kept for history.

# T30 — Stripe: replace the per-student price S$0.40 with S$0.50 (owner steps)

Why: TutorDeck's centre fee is now **S$100 + S$0.50 × billable students**. A Stripe price can't be edited, so you create a NEW price at S$0.50, give it the lookup key `centre_student_monthly`, and retire the old one. Until Stripe and the database agree, the monthly job (`api/billing-cron.js`) refuses to touch a centre (`price_mismatch`) — it never bills a wrong amount.

Do **SANDBOX first** (top-left toggle "Sandbox" / test mode on), then the same in **LIVE** mode when you go live. Don't mix them up: a price made in one mode doesn't exist in the other.

Order matters: do the Stripe steps (A) and the DEV database step (B) in the same sitting, so the two agree.

## A. Stripe dashboard

1. Open https://dashboard.stripe.com and check the mode switch (sandbox "TutorDeck sandbox" for the first pass).
2. **Product catalogue** (left menu) → open the product that holds the per-student price (the one with price lookup key `centre_student_monthly`; the name is usually "TutorDeck centre — per student").
3. Find the current price **S$0.40 / month** (it shows the lookup key `centre_student_monthly`). Click it. Click **⋯ (More) → Edit lookup key** and **change the key** to `centre_student_monthly_old_040` → Save. (Stripe lets a lookup key sit on only one active price, so free it first. Do NOT delete or archive yet.)
4. Back on the product page click **Add another price**:
   - Pricing model: **Standard pricing**
   - Price: **0.50**, currency **SGD**
   - Billing period: **Recurring → Monthly**
   - Usage type: **Licensed** (same as the old price: the job sets the quantity)
   - Under **More options** → **Lookup key**: type exactly `centre_student_monthly`
   - Tax behaviour: leave **Unspecified/exclusive** the same as the old price (TutorDeck isn't GST-registered; Stripe Tax stays off).
   - Click **Add price**.
5. Open the new price and check: **S$0.50 SGD / month**, lookup key `centre_student_monthly`.
6. **Existing centre subscriptions** (created by hand, see CLAUDE.md go-live item "Centre fee job"): open **Subscriptions** → the centre's subscription → **⋯ → Update subscription**. On the line "centre_student_monthly" click **⋯ → Replace/Change price**, choose the new S$0.50 price, **keep the quantity as it is**, set **Proration: none / do not prorate**, and confirm. (Do this after the 1st of the month's job has run and before the next 00:30 SGT run, i.e. any mid-month day; never on the 1st.) A new centre subscription simply uses the S$0.50 price from the start.
7. Only once no subscription uses the old price: open the old S$0.40 price → **⋯ → Archive price**.
8. LIVE mode, later: repeat the whole thing, but there is nothing to replace — just **create the price at S$0.50 with lookup key `centre_student_monthly`** when you recreate the LIVE products (CLAUDE.md go-live checklist). Never create the LIVE price at S$0.40.

## B. Database (DEV first)

1. Supabase → project **DEV** (`tuzxsqkfzrjssnpcoale`, dummy data) → SQL editor → New query.
2. Paste the whole content of `db/migration_fee_050.sql` and **Run**. It is safe to run twice.
3. Check it (should show `50` for the old-default centres and any custom price unchanged):
   ```sql
   select o.trading_name, p.base_cents, p.per_student_cents
   from org_plans p join organisations o on o.id = p.org_id
   where p.plan_code = 'centre' order by 1;
   ```
4. LIVE database: **not yet** (no centre plans exist there). Run `migration_fee_050.sql` on LIVE together with the other org/billing migrations at the moment of shipping (CLAUDE.md go-live checklist), after showing the SELECT above and a yes.

## C. Check the two agree

1. Deploy preview on DEV sign in as the demo centre owner → **Organisation → Plan**: it must read "S$100.00 a month + S$0.50 per billable student" with examples "98 students → 100 billable → S$150.00 · 250 students → 250 billable → S$225.00 · 405 students → 410 billable → S$305.00".
2. Dry run of the job (sandbox only): open `/api/billing-cron?dry=1` with the `CRON_SECRET` bearer header. A centre must show `dry:would_update` or `already_correct`, not `skipped:price_mismatch`. If you see `price_mismatch`, the Stripe price (A) or the stored plan (B) is not yet 50c.

## Undo

Stripe: put the lookup key back by moving `centre_student_monthly` to the old S$0.40 price (steps 3–4 in reverse). Database: run `db/migration_fee_050_down.sql`.
