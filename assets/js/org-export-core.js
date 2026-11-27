// Centre data export (T35-E) — everything that needs no DOM and no network: the catalogue of files and columns (with plain-words descriptions), the CSV writer, the
// ZIP writer, the data-dictionary text, and the loop that pulls pages from the database and streams them into the ZIP.
// Used by assets/js/org-export.js (Settings → Data export) and unit-tested in tests/org-export-core.test.js.
//
// The database decides what may leave (db/migration_org_export.sql: owner-only, explicit column lists, masked payout numbers, audited). THIS file lists the same columns
// in the same order with a description each; tests/org-export-core.test.js fails when the two drift, and when docs/centre-data-export-dictionary.md (generated from
// this list by tests/gen-export-dictionary.js) is out of date.
//
// Memory: one page at a time is turned into CSV text, hashed, and handed to a Blob; a table is compressed (where the browser can) and its Blob joined into the ZIP.
// No table is ever held as one JavaScript string or one object tree, so 100,000-row tables are fine.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.OrgExportCore = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  // ------------------------------------------------------------------ the catalogue
  var C = {
    id: "Unique id of this row. Other files point at it (for example a lesson's student_id is a student's id), so you can join files in a spreadsheet.",
    created: "When the row was created (UTC).",
    who: function (what) { return what + " (the person's name; \"Former member\" if they have since left the centre)."; }
  };
  // [tbl, file, title, about, [[column, description], ...]]  — the column names and their order must equal org_export_catalog() in the migration.
  var CATALOG = [
    ["organisations", "centre_profile.csv", "Centre profile", "The centre's own details: names, UEN, address, time zone and currency.", [
      ["id", "Your centre's id."], ["trading_name", "Trading name."], ["legal_name", "Registered (legal) name."], ["uen", "Business registration number (UEN)."], ["address", "Address."],
      ["kind", "Always \"centre\"."], ["preset", "The setup preset the centre started from."], ["status", "setup, active or suspended."], ["timezone", "The centre's time zone."], ["currency", "Currency."],
      ["reply_to_email", "Email address parents' replies go to."], ["brand_color", "Brand colour on invoices and pages."], ["created_at", C.created]]],
    ["branches", "branches.csv", "Branches", "Each branch (location) of the centre.", [["id", C.id], ["name", "Branch name."], ["address", "Branch address."], ["created_at", C.created]]],
    ["rooms", "rooms.csv", "Rooms", "Rooms or classrooms in a branch.", [["id", C.id], ["branch_id", "The branch (branches.csv id)."], ["name", "Room name."], ["capacity", "Seats."]]],
    ["terms", "terms.csv", "School terms", "The centre's term dates.", [["id", C.id], ["name", "Term name."], ["starts_on", "First day."], ["ends_on", "Last day."]]],
    ["holidays", "holidays.csv", "Holidays", "Days when no lessons are generated.", [["id", C.id], ["branch_id", "The branch it applies to (blank = every branch)."], ["name", "Holiday name."], ["starts_on", "First day."], ["ends_on", "Last day."]]],
    ["memberships", "people_tutors_and_staff.csv", "Tutors, staff and parents with access", "Everyone who has (or was invited to have) access to the centre: owner, staff admins, tutors and parent logins. No passwords and no login ids.", [
      ["id", C.id + " For a tutor this is the id lessons and slots call taught_by."], ["display_name", "Name shown in the app."], ["role", "owner, staff, tutor or parent."],
      ["permissions", "What a staff admin may do (separated by semicolons)."], ["employment_type", "For tutors: freelancer, part-time or full-time."], ["status", "invited, active or disabled."],
      ["invited_email", "The email address the invitation went to."], ["phone", "Phone number, if one was entered."], ["created_at", C.created]]],
    ["tutor_payout_details", "tutor_payout_details.csv", "Tutor payout details", "Where each tutor is paid. Account numbers and holder names are MASKED (•••••1234, first letter + •••) unless you ticked \"include full payout numbers\" before exporting. Only the current details, not history.", [
      ["id", C.id], ["membership_id", "The tutor (people_tutors_and_staff.csv id)."], ["method", "bank, paynow_mobile or paynow_uen."], ["bank_name", "Bank, for a bank account."],
      ["paynow_id", "PayNow mobile number or UEN (masked unless you chose full numbers)."], ["account_no", "Bank account number (masked unless you chose full numbers)."],
      ["account_holder", "Name on the account (first letter only unless you chose full numbers)."], ["created_at", "When these details were saved (UTC)."]]],
    ["households", "families.csv", "Families", "One row per family (household). Students link to a family.", [["id", C.id], ["name", "Family name."], ["phone_key", "The family's phone number in a plain form used to match siblings."], ["created_at", C.created]]],
    ["guardians", "parents_guardians.csv", "Parents and guardians", "Parents' and guardians' names and contact details. This is personal data under the PDPA: keep this file private.", [
      ["id", C.id], ["household_id", "The family (families.csv id)."], ["name", "Parent or guardian's name."], ["relation", "Relationship to the student."], ["phone", "Phone number."], ["email", "Email address."], ["created_at", C.created]]],
    ["students", "students.csv", "Students", "One row per student, including those who have left (see active and end_date).", [
      ["id", C.id], ["household_id", "The family (families.csv id)."], ["name", "Student's name."], ["kind", "individual or group, if used."], ["level", "School level."], ["contact", "Contact number or note entered for the student."],
      ["recipient_name", "Who invoices are addressed to."], ["household", "The family name as originally typed."], ["location", "Where lessons happen, if recorded."], ["online_link", "Online lesson link, if any."],
      ["pay_by_bank", "True if the family pays by bank transfer."], ["notes", "Notes about the student."], ["active", "False once the student has been discontinued."], ["start_date", "First lesson date."],
      ["end_date", "Lessons run until this date (inclusive)."], ["created_at", C.created]]],
    ["student_tutors", "student_tutors.csv", "Student–tutor assignments", "Which tutor looks after which student, and for how long.", [
      ["id", C.id], ["student_id", "The student."], ["membership_id", "The tutor (people_tutors_and_staff.csv id)."], ["since", "From."], ["until", "Until (blank = still assigned)."], ["active", "Whether the assignment is current."],
      ["created_by", C.who("Who added it")], ["created_at", C.created]]],
    ["recurring_slots", "weekly_slots.csv", "Weekly slots", "The weekly timetable template that lessons are generated from.", [
      ["id", C.id], ["student_id", "The student."], ["student_name", "The student's name (looked up for you)."], ["taught_by", "The tutor (people_tutors_and_staff.csv id)."], ["tutor_name", "The tutor's name (looked up for you)."],
      ["session_key", "Slots that share this value are one group class."], ["weekday", "0 = Sunday … 6 = Saturday."], ["start_time", "Start time."], ["end_time", "End time."], ["subject", "Subject."], ["level", "Level."],
      ["split", "Number of students sharing the lesson fee, if split."], ["rate_cents", "Fee per lesson, in cents."], ["active", "False once the slot has been stopped."], ["starts_on", "First date the slot applies."],
      ["stopped_from", "Date from which the slot no longer applies."], ["created_at", C.created]]],
    ["lessons", "lessons.csv", "Lessons", "Every lesson: past, today and scheduled. The ground truth for attendance and billing.", [
      ["id", C.id], ["student_id", "The student."], ["student_name", "The student's name (looked up for you)."], ["taught_by", "The tutor who was scheduled (people_tutors_and_staff.csv id)."], ["tutor_name", "That tutor's name (looked up for you)."],
      ["covered_for", "If a replacement tutor took the lesson, the tutor they covered for."], ["slot_id", "The weekly slot it was generated from (blank for a one-off)."], ["session_id", "Lessons sharing this value are one group session."],
      ["lesson_date", "Date."], ["start_time", "Start time."], ["end_time", "End time."], ["subject", "Subject."], ["level", "Level."], ["split", "Number of students sharing the fee, if split."],
      ["status", "scheduled, done or cancelled (cancelled lessons are billed at compensation_cents)."], ["attendance", "attended, absent or blank if not yet marked."], ["attendance_marked_at", "When attendance was marked (UTC)."],
      ["attendance_marked_by", C.who("Who marked it")], ["trial", "True for a trial lesson."], ["one_off", "True for a manual one-off lesson."], ["postponed", "True if the lesson was moved."],
      ["slot_date", "The slot's original date, if the lesson was moved."], ["rate_cents", "Fee per lesson, in cents."], ["amount_cents", "Amount billed for the lesson, in cents."],
      ["compensation_cents", "What is charged for a cancelled lesson, in cents (0 = not charged; blank = still to be decided)."], ["charge_note", "Note about the charge."], ["paid", "Whether the lesson has been paid."],
      ["paid_date", "Date it was paid."], ["topics", "Topics covered."], ["homework", "Homework set."], ["remarks", "Remarks about the lesson."], ["remarks_at", "When the remarks were written (UTC)."],
      ["subject_notes", "Per-subject notes (structured text)."], ["changed_by_tutor", C.who("The tutor who changed the lesson, if one did")], ["changed_by_tutor_at", "When (UTC)."],
      ["changed_by_tutor_what", "What the tutor changed."], ["changed_by_tutor_reason", "Reason given."], ["changed_from_date", "The date before the change."], ["changed_from_start", "The start time before the change."],
      ["created_at", C.created]]],
    ["exams", "exams.csv", "Exams and assessments", "Exam dates and results recorded for students.", [
      ["id", C.id], ["student_id", "The student."], ["student_name", "The student's name (looked up for you)."], ["subject", "Subject."], ["exam_date", "Date."], ["assessment_type", "Type of assessment."],
      ["score", "Mark."], ["max_score", "Out of."], ["topics", "Topics covered."], ["remarks", "Remarks."], ["created_at", C.created]]],
    ["invoices", "invoices_legacy.csv", "Older-style invoices", "Invoices made with the original tutor screen (usually empty for a centre). The invoice page's HTML is not included.", [
      ["id", C.id], ["student_id", "The student."], ["invoice_no", "Invoice number."], ["issued_date", "Date issued."], ["total_cents", "Total, in cents."], ["status", "Status."], ["paid_date", "Date paid."],
      ["sent_at", "When it was sent (UTC)."], ["data", "The invoice's lines and details (structured text)."], ["created_at", C.created]]],
    ["centre_invoices", "invoices.csv", "Invoices and credit notes", "Every invoice and credit note. kind tells them apart; issued documents never change (a correction is a credit note).", [
      ["id", C.id], ["kind", "lesson, deposit, credit_note and so on."], ["series", "Number series: invoice or credit_note."], ["status", "draft, issued or void."], ["number_text", "The document number shown to the family."],
      ["number_seq", "The running number."], ["imported_number", "The number from your old system, if the invoice was imported."], ["household_id", "The family (families.csv id)."], ["household_name", "The family's name (looked up for you)."],
      ["student_id", "The student, for a per-student invoice."], ["student_name", "The student's name (looked up for you)."], ["credits_invoice_id", "For a credit note: the invoice it corrects."],
      ["period_start", "First day billed."], ["period_end", "Last day billed."], ["issue_date", "Date issued."], ["due_date", "Due date."], ["gst_registered", "Whether GST was charged."],
      ["gst_rate_bp", "GST rate in basis points (900 = 9%)."], ["gst_inclusive", "Whether prices include GST."], ["net_cents", "Amount before GST, in cents."], ["gst_cents", "GST, in cents."],
      ["total_cents", "Total, in cents."], ["reason", "Reason (credit notes)."], ["void_reason", "Reason it was voided."], ["created_by", C.who("Who created it")], ["created_at", C.created],
      ["issued_by", C.who("Who issued it")], ["issued_at", "When it was issued (UTC)."], ["voided_at", "When it was voided (UTC)."]]],
    ["centre_invoice_lines", "invoice_lines.csv", "Invoice lines", "The lines of each invoice. Join to invoices.csv with invoice_id.", [
      ["id", C.id], ["invoice_id", "The invoice (invoices.csv id)."], ["position", "Line order."], ["lesson_id", "The lesson billed (blank for fees)."], ["student_id", "The student."], ["fee_kind", "Kind of fee if not a lesson."],
      ["description", "What the line says."], ["qty", "Quantity."], ["unit_cents", "Price each, in cents."], ["line_cents", "Line total, in cents."], ["created_at", C.created]]],
    ["centre_payments", "payments.csv", "Payments", "Money received from families (and reversals of mistakes). Payments are never edited: a mistake is a reversal row.", [
      ["id", C.id], ["kind", "payment or reversal."], ["reverses_payment_id", "For a reversal: the payment it cancels."], ["household_id", "The family (families.csv id)."], ["household_name", "The family's name (looked up for you)."],
      ["method", "cash, PayNow, bank transfer and so on."], ["amount_cents", "Amount, in cents."], ["received_on", "Date received."], ["reference", "Reference the family used."], ["payer_name", "Name of the payer."], ["note", "Note."],
      ["recorded_by", C.who("Who recorded it")], ["created_at", C.created]]],
    ["centre_payment_allocations", "payment_allocations.csv", "Payment allocations", "How each payment was applied to invoices.", [
      ["id", C.id], ["payment_id", "The payment (payments.csv id)."], ["invoice_id", "The invoice (invoices.csv id)."], ["cents", "Amount applied, in cents (negative when a payment is reversed)."], ["created_by", C.who("Who allocated it")], ["created_at", C.created]]],
    ["centre_family_credit", "family_credit.csv", "Family credit", "Credit a family holds with the centre: overpayments, credit from missed lessons, and how it was used or refunded.", [
      ["id", C.id], ["household_id", "The family (families.csv id)."], ["kind", "How the credit arose or was used."], ["handling", "How it was handled."], ["cents", "Amount, in cents."], ["payment_id", "Related payment."],
      ["invoice_id", "Related invoice."], ["method", "Payment method, for a refund."], ["reference", "Reference."], ["reason", "Reason."], ["refund_id", "Related refund (refunds.csv id)."], ["created_by", C.who("Who recorded it")], ["created_at", C.created]]],
    ["centre_deposits", "deposits.csv", "Deposits", "Refundable deposits asked of students.", [
      ["id", C.id], ["student_id", "The student."], ["household_id", "The family."], ["source", "Where the deposit came from."], ["mode", "How the amount was worked out."], ["percent_bp", "Percentage in basis points, if a percentage."],
      ["first_month_cents", "First month's fee used for the calculation, in cents."], ["required_cents", "Deposit asked, in cents."], ["taxable", "Whether GST applies to it."], ["period_start", "Billing month it was raised."],
      ["invoice_id", "The invoice that carried it."], ["created_by", C.who("Who created it")], ["created_at", C.created]]],
    ["centre_deposit_ledger", "deposit_ledger.csv", "Deposit ledger", "Every movement of each deposit: received, set off, forfeited, refunded.", [
      ["id", C.id], ["student_id", "The student."], ["deposit_id", "The deposit (deposits.csv id)."], ["kind", "Kind of movement."], ["cents", "Amount, in cents."], ["taxable", "Whether GST applies."],
      ["invoice_id", "Related invoice."], ["payment_id", "Related payment."], ["allocation_id", "Related allocation."], ["refund_id", "Related refund."], ["entry_date", "Date of the entry."], ["reason", "Reason."],
      ["created_by", C.who("Who entered it")], ["created_at", C.created]]],
    ["centre_refunds", "refunds.csv", "Refunds", "Deposit refunds and family-credit refunds, with the approval trail.", [
      ["id", C.id], ["kind", "deposit or family_credit."], ["student_id", "The student."], ["household_id", "The family."], ["deposit_id", "The deposit refunded."], ["refund_cents", "Amount to pay back, in cents."],
      ["forfeit_cents", "Amount kept by the centre, in cents."], ["set_off_cents", "Amount set against unpaid invoices, in cents."], ["held_cents", "Amount still held, in cents."], ["taxable", "Whether GST applies."],
      ["gst_cents", "GST in the amount, in cents."], ["release_rule", "The centre's release rule used."], ["notice_days", "Notice period in days."], ["notice_given_on", "Date notice was given."],
      ["lesson_end", "Last lesson date."], ["payer_name", "Who the money goes back to."], ["reason", "Reason."], ["requested_by", C.who("Who asked for the refund")], ["requested_on", "Date asked."], ["created_at", C.created]]],
    ["centre_refund_events", "refund_events.csv", "Refund history", "Each step of a refund: approved, paid, cancelled.", [
      ["id", C.id], ["refund_id", "The refund (refunds.csv id)."], ["kind", "approved, paid, cancelled …"], ["event_on", "Date of the step."], ["method", "Payment method."], ["reference", "Reference."],
      ["reason", "Reason."], ["note", "Note."], ["set_off_cents", "Amount set off at this step, in cents."], ["actor", C.who("Who did it")], ["created_at", C.created]]],
    ["centre_late_fees", "late_fees.csv", "Late fees", "Late fees proposed, charged or waived.", [
      ["id", C.id], ["invoice_id", "The overdue invoice."], ["month_no", "Which month overdue."], ["fee_date", "Date of the fee."], ["status", "Proposed, charged or waived."], ["fee_cents", "Fee, in cents."],
      ["base_cents", "Amount the fee was worked out on, in cents."], ["rule", "The rule applied (structured text)."], ["household_id", "The family."], ["student_id", "The student."],
      ["document_id", "The invoice the fee was put on."], ["decided_by", C.who("Who decided")], ["decided_at", "When (UTC)."], ["reason", "Reason."], ["created_at", C.created]]],
    ["org_counters", "invoice_number_counters.csv", "Invoice number counters", "The next number for invoices and credit notes.", [
      ["series", "invoice or credit_note."], ["next_number", "The next number to be used."], ["locked", "True once a number has been issued."], ["created_at", C.created]]],
    ["org_invite_mail_log", "invitation_emails_sent.csv", "Invitation emails sent", "When invitation emails were sent to tutors and staff, and whether they were delivered.", [
      ["id", C.id], ["membership_id", "The person invited (people_tutors_and_staff.csv id)."], ["sent_by", C.who("Who sent it")], ["sent_at", "When (UTC)."], ["status", "sent, failed …"]]],
    ["materials", "materials.csv", "Teaching materials (list only)", "The list of teaching materials. The files themselves are not part of this export yet.", [
      ["id", C.id], ["subject", "Subject."], ["level", "Level."], ["stream", "Stream."], ["topic", "Topic."], ["title", "Title."], ["kind", "Kind of material."], ["file_name", "File name."], ["size_bytes", "Size."], ["created_at", C.created]]],
    ["org_settings", "settings_history.csv", "Settings history", "Every version of the centre's settings, with the date each took effect.", [
      ["id", C.id], ["version", "Version number."], ["schema_version", "Settings layout version."], ["effective_from", "Date this version took effect."], ["settings", "The full settings (structured text)."],
      ["created_by", C.who("Who saved it")], ["created_at", C.created]]],
    ["org_plans", "fee_plans.csv", "TutorDeck fee plans", "The fee terms TutorDeck charges the centre.", [
      ["id", C.id], ["plan_code", "Plan name."], ["base_cents", "Monthly base fee, in cents."], ["per_student_cents", "Fee per billable student, in cents."], ["effective_from", "Date it took effect."],
      ["billing_method", "stripe or invoice."], ["billing_starts_on", "First billing month (before it: free pilot)."], ["first_month_billable_override", "Agreed number of students for the first billed month."],
      ["billing_start_reason", "Why."], ["created_at", C.created]]],
    ["platform_fee_snapshots", "monthly_fee_records.csv", "Monthly TutorDeck fee records", "What TutorDeck counted and charged each month.", [
      ["month", "The month (first day)."], ["active_students", "Active students counted."], ["billable_students", "Billable students (rounded)."], ["base_cents", "Base fee, in cents."],
      ["per_student_cents", "Per-student fee, in cents."], ["fee_cents", "Fee charged, in cents."], ["billable", "False for a free pilot month."], ["waived_reason", "Why a month was waived."],
      ["override_students", "Agreed student number used, if any."], ["computed_at", "When it was worked out (UTC)."]]],
    ["support_access_grants", "support_access.csv", "Support access", "Each time you let TutorDeck support look at your data, and until when.", [
      ["id", C.id], ["granted_by", C.who("Who gave access")], ["reason", "Reason."], ["expires_at", "Access ended or ends (UTC)."], ["revoked_at", "When it was withdrawn (UTC)."], ["created_at", C.created]]],
    ["audit_log", "audit_log.csv", "Audit log", "Who changed what and when. Passwords, links, billing-provider ids, payout numbers and login ids are removed from the before/after copies.", [
      ["id", C.id], ["at", "When (UTC)."], ["actor", C.who("Who did it")], ["action", "insert, update, delete or a named action."], ["table_name", "The table changed."], ["row_id", "The id of the row changed."],
      ["before", "The row before the change (structured text, secrets removed)."], ["after", "The row after the change (structured text, secrets removed)."]]]
  ].map(function (t) { return { tbl: t[0], file: t[1], title: t[2], about: t[3], cols: t[4] }; });
  // what is never in the export, each with its reason (the same words are in the database catalogue)
  var EXCLUDED = [
    { tbl: "centre_invoice_share", title: "Invoice share links", reason: "Invoice share links. Anyone holding one link can read that invoice, so the links are never put in a file." },
    { tbl: "org_notifications", title: "In-app notices", reason: "In-app notices addressed to individual users. They are not business records and name login accounts." },
    { tbl: "org_subscriptions", title: "Billing-provider record", reason: "TutorDeck's billing-provider record for the centre (Stripe customer and subscription ids). You can see these in your own Stripe account; the fee history is in the plan and monthly fee files." }
  ];
  var NEVER = [
    "Passwords, login tokens and anything from the login system.",
    "Login ids: every \"who\" column holds the person's name instead.",
    "Other centres' data: the export is for your centre only.",
    "Google calendar ids, mail-provider message ids and payment-proof file paths.",
    "Payout account numbers and holder names, unless the owner ticked \"include full payout numbers\" (masked as •••••1234 otherwise)."
  ];
  var PROMISE = "Self-service export of all records (CSV, owner only, excludes passwords and billing-provider ids)";
  var PDPA = "This export contains families' names, phone numbers and email addresses (parents and guardians). That is personal data under the PDPA: store the file somewhere private, share it only with people who need it, and delete it when you no longer need it.";

  function catalogByTable() { var m = {}; CATALOG.forEach(function (t) { m[t.tbl] = t; }); return m; }

  // ------------------------------------------------------------------ CSV
  // columns that end in _cents get a dollars column right after them (cents / 100, exact, two decimals)
  function outputColumns(cols) {
    var out = [];
    cols.forEach(function (c) { out.push(c); if (/_cents$/.test(c)) out.push(c.replace(/_cents$/, "_dollars")); });
    return out;
  }
  function centsToDollars(v) {
    if (v === null || v === undefined || v === "") return "";
    var n = typeof v === "number" ? v : Number(v);
    if (!isFinite(n) || Math.floor(n) !== n) return "";
    var neg = n < 0, a = Math.abs(n), whole = Math.floor(a / 100), frac = a % 100;
    return (neg ? "-" : "") + whole + "." + (frac < 10 ? "0" : "") + frac;
  }
  var NUMERIC = /^[+-]?\d+(\.\d+)?$/;
  // text that a spreadsheet could read as a formula gets a leading apostrophe (OWASP "CSV injection"); plain numbers are left alone
  function guard(s) { return /^[=+\-@\t\r]/.test(s) && !NUMERIC.test(s) ? "'" + s : s; }
  function cellText(v) {
    if (v === null || v === undefined) return "";
    if (typeof v === "boolean") return v ? "true" : "false";
    if (typeof v === "number") return String(v);
    if (Array.isArray(v)) return guard(v.every(function (x) { return x === null || typeof x !== "object"; }) ? v.map(function (x) { return x === null ? "" : String(x); }).join("; ") : JSON.stringify(v));
    if (typeof v === "object") return JSON.stringify(v);
    return guard(String(v));
  }
  function csvCell(v) {
    var s = cellText(v);
    return /[",\r\n]/.test(s) || /^\s|\s$/.test(s) ? "\"" + s.replace(/"/g, "\"\"") + "\"" : s;
  }
  function csvLine(cells) { return cells.map(csvCell).join(",") + "\r\n"; }
  // one page of database rows (arrays in column order) -> CSV text, with the dollars columns added
  function csvRows(cols, rows) {
    var out = "";
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i], cells = [];
      for (var j = 0; j < cols.length; j++) { cells.push(r[j]); if (/_cents$/.test(cols[j])) cells.push(centsToDollars(r[j])); }
      out += csvLine(cells);
    }
    return out;
  }
  function csvHeader(cols) { return "﻿" + csvLine(outputColumns(cols)); }

  // ------------------------------------------------------------------ CRC-32 and ZIP
  var TABLE = (function () { var t = new Uint32Array(256); for (var n = 0; n < 256; n++) { var c = n; for (var k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
  function crc32(bytes, prev) { var c = (prev === undefined ? 0 : prev) ^ 0xFFFFFFFF; for (var i = 0; i < bytes.length; i++) c = TABLE[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; }
  var enc = new TextEncoder();
  function dosTime(d) { return [((d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1)) & 0xFFFF, (((Math.max(d.getFullYear(), 1980) - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate()) & 0xFFFF]; }
  function u16(n) { return new Uint8Array([n & 255, (n >>> 8) & 255]); }
  function u32(n) { return new Uint8Array([n & 255, (n >>> 8) & 255, (n >>> 16) & 255, (n >>> 24) & 255]); }
  function cat(list) { var n = 0; list.forEach(function (a) { n += a.length; }); var o = new Uint8Array(n), p = 0; list.forEach(function (a) { o.set(a, p); p += a.length; }); return o; }

  // A ZIP being built. addFile takes the file as an async-free list of text chunks produced by `fill(push)` so a big table never exists as one string.
  function ZipWriter(opts) {
    this.parts = []; this.entries = []; this.offset = 0; this.compress = !opts || opts.compress !== false; this.now = (opts && opts.now) || new Date();
  }
  ZipWriter.prototype.canCompress = function () { return this.compress && typeof CompressionStream === "function" && typeof Response === "function"; };
  // chunks: array of strings or Uint8Arrays (already produced); returns a promise
  ZipWriter.prototype.addBlobParts = async function (name, chunks, crc, size) {
    var raw = new Blob(chunks), method = 0, body = raw, csize = size;
    if (size > 0 && this.canCompress()) {
      try { body = await new Response(raw.stream().pipeThrough(new CompressionStream("deflate-raw"))).blob(); if (body.size < size) { method = 8; csize = body.size; } else body = raw; }
      catch (e) { body = raw; method = 0; }
    }
    if (this.offset + csize > 0xFFFFFFF0 || this.entries.length > 65000) throw new Error("This export is too big for one ZIP file. Please contact TutorDeck support.");
    var nm = enc.encode(name), t = dosTime(this.now);
    var header = cat([u32(0x04034b50), u16(20), u16(0x0800), u16(method), u16(t[0]), u16(t[1]), u32(crc), u32(csize), u32(size), u16(nm.length), u16(0), nm]);
    this.entries.push({ nm: nm, method: method, time: t, crc: crc, csize: csize, size: size, offset: this.offset });
    this.parts.push(header, body); this.offset += header.length + csize;
  };
  ZipWriter.prototype.addText = function (name, text) { var b = enc.encode(text); return this.addBlobParts(name, [b], crc32(b), b.length); };
  // a file built from pages: `produce(emit)` calls emit(textChunk) as pages arrive; resolves when produce does. Hash and size are kept as it goes.
  ZipWriter.prototype.addStreamed = async function (name, produce) {
    var chunks = [], pending = [], pendingBytes = 0, crc = 0, size = 0;       // pages are handed to Blobs every ~2 MB, so the browser (not this script) holds the bulk
    await produce(function (text) {
      if (!text) return; var b = enc.encode(text); crc = crc32(b, crc); size += b.length; pending.push(b); pendingBytes += b.length;
      if (pendingBytes >= 2097152) { chunks.push(new Blob(pending)); pending = []; pendingBytes = 0; }
    });
    if (pending.length) chunks.push(new Blob(pending));
    await this.addBlobParts(name, chunks, crc, size);
    return size;
  };
  ZipWriter.prototype.finish = function () {
    var cd = [], cdSize = 0, self = this;
    this.entries.forEach(function (e) {
      var h = cat([u32(0x02014b50), u16(20), u16(20), u16(0x0800), u16(e.method), u16(e.time[0]), u16(e.time[1]), u32(e.crc), u32(e.csize), u32(e.size), u16(e.nm.length), u16(0), u16(0), u16(0), u16(0), u32(0), u32(e.offset), e.nm]);
      cd.push(h); cdSize += h.length;
    });
    var end = cat([u32(0x06054b50), u16(0), u16(0), u16(this.entries.length), u16(this.entries.length), u32(cdSize), u32(self.offset), u16(0)]);
    return new Blob(this.parts.concat(cd, [end]), { type: "application/zip" });
  };

  // ------------------------------------------------------------------ the README and the data dictionary
  function colList(t) { return t.cols.map(function (c) { return c[0]; }); }
  function dictionaryText(opts) {
    opts = opts || {}; var counts = opts.counts || null, L = [];
    L.push("What each file and column means");
    L.push("");
    L.push("• Money: every amount ending in _cents is whole cents (1250 = S$12.50). Next to each one the file has a matching _dollars column (12.50) for spreadsheets.");
    L.push("• Dates are YYYY-MM-DD. Times of day are as entered. Timestamps (created_at and similar) are in UTC, written like 2026-11-27T08:25:04+00:00.");
    L.push("• Ids (long codes) join the files: a lesson's student_id is a student's id. \"Looked up for you\" columns repeat the name so you do not have to join.");
    L.push("• \"True\"/\"false\" are written in full. Text a spreadsheet could mistake for a formula (starting with = + - @) gets a leading apostrophe.");
    L.push("• Columns marked \"structured text\" hold small data records as JSON text; most people can ignore them.");
    L.push("");
    CATALOG.forEach(function (t) {
      L.push(t.file + (counts && counts[t.tbl] !== undefined ? "  (" + counts[t.tbl] + " rows)" : "") + " — " + t.title);
      L.push("  " + t.about);
      t.cols.forEach(function (c) { L.push("  " + c[0] + (/_cents$/.test(c[0]) ? " (+ " + c[0].replace(/_cents$/, "_dollars") + ")" : "") + " — " + c[1]); });
      L.push("");
    });
    return L.join("\n");
  }
  function exclusionText() {
    var L = ["Not in this export, and why", ""];
    NEVER.forEach(function (n) { L.push("• " + n); });
    EXCLUDED.forEach(function (e) { L.push("• " + e.title + ": " + e.reason); });
    return L.join("\n");
  }
  function readmeText(info) {
    var L = [];
    L.push("TutorDeck data export" + (info.centre ? " — " + info.centre : ""));
    L.push("Exported " + info.at + " by the centre owner.");
    L.push("Payout account numbers: " + (info.fullPayout ? "FULL (the owner ticked \"include full payout numbers\")." : "masked (•••••1234)."));
    L.push("");
    L.push("PDPA: " + PDPA);
    L.push("");
    L.push(PROMISE + ".");
    L.push("");
    L.push(exclusionText());
    L.push("");
    L.push(dictionaryText({ counts: info.counts }));
    return L.join("\r\n").replace(/\r?\n/g, "\r\n");
  }
  // docs/centre-data-export-dictionary.md — generated, never edited by hand (tests/gen-export-dictionary.js)
  function dictionaryMarkdown() {
    var L = ["# Centre data export: data dictionary", "",
      "<!-- GENERATED by `node tests/gen-export-dictionary.js` from assets/js/org-export-core.js. Do not edit by hand: tests/org-export-core.test.js fails when this file is out of date. -->", "",
      "Promise (owner's wording): **" + PROMISE + ".**", "",
      "Who: the centre **owner** only (active owner of a centre). Staff, tutors, parents, other centres' owners, solo tutors and platform admins get nothing. Every export is audited (who, when, tables, row counts; never data). Where: Settings → Data export (`org?id=…#export`).", "",
      "Format: one UTF-8 CSV per table (with a byte-order mark so Excel reads names correctly) plus `README.txt`, all in one ZIP built in the browser. Money columns ending `_cents` are whole cents and get a `_dollars` column next to them.", "",
      "> " + PDPA, "",
      "## Never exported", ""];
    NEVER.forEach(function (n) { L.push("- " + n); });
    EXCLUDED.forEach(function (e) { L.push("- **" + e.title + "** (`" + e.tbl + "`): " + e.reason); });
    L.push("");
    L.push("## Files", "", "| File | Table | What it holds |", "|---|---|---|");
    CATALOG.forEach(function (t) { L.push("| `" + t.file + "` | `" + t.tbl + "` | " + t.title + " |"); });
    L.push("");
    CATALOG.forEach(function (t) {
      L.push("## `" + t.file + "` — " + t.title, "", t.about, "", "| Column | Meaning |", "|---|---|");
      outputColumns(colList(t)).forEach(function (c) {
        var base = t.cols.filter(function (x) { return x[0] === c; })[0];
        L.push("| `" + c + "` | " + (base ? base[1] : "The same amount in dollars (`" + c.replace(/_dollars$/, "_cents") + " ÷ 100`).").replace(/\|/g, "\\|") + " |");
      });
      L.push("");
    });
    return L.join("\n");
  }

  // ------------------------------------------------------------------ words for the database's refusals
  function errorText(e) {
    var m = String((e && e.message) || e || "");
    if (/NOT_FOUND/.test(m)) return "Only the centre's owner can export its data.";
    if (/too many exports/i.test(m)) return "You have started a lot of exports in the last hour. Please wait a little and try again.";
    if (/finished/i.test(m)) return "That export had already finished. Please start a new one.";
    if (/Failed to fetch|NetworkError|network/i.test(m)) return "The connection dropped. Please check your internet and try again.";
    if (/timeout|statement/i.test(m)) return "The database took too long to answer. Please try again in a minute.";
    return "The export could not be completed: " + m.replace(/^NOT_ALLOWED:\s*/, "");
  }
  function fileStamp(d) { var p = function (n) { return (n < 10 ? "0" : "") + n; }; return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()); }
  function slug(s) { return String(s || "centre").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "centre"; }
  var PAGE = { lessons: 1000, audit_log: 1000, recurring_slots: 1000 };
  function pageSize(tbl) { return PAGE[tbl] || 5000; }

  // ------------------------------------------------------------------ the whole export
  // rpc(name, args) -> Promise<{data, error}> (the Supabase client's rpc). opts: {orgId, centreName, fullPayout, onProgress(info), now(), compress, retries, wait(ms)}
  // Pages are fetched one after another; a page that fails for a network reason is retried (with a pause) before giving up. Nothing is cached between tables.
  async function runExport(rpc, opts) {
    var now = (opts.now ? opts.now() : new Date()), retries = opts.retries === undefined ? 3 : opts.retries, wait = opts.wait || function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };
    var progress = opts.onProgress || function () {};
    async function call(name, args) {
      var last;
      for (var i = 0; i <= retries; i++) {
        var r; try { r = await rpc(name, args); } catch (e) { r = { error: e }; }       // (the Supabase builder is a thenable, not a Promise: no .catch)
        if (!r.error) return r.data;
        last = r.error;
        if (/NOT_FOUND|NOT_ALLOWED|P0001|42501/.test(String(last.message || "") + String(last.code || ""))) break;     // a refusal is final; only network trouble is retried
        await wait(400 * (i + 1) * (i + 1));
      }
      throw last;
    }
    var st = await call("org_export_start", { p_org: opts.orgId, p_full_payout: !!opts.fullPayout });
    var byTbl = catalogByTable(), known = {}; st.tables.forEach(function (t) { known[t.tbl] = t.rows; });
    var zip = new ZipWriter({ now: now, compress: opts.compress }), counts = {}, total = 0, expectedTotal = 0, tables = st.tables.filter(function (t) { return byTbl[t.tbl]; });
    tables.forEach(function (t) { expectedTotal += t.rows; });
    var unknown = st.tables.filter(function (t) { return !byTbl[t.tbl]; }).map(function (t) { return t.tbl; });
    if (unknown.length) throw new Error("The database lists tables this page does not know yet (" + unknown.join(", ") + "). Please reload the page and try again.");
    for (var ti = 0; ti < tables.length; ti++) {
      var tb = tables[ti], meta = byTbl[tb.tbl], names = colList(meta), n = 0;
      progress({ phase: "table", table: tb.tbl, file: meta.file, index: ti, of: tables.length, done: total, expected: expectedTotal });
      await zip.addStreamed(meta.file, async function (emit) {
        emit(csvHeader(names));
        var after = null;
        for (;;) {
          var page = await call("org_export_page", { p_org: opts.orgId, p_job: st.job, p_table: tb.tbl, p_after: after, p_limit: pageSize(tb.tbl) });
          if (page.cols.join(",") !== names.join(",")) throw new Error("The database's columns for " + meta.file + " differ from this page's list. Please reload the page and try again.");
          emit(csvRows(names, page.rows)); n += page.rows.length; total += page.rows.length;
          progress({ phase: "rows", table: tb.tbl, file: meta.file, index: ti, of: tables.length, done: total, expected: expectedTotal });
          after = page.next; if (after === null || after === undefined) break;
        }
      });
      counts[tb.tbl] = n;
    }
    progress({ phase: "finishing", done: total, expected: expectedTotal });
    var fin = await call("org_export_finish", { p_org: opts.orgId, p_job: st.job, p_counts: counts });
    await zip.addText("README.txt", readmeText({ centre: opts.centreName, at: now.toISOString(), fullPayout: !!st.full_payout, counts: counts }));
    var blob = zip.finish();
    return { blob: blob, filename: "tutordeck-export-" + slug(opts.centreName) + "-" + fileStamp(now) + ".zip", counts: counts, rows: total, matched: !!(fin && fin.matched), differs: (fin && fin.differs) || [], job: st.job, fullPayout: !!st.full_payout };
  }

  return { CATALOG: CATALOG, EXCLUDED: EXCLUDED, NEVER: NEVER, PROMISE: PROMISE, PDPA: PDPA, catalogByTable: catalogByTable, outputColumns: outputColumns, centsToDollars: centsToDollars, cellText: cellText, csvCell: csvCell,
           csvLine: csvLine, csvRows: csvRows, csvHeader: csvHeader, crc32: crc32, ZipWriter: ZipWriter, dictionaryText: dictionaryText, exclusionText: exclusionText, readmeText: readmeText,
           dictionaryMarkdown: dictionaryMarkdown, errorText: errorText, fileStamp: fileStamp, slug: slug, pageSize: pageSize, runExport: runExport };
});
