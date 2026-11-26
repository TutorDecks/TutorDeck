# T4 plan: centre money (invoicing, payments, deposits, late fees, tutor pay)

Branch `claude/t4-plan`. Plan only: no product code, no SQL, nothing deployed, LIVE untouched. Written 2026-11-26 for the prospective customer **Opus Tuition** (remote 1-to-1 centre). Read: CLAUDE.md, `assets/js/org-settings.js`, `assets/js/money.js`, `db/migration_org_foundation.sql`, `migration_attendance.sql`, `migration_tutor_access.sql`, `baseline_2026-11.sql`, the T3, T6, T18, T24b plans, the T27 product guide (sections 3, 4.9, 4.10, 4.16, 7) and the branches `claude/t3-1..t3-4`. Anything I could not confirm says **not verified**. Money and tax points are for the owner's accountant or lawyer; this is not advice.

## Summary
- **Nothing of this exists yet.** There is no centre invoice, payment, refund, deposit, late-fee or tutor-rate table. The settings exist (`billing.one_off_fees.deposit_cents` l.84, `billing.late_fee.*` l.86-88, `tutor_pay.*` l.144-160 of `org-settings.js`), but nothing reads them and the deposit and late-fee rows carry no `soon` flag, so the wizard promises what the app does not do (T18a may already fix the flags: not verified). `org_validate_settings` (foundation l.325) checks only a few of these keys.
- **Approach (same as T3/T6):** database first. Every action is one `SECURITY DEFINER` function that checks `org_can(...)`, the centre's settings and the integrity rules. The new tables have **no write policy at all** (stricter than the old `org_write` pattern, because these rows are money records). Tutors keep zero table access and get two read-only functions for their own pay.
- **Four kinds of document and one ledger, never mixed:** lesson invoice, deposit invoice, late fee (a line on a lesson invoice, or its own small document), credit note; plus a **deposit ledger** that is a liability held by the centre, never revenue. Issued documents never change; corrections are credit notes or reversing entries.
- **Deposits (Opus):** mode none / fixed / **percent of first month's fee** (50% for Opus), raised with the first invoice run, frozen at the amount first computed, held per student, released by centre rules, **refund = request, approve, pay, with who/when/reference** at every step.
- **Tutor pay:** a new append-only, effective-dated **rate table per tutor, overridable per student**; methods per lesson / per hour / **percent of the parent's fee** / fixed monthly. The default "pay only after the parent's payment is reconciled" needs real payments first, so tutor pay comes **after** invoicing and payments.
- **Late fees:** none / once / **every month it stays unpaid**, fixed or percent, cap, grace days; created as **proposals** a person applies, added to the next invoice or issued as their own document; can be waived with a reason.
- **Nine small steps** (section 5), S0-S8, each shippable alone and clickable with the demo logins. Opus needs S0-S5 and S7-S8; late fees (S6) are small once S3 exists.
- **TutorDeck never holds the money.** Parents pay the centre's own PayNow/bank; TutorDeck records it. Refunds are paid by the centre; TutorDeck records them.
- Eight decisions for the owner in section 7. Ask Opus five questions first (section 6).

## 1. Deposits
**Settings** (section "How lessons are billed"; values not built are `soon`; billing changes apply from the 1st of next month, the existing `CYCLE_SECTIONS` rule):
| Key | Values | Notes |
|---|---|---|
| `billing.deposit.mode` | `none` / `fixed` / `percent_first_month` | `fixed` reuses `one_off_fees.deposit_cents`. |
| `billing.deposit.percent_bp` | 0-10000 (5000 = 50%) | only for `percent_first_month`. |
| `billing.deposit.due` | `with_first_invoice` (built); `before_first_lesson` (`soon`) | |
| `billing.deposit.waived_by` | `owner` / `issue_invoices` / `nobody` | waiving needs a reason. |
| `billing.deposit.release` | `refund_full` / `refund_less_unpaid` / `admin_decides` | what the system **proposes** when a student leaves. |
| `billing.deposit.forfeit_notice_days` | 0-90 (0 = never forfeit) | leaving with less notice than this proposes forfeit. |
| `billing.deposit.refund_approved_by` | `owner` / `other_staff` / `any_staff` | `other_staff` = not the person who requested. |

**"First month's fee"** = what the invoice run would bill for the student's first period (non-trial lessons at the centre's rate, before sibling discount and GST), computed once when the deposit is raised and **frozen** on the deposit row together with the percent used. If the fee changes later, the deposit does not move on its own; staff may make an **adjustment** with a reason. Trial lessons do not raise a deposit; the first non-trial lesson in an invoice run does. Whether Opus bills in advance or after the month decides if the first month is known on day one: **not verified, ask Opus**.

**Invoiced** as its own **deposit invoice** (kind `deposit`, "Refundable deposit"), issued together with the student's first lesson invoice but a separate document, sharing the centre's invoice-number counter (one gap-free series). It is never a line on a lesson invoice, never counted in revenue, never taxed by default (decision 1), and **never gets a late fee**.

**Held** in an append-only **deposit ledger** per student (household view on top). Entry kinds: `raised`, `received`, `waived`, `adjusted`, `applied` (kept against unpaid invoices), `forfeited`, `refund_requested`, `refund_approved`, `refunded`, `refund_cancelled`, `transferred_out/in`, `opening_balance`, `reversal`. Balance = sum; corrections are reversing entries. It shows on a **household deposit statement** (parents later through the portal) and as one total "Deposits held" for staff with `record_payments` or `view_revenue`, outside every revenue figure.

**Release rules are money rules**, so a snapshot of the release settings is stored on the deposit when it is raised; changing policy later does not rewrite what the parent agreed to.

**Refund tracking** (one row per refund; every step is a ledger entry and an audit row):
`proposed` (system, once the student's end date has passed and nothing blocks: no draft invoice, no pending charge) → `requested` (staff with `record_payments`, who sees the calculation: balance, minus unpaid invoices if `refund_less_unpaid`, minus any forfeit) → `approved` (per `refund_approved_by`) → `paid` (staff types method PayNow / bank / cash / cheque, date, reference, optional proof image) or `cancelled` (reason). Fields: amount, payee name (free text), reference, requested / approved / paid by and at. **Never store a full bank or PayNow number** (PDPA, as T24b); "PayNow, last 4 digits 1234" is enough. Output: a numbered **refund statement** (credit-note style, immutable).

**Edge cases**
| Case | Rule |
|---|---|
| Leaves mid-month | The final invoice follows `billing.proration`; the refund proposal waits until that invoice is issued, then deducts it if unpaid. |
| Siblings | Deposit is per student. "Unpaid invoices" means the household's if `invoicing.grouping = family`, the student's if `student`. |
| Move deposit between students | Staff only, same household (database check), reason, a `transferred_out` and `transferred_in` pair. |
| First month fee changes | Frozen amount stays; adjustment with reason. |
| Part-paid deposit | Payment is allocated to the deposit invoice; ledger shows `received` in part and "short by S$X". Lessons are not blocked (a "block until paid" value is `soon`). |
| Student returns | Balance still held carries over; only the top-up to the required amount is raised. |
| Already collected on a sheet | `opening_balance` entry (reason, staff only) so a centre can start mid-year. |
| Overpayment on a deposit | Goes to household credit per `payments.overpayments`, never silently into the deposit. |

## 2. Tutor pay
**Where the rate lives:** new append-only table `tutor_pay_rates` (`org_id`, `membership_id`, `student_id` null = the tutor's default, a student = override for that pair only, `method`, `amount_cents` or `percent_bp`, `effective_from`, `reason`, `created_by`, `created_at`). The rate in force for a lesson is the newest row with `effective_from` on or before the **lesson date** (money rules follow what was in force when the lesson happened). A change is a new row; nothing is edited or deleted. A replacement tutor on one lesson (`lessons.replacement_tutors`) is paid at **their own** default, never the original tutor's override.

**Methods** (`tutor_pay.rate_model` stays the centre's default that pre-fills the form; each tutor can differ): `per_lesson` (fixed cents), `per_hour` (cents x duration), `monthly_fixed`, `per_student_lesson` (groups only), and the new **`percent_of_fee`** (`soon` until S8).

**Percentage of what** (new centre settings):
- `tutor_pay.percent_base`: `billed_after_discounts` (default: the lesson's billed amount after sibling and one-off discounts) / `list_price`. **GST is never in the base** (tax, not fee). **Late fees and deposits never are.** A cancelled lesson's billed amount is its compensation, so a percentage of a free cancellation is 0.
- `tutor_pay.cancelled_lessons` (for fixed methods): `pay_if_charged` (default) / `pay_rate` / `pay_nothing`.
- `tutor_pay.payable_when` (exists): `parent_paid` = payable only when the invoice line it sits on is **fully covered** by payments (allocated oldest line first); `taught` = once marked attended. New `tutor_pay.part_payments`: `after_full` (default) / `pro_rata`. Unpaid lessons show **pending** and roll into the next period. A credit note after pay is **not** clawed back automatically: it raises a suggested negative adjustment that staff confirm (decision 2).

**Employee or freelancer:** already `memberships.employment_type`. It changes the wording only (payslip vs payment summary). **CPF, SDL and tax are not computed in v1** (the wizard note already says the centre confirms with its accountant); a later setting can add them.

**Pay run:** `tutor_pay_runs` (period; draft / closed / paid), `tutor_pay_lines` (lesson, rate snapshot, base, amount, payable or pending), `tutor_pay_adjustments` (signed cents, **reason required**, only if `tutor_pay.adjustments` is on). A closed run never changes; mistakes are adjustments in the next run. The **lessons-taught report** (mode `report`) is a function with counts and hours per tutor and month and no money, so it ships early (S7). **Pay list:** `manual_list` = CSV of payee, amount, reference, using T24b's payout details (masked, reveal audited, needs `view_payout_details`); `bank_file` stays `soon`.

**Who sees what:** rates and pay rows are readable by the tutor (own, through a function) and by staff with `run_tutor_pay` or the owner. `tutor_my_pay(period)` and `tutor_my_rates()` return an explicit column list: date, student first name, minutes, **their pay, their rate**, state; **never fee, price, amount, paid or invoice** (a test greps the return columns, as for `tutor_my_lessons`). `tutor_pay.tutor_visibility` (`running` / `closed_only`) decides whether open-period rows show. A percentage rate lets a tutor who knows the percentage work out the fee from their own pay; the centre decides if that is acceptable (decision 2).

## 3. Late fees
Settings (extend the existing `enabled`, `amount_cents`, `after_days`; `after_days` becomes the **grace period** after the due date):
| Key | Values |
|---|---|
| `billing.late_fee.repeat` | `once` / `monthly` (again each month the invoice stays unpaid, on the same day of the month) |
| `billing.late_fee.type` | `fixed` (`amount_cents`) / `percent` (`percent_bp` of the **unpaid balance of that lesson invoice** on that date) |
| `billing.late_fee.cap_cents` | 0 = no cap; otherwise the most late fees one invoice can ever collect |
| `billing.late_fee.show_as` | `next_invoice_line` (a "Late fee" line on the family's next invoice) / `own_invoice` |
| `billing.late_fee.waived_by` | `owner` / `issue_invoices` |

**Fixed rules:** a late fee never changes an issued invoice; no compounding (a late fee is never itself charged a late fee); lesson invoices only; a fully paid invoice stops accruing; paying on the due date is on time. **How:** `late_fee_proposals(org)` lists fees due today, one per invoice and month (unique on invoice + month number, so running it twice adds nothing). A person with `issue_invoices` applies or **waives** (reason required, audited). Applying attaches the line to the next draft invoice or issues the small own document. No daily cron in v1: it is a screen and a count on Home (decision 5). GST on a late-fee line follows the invoice it sits on (accountant to confirm).

## 4. Centre invoicing (the original T4)
- **Tables** (new; the solo `invoices` table has `tutor_id not null` and keeps HTML in `data`, so it stays untouched, per "solo flows must not change"): `centre_invoices` (kind, number, household, optional student, period, draft / issued, due date, settings version used, subtotal, GST, total in cents, share token), `centre_invoice_lines` (a lesson id or a description, cents; a partial unique index so **a lesson is billed once**), `centre_payments` + `centre_payment_allocations` (a payment may cover several invoices; a part payment or overpayment is allocated or becomes household credit), `centre_credit_notes`, and `org_counters`. The counter is new because `profile.next_invoice_number` lives inside `org_settings`, which is append-only (`audit_immutable` trigger) and cannot be a counter.
- **Invoice run:** `staff_invoice_run_preview(org, period)` is read-only and lists, per household, ready lessons and **not-ready** ones with the reason: a cancelled lesson with `compensation is null` (T3 exposes `pending_charge_count(org)`), a lesson with no price (T6 decision 1), a lesson past its day but not yet marked. `staff_invoice_run_create` makes drafts (or issues straight away when `invoicing.review_before_sending` is off). **Idempotent.** One invoice per family or student, sibling discount, one-off discounts with a reason, proration, GST **once per invoice**, half-up, exactly as `Money.invoiceTotals`.
- **Billing models:** build `postpaid_lessons` and `fixed_in_advance` (month) first; `prepaid_packages`, per-term fixed and `pay_per_lesson` need credits (T18) and stay `soon`. Whether trial lessons are charged is a centre decision with **no setting today**: add one in S0 (not verified whether Opus charges trials).
- **Issue** takes its number from `org_counters` in the same transaction (no gaps). A **credit note** is a separate numbered document with a reason, referencing the invoice; the invoice stays. A credited lesson is not re-billed automatically.
- **Payments:** `staff_record_payment` (manual PayNow with the invoice number as reference, bank, cash, cheque; date; optional proof) needs `record_payments`; a mistake is a **reversal row**, never an edit. `payments.partial_payments` off = refused unless it covers the balance; `payments.overpayments` credit / refund as chosen. Status shown: draft, issued, part-paid, paid, overdue (derived).
- **Delivery now:** shareable link (`invoicing.delivery.share_link`, a public function like solo's `invoice_by_token` returning only that invoice) and a WhatsApp message in the existing template pattern. **Later:** email and reminders (need T7's email provider), and statement matching (CSV of DBS / OCBC / UOB that only **suggests** matches by invoice number; a person confirms; raw statements are deleted after matching because they hold payers' names).
- **GST in two places** (browser `money.js`, SQL): the SQL function is the source for issued documents; one shared file of worked examples runs in `tests/money.test.js` and in the SQL test so they cannot drift.

## 5. Data model, access, tests, build order
**Access.** Every new table: `org_id`, same-org composite keys, `audit_row` trigger (redacting reference text), `audit_immutable` on the append-only ones. Read policy by permission (`issue_invoices` invoices, `record_payments` payments and deposits, `run_tutor_pay` rates and pay, `view_revenue` totals). **No insert/update/delete policy**; writes only through functions. Solo orgs and non-members get `NOT_FOUND`. **No new permission names** (refund approval is the setting `refund_approved_by`); T24b's `view_payout_details` is reused. Tutors: no policy anywhere, only `tutor_my_pay` and `tutor_my_rates`; nothing is added to `tutor_my_lessons`.

**Test rule:** one SQL file per step in `tests/sql/`, **a test for every value of every setting** (allowed, the exact refusal, the edge and one past it), plus the cross-org, solo, tutor and parent refusals, an audit-row check and a money-column grep on tutor functions. `tests/org-settings.test.js` compares the new enums with `org_validate_settings`; `money.test.js` gets the shared vectors. Each step: DEV only, `?v=` bump, README log entry, 390 px check, migration after T3's; LIVE only when the owner says ship, before the code that needs it.

| Step | Build | Done means | Owner click-through (DEV; demo logins and password are in `db/seed_dev_demo.sql`) |
|---|---|---|---|
| **S0** | Settings and honesty: all new keys in `org-settings.js` (unbuilt = `soon`), full validation in `org_validate_settings`, a trials-charged setting, tests | Every new option has label, default and SQL check; none promises what is unbuilt | `centre.owner@example.test` opens Settings: the new deposit, late-fee and pay options show "coming soon"; a bad percent is refused |
| **S1** | Document, payment and counter tables, append-only triggers, RLS, SQL GST function with shared vectors | Issued rows cannot change; totals equal `money.js`; tutors and other centres read nothing | (SQL tests only, no screen) |
| **S2** | Invoice run preview, drafts, issue (postpaid, fixed monthly), households, sibling discount, GST, pending-charge block | Running twice adds nothing; a null-compensation lesson holds back only its own household's invoice | `centre.owner@` > Money > Invoice run: preview says "Sophie Lim: charge pending"; set the charge to 0 in Charges; create drafts; approve; number `INV-1` |
| **S3** | Record payment (manual PayNow), part payment, overpayment, credit note, status chips, share link, WhatsApp text | Paid / part-paid / overdue show correctly; a wrong payment is reversed, not edited | Record a part payment on `INV-1`: "part-paid"; credit note S$10 with a reason; open the share link logged out |
| **S4** | Deposits: settings, deposit invoice with the first run, ledger, waive, "Deposits held", opening balance | The Opus rule (50%, with first invoice) makes one frozen deposit invoice; none for a trial | Mode percent 50; add a student; run: a separate "Refundable deposit" invoice for half the first month; record it paid; held total rises, revenue does not |
| **S5** | Deposit release and refund tracking, forfeit rule, transfer, adjustment, refund statement | Every value of `release` and `refund_approved_by` tested; the proposal waits for the final invoice | End the student; proposal appears; request; approve as owner (refused for staff when set to `owner`); mark paid with a reference; statement shows the trail |
| **S6** | Late-fee proposals, apply as line or own document, waive | `once` and `monthly` tested at the grace edge, the cap and a part payment; none on a deposit invoice | Leave `INV-1` unpaid past due + grace: a proposal; apply to next invoice; next month a second; waive one with a reason |
| **S7** | Tutor rates table and screen, `tutor_my_rates`, lessons-taught report, `tutor_my_pay` for per-lesson / per-hour / monthly | A rate change applies only from its date; a student override beats the default; a tutor sees only their own pay | `centre.owner@` > People > tutor.one: S$40 per lesson from 1 Dec; `tutor.one@example.test` sees the rate and no fee anywhere; `tutor.two@example.test` sees none of it |
| **S8** | `percent_of_fee`, payable only after the parent paid, pay runs, adjustments, statements, manual pay-list CSV | Payable follows allocations; a closed run is immutable; pending rolls over | 60% for tutor.one; pay `INV-1` in full; run for Dec: lessons payable, an unpaid household's pending; add a bonus with a reason; export the list |
| later | Email delivery and reminders (T7), statement matching, bank file, prepaid packages and credits (T18), CSV import, CPF/SDL | | |

`centre.staff@example.test` exists in the demo data only on the T3 branches until they merge, so clicks that need a staff login wait for that. Prerequisites on `dev`: T12 (current organisation), T3 steps 1-4 (Charges queue, `pending_charge_count`), T24b's permission.

## 6. What Opus needs, and what other centres may need
Ask Opus first (**not verified**): (1) bills in advance or after the month? (2) GST registered? (3) tutors employees or freelancers, and is "percent" of the fee billed or collected? (4) what should happen to the deposit when a student leaves at short notice? (5) all in Singapore time, and do parents pay only by PayNow?
| Item | Opus | Other centres |
|---|---|---|
| Invoice run, households, GST, credit notes, manual PayNow | **yes** (S1-S3) | yes |
| Deposit of 50% of the first month, held, refunds tracked | **yes** (S4-S5) | some |
| Late fee, repeated each month | **yes** (owner's list), small (S6) | some |
| Per-tutor and per-student rates, per lesson | **yes** (S7) | yes |
| Percent of the parent's fee, after the parent paid | **yes** (S8) | some |
| Lessons-taught report | yes | yes |
| Prepaid packages, credits, make-ups | maybe (T18) | many |
| Email delivery, reminders | wanted (T7) | yes |
| Statement matching, bank file, CSV import, CPF | later | later |
| Group-class rates | no (1-to-1) | yes |

## 7. Risks and decisions for the owner (recommendation first)
1. **Deposit accounting and GST.** Recommend: a refundable deposit is a liability in its own ledger and documents, no GST when received; revenue and GST only when forfeited or applied to fees, under the centre's GST setting that day. A `taxable` flag on each deposit row lets the accountant's answer change the default without a schema change. Alternative: tax at receipt. Accountant to confirm this and what the deposit document may be called.
2. **Percent pay base.** Recommend: percent of the billed fee after discounts and before GST, payable only when its invoice line is fully paid, otherwise pending. Alternative: on cash received, pro rata. Never includes late fees or deposits; credit notes after pay become suggested adjustments. Confirm with Opus.
3. **Reuse `invoices` or new tables.** Recommend new `centre_*` tables (solo flows untouched, proper lines, counters). Alternative: widen `invoices`, riskier for every solo tutor.
4. **Refund approval.** Recommend: staff request, the owner approves by default (four-eyes option), never automatic. Alternative: any staff.
5. **Late-fee automation.** Recommend proposals a person applies, no cron for now. Alternative: a daily job once trusted. The fee and its wording must be in the terms parents accepted (lawyer to confirm); never on deposit invoices.
6. **First release size.** Recommend S0-S5 then S7-S8, then S6 (small once S3 exists). Alternative: S0-S3 and S7 only, with Opus doing deposits by hand for now.
7. **PDPA and retention.** Recommend: no full bank/PayNow numbers in refunds; raw bank statements deleted after matching; tutor-pay rows kept as the centre's records but shown as "Former tutor" after a tutor leaves (T24b); how long accounting records must be kept (often said to be 5 years: **not verified**) to confirm with the accountant. Alternative: keep everything.
8. **Opening the books mid-year.** Recommend `opening_balance` entries and a settable opening invoice number before the first run, so Opus can move over its sheets. Alternative: start every balance at zero on a month boundary.
