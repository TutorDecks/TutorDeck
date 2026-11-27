# T35 — closing a centre: design only (NOT built)

T35-E built the **export** (build steps E1 to E5 of `T35-plan.md`). Closing a centre (step E6) is **not** in the first release, so this file only records the design the owner accepted on 2026-11-27, to build later. Nothing here exists in the database yet; `org_delete_solo()` still refuses centres (`ONLY_SOLO`).

## What the owner decided
- The centre owner exports first (the export screen is the mandatory first step).
- **Grace: 30 days read-only, then deletion.** Backups keep the data for up to **30 more days** (we do not edit old backups; say so to the customer). Immediate deletion is not offered.

## Proposed states (one new column, no new table)
`organisations.status` today is `setup | active | suspended`. Add `closing` (plus `organisations.closing_started_at timestamptz`, `closing_by uuid`, `closing_export_job bigint`):

| State | Meaning | Who can do what |
|---|---|---|
| `active` | normal | as today |
| `closing` | read-only for 30 days | owner can still sign in, read everything, **export again**, and press **Reopen**; every write policy and every write function refuses ("this centre is closing"); invitations, tutor marking, parent views are off; Stripe subscription set to cancel at period end |
| (deleted) | after 30 days | `org_delete_centre(org)` runs from the daily cron: counts rows, deletes through the existing `on delete cascade`, proves nothing is left, keeps one anonymous marker row (the same pattern as `org_delete_solo`, flag `td.deleting_org`) |

## Closure flow (DB part, to build)
1. `org_close_start(p_org, p_export_job bigint, p_no_export_reason text)`: owner only (reuse `org_export_gate`). Requires either a **finished** export job started by this owner **today** (it is already audited: `org_export_finished`, `matched = true`) **or** the owner typing the explicit sentence "I don't want an export" (stored in the audit row). Sets `status = 'closing'`, `closing_started_at = now()`, audits `org_close_started` (counts only).
2. A guard (one trigger function on every business table, or the existing `org_row_guard`) refuses writes while `status = 'closing'` (`CLOSING: this centre is closing and is read-only`). Reads and `org_export_*` keep working.
3. `org_close_cancel(p_org)`: owner only, only while `closing`: back to `active`, audited.
4. `org_delete_centre(p_org)` (cron, service role only, never callable by a browser): deletes only centres with `closing_started_at < now() - interval '30 days'`; returns counts; second call is harmless.

## Tests to write with it
Close refused without an export; refused for staff / tutor / other owner (NOT_FOUND); every write function refuses while closing (loop over the function list); export still works while closing; reopen works; deletion refuses before day 30, proves empty after, keeps exactly one marker row, leaves other centres untouched; the audit rows exist; undo script.

## Customer wording (draft)
"Closing your centre: first download your data. Your centre then becomes read-only for 30 days (you can still sign in, download again, or reopen). After 30 days everything is permanently deleted from TutorDeck. Our encrypted backups can hold a copy for up to 30 more days, then it ages out."
