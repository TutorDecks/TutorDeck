# T18 — Public holidays and make-up credits (investigation + plan)

Branch `claude/t18-plan`. No product code, SQL or deploys. Date: 2026-11-24.

## Summary
- **There is no credit model in the app today.** "A makeup uses a credit", "Makeups per period", "Don't generate lessons on centre holidays", "Warn parents when credits fall to" and "Credits expire after" are saved in the centre settings and **nothing reads them**. Ticking them changes nothing. Three of them are not marked `soon`, so the wizard promises things the app does not do.
- **Answer to "does a postponed lesson + its make-up use 2 credits?"** Today: no credits are used at all. A postponed lesson is the *same lesson moved to a new date*, so it is billed once.
- **Recommended rule:** one lesson owed = one credit. Postponing never costs a second credit; the make-up *fulfils* the same credit. Make it a centre setting.
- **Holidays:** ship a read-only library of Singapore public holidays (2026 + 2027, from MOM), centres tick which to add. Nothing is auto-applied. Then make lesson generation actually skip holidays.
- Recommended order: (1) honesty fix (`soon` flags + help text), (2) holiday library, (3) holidays skip lessons, (4) credits ledger. Details below.

## 1. What the code does today
**Postpone (solo and centre, Calendar).** `calendar.js` `savePostpone` (~l.833) updates the *same* lessons row: new date/time, `postponed=true`. `slot_date` keeps the original slot date so no phantom "not logged" lesson appears (`calendar.js` ~l.163). Amount is recalculated only for a change in duration. Nothing is created, nothing is credited. "Revert to slot" undoes it.
**Cancel / absent (Ledger).** `ledger.js` ~l.622: status `cancelled`, billable amount = `compensation` (0 = family not charged, null = charge pending). For centres, tutors/admins mark this (CLAUDE.md: attendance + compensation rules). The cancelled lesson is **not linked** to any replacement lesson.
**Make-up lesson.** No such object. If a tutor wants one they add a normal one-off lesson (✦, `one_off=true`), which is billed like any lesson. Nothing connects it to the missed lesson.
**Credits.** Only exist as setting keys in `assets/js/org-settings.js` (l.60–72: `billing.low_balance_credits`, `credit_expiry_days`, `makeups.allowed / per_period / uses_credit`; defaults l.171–172) and `payments.overpayments = credit` (l.116). `org_validate_settings` (`db/migration_org_foundation.sql` l.325) validates none of them. No table of balances, no code in `ledger.js`, `invoices.js`, `money.js` or `api/` reads them. `billing.model = prepaid_packages` is likewise stored but has no packages table.
**Holidays.** Table `holidays` (org_id, optional branch_id, name, starts_on, ends_on; `migration_org_foundation.sql` l.120). The only code is the manual add/remove form in the centre wizard step 2 (`org.js` ~l.263–290). `calendar.skip_holidays` (`org-settings.js` l.47, default on) is read by nobody. Lesson generation (`ledger.js` `generateRange` l.64, Planner, Calendar projection) never looks at holidays. Solo tutors have no holiday screen at all.

So today a holiday lesson is generated like any other, and the tutor must cancel or delete it by hand.

## 2. How credits behave today: worked example
Family pays S$40/lesson. Lesson on Sat 5 Dec is **postponed** to Sat 12 Dec, then taught.
| Step | Lessons billed | "Credits" used |
|---|---|---|
| Postpone 5 Dec to 12 Dec | 1 (same row, moved) | 0 (no credits exist) |
| Taught on 12 Dec | 1, marked done | 0 |
Result: charged once, S$40. If instead 5 Dec is marked **absent** (cancelled) and the tutor adds a separate make-up lesson on 12 Dec: the cancelled one bills its compensation (0 if not charged, else the typed amount) **and** the make-up bills S$40 normally. A parent could be charged twice. This is the real hazard, because the app does not know the two belong together.

## 3. Recommended rule (a centre setting)
**One lesson owed = one credit.** A credit is created when a lesson is *not charged* (absent with notice, tutor cancelled, holiday) and is used up when a make-up is taught. The make-up fulfils the same credit; it never takes a second one.
New setting `billing.makeups.credit_rule` (replaces the bare `uses_credit` toggle, which stays readable for old saves):
| Option | Meaning | Status |
|---|---|---|
| `none` | Make-ups are ordinary extra lessons, billed normally | build first |
| `one_per_missed` (default) | A missed, not-charged lesson earns 1 credit; a make-up spends exactly that credit and is not billed | soon |
| `charged_missed_free_makeup` | Missed lesson stays charged; make-up free | soon |
Also needed: expiry (`credit_expiry_days`, existing key, applies to make-up credits too) and `per_period` as a cap on make-ups taken. Per the product principle, each option is built completely, validated in `org_validate_settings`, with a test per value. **Solo tutors** keep today's behaviour (postpone moves the lesson; no credits), unchanged.
Data: `makeup_credits(id, org_id, student_id, source_lesson_id, created_on, expires_on, used_lesson_id null, status)`. Append-only rows; spending sets `used_lesson_id`. Credit created by the same database function that marks the lesson cancelled with compensation 0.

## 4. In-app wording (exact text)
- Setting label: **"When a lesson is missed and not charged"**. Help: *"The family earns 1 make-up credit. Taught make-up lessons use that same credit, so one missed lesson is never charged twice."*
- Option `none`: *"No credits — make-ups are billed like any lesson."*
- Option `one_per_missed`: *"1 missed lesson = 1 credit. The make-up uses that credit; it is not billed again."*
- Tooltip on Postpone (Calendar): *"Moves this lesson to a new day. It is still one lesson, so nothing extra is charged and no credit is used."*
- Tooltip on a make-up lesson: *"Using 1 credit from the lesson missed on {date}."*
- Until built (now): mark makeups.allowed / per_period / uses_credit and the two prepaid credit settings `soon`, help *"Make-up credits come in a later update; for now a make-up is added as a normal lesson."*

## 5. Singapore public holiday library
**Design.** Data file `assets/data/sg-public-holidays.json` (plain data, public repo, no secrets): `{year, date, name, observed_on?, status}` rows, `status` = `official` or `to_confirm`. Centre wizard step 2 shows "Singapore public holidays" with a checkbox per row (none ticked by default), plus "Select all for {year}". Ticking inserts a normal `holidays` row (name, starts_on = ends_on) so the existing table, delete button and tests stay. Un-ticking deletes that row. A holiday whose date has already got a row is shown ticked. **Nothing is auto-applied**, not at sign-up either. Solo tutors get the same list in Settings later (needs `holidays` for solo orgs; the table already carries `org_id` for them).
**Yearly update.** Hari Raya Puasa, Hari Raya Haji, Vesak, Deepavali and Chinese New Year move each year; Good Friday moves too. MOM publishes next year's list around mid-year. Each November someone adds the following year's rows from the MOM page (a recurring to-do on the board). Years not in the file show "Not published yet".
**Dates (verified).** Source: https://www.mom.gov.sg/employment-practices/public-holidays, page "Last Updated: 19 June 2026", read by a fetch on 2026-11-24. Not cross-checked against a second source; the page has no "final/gazetted" statement and no to-be-confirmed footnotes, so 2027 is `official` as published but should be re-checked before shipping.
| 2026 | | 2027 | |
|---|---|---|---|
| Thu 1 Jan New Year's Day | | Fri 1 Jan New Year's Day | |
| Tue 17 + Wed 18 Feb Chinese New Year | | Sat 6 + Sun 7 Feb Chinese New Year (Mon 8 Feb if rest day is 7 Feb) | |
| Sat 21 Mar Hari Raya Puasa | | Wed 10 Mar Hari Raya Puasa | |
| Fri 3 Apr Good Friday | | Fri 26 Mar Good Friday | |
| Fri 1 May Labour Day | | Sat 1 May Labour Day | |
| Wed 27 May Hari Raya Haji | | Mon 17 May Hari Raya Haji | |
| Sun 31 May Vesak Day (Mon 1 Jun if rest day is 31 May) | | Thu 20 May Vesak Day | |
| Sun 9 Aug National Day (Mon 10 Aug if rest day is 9 Aug) | | Mon 9 Aug National Day | |
| Sun 8 Nov Deepavali (Mon 9 Nov if rest day is 8 Nov) | | Thu 28 Oct Deepavali | |
| Fri 25 Dec Christmas Day | | Sat 25 Dec Christmas Day (no substitute listed) | |
Note on substitutes: MOM's Monday holiday applies only to people whose *rest day* is that Sunday. A tuition centre is not an employer's rest-day rule, so the library lists the Monday as a separate, **unticked-by-default** row "Substitute (Mon)" and the centre decides.

## 6. What happens to lessons on a ticked holiday
Process rule, so a centre option `calendar.holiday_action` (applies to every lesson from today):
- `skip_generation` (default): not generated by Ledger / Planner / Calendar projection; shown on the Calendar as a grey holiday band.
- `generate_and_flag` *(soon)*: still generated but marked "holiday"; admin decides.
Already-generated lessons on a newly ticked day are **not deleted or changed** (real data). The wizard shows a list, "3 lessons already fall on this day", with a one-tap "Cancel with no charge" that goes through the normal cancel path. Whether a holiday lesson earns a make-up credit follows the credit rule above (`holiday_earns_credit`, soon). Solo tutors keep today's behaviour until they opt into the library.

## 7. Database changes and tests (all later, none now)
- `org_validate_settings`: validate `makeups.credit_rule`, `calendar.holiday_action`; fixes `skip_holidays` meaning.
- New table `makeup_credits` (RLS by org, `on delete cascade` so account deletion covers it); function that creates/spends a credit atomically; add to the `org_delete_solo` residue test.
- `holidays`: add `source text` (`library`/`custom`) and `library_key text`, unique `(org_id, library_key)` so ticking twice is a no-op.
- Tests: SQL tests per credit_rule value (missed→credit, make-up spends same credit, no second credit on postpone, expiry, per_period cap); JS test that options in `org-settings.js` match SQL; unit test for holiday skipping in the shared generation helper; data-file test (dates parse, weekdays match the names, no duplicates). New migrations go to DEV first; LIVE only when shipping.

## 8. Build steps and recommendation
1. **Honesty fix (tiny, ship now):** `soon` flags + help text on make-up/credit/holiday-skip settings; "Postpone" tooltip. No DB.
2. **Holiday library UI + data file + yearly to-do** (no behaviour change; centres only).
3. **Holidays actually skip lessons:** one shared helper used by Ledger generation, Planner and Calendar projection, with `holiday_action`; solo opt-in later.
4. **Credits:** table + `none` / `one_per_missed`, link a make-up lesson to its missed lesson (button "Make-up for…" on a cancelled lesson), staff screen shows balances.
5. Prepaid packages and low-balance warnings: separate project, not before centre invoicing (T4).
Recommendation: do 1 and 2 now, 3 next; hold 4 until the owner picks the rule below.

## 9. Decisions for the owner
1. Confirm the rule: one missed lesson = one credit, make-up never charged twice (option `one_per_missed` as default?).
2. When does a missed lesson earn a credit: only with notice (24h), or also tutor-cancelled and holiday?
3. Credits expire? Default never (0), as today's setting.
4. Holidays: default action "skip" for centres — ok? Should Monday substitute days be offered?
5. Offer the holiday library to solo tutors too (recommended, later)?
