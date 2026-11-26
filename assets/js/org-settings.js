// Organisation settings — the full, typed schema behind the setup wizard (steps 1–10) and Settings.
// Every option in the brief is here from day one; features not built yet are marked `soon` and shown as
// "coming soon". Stored per organisation as versioned rows in org_settings (see db/migration_org_foundation.sql,
// whose org_validate_settings() checks the same enums). Money is cents, rates are basis points.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.OrgSettings = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  var SCHEMA_VERSION = 1;

  // keep in sync with org_invite() in the migration (a test checks this)
  var STAFF_PERMISSIONS = [
    { key: "manage_timetable", label: "Manage timetable" },
    { key: "manage_students",  label: "Manage students & families" },
    { key: "manage_tutors",    label: "Manage tutors" },
    { key: "issue_invoices",   label: "Issue invoices" },
    { key: "record_payments",  label: "Record payments" },
    { key: "view_revenue",     label: "View revenue" },
    { key: "run_tutor_pay",    label: "Run tutor pay" },
    { key: "view_audit_log",   label: "View the audit log" }
  ];

  function o(v, l) { return [v, l]; }
  // Nothing in the app reads these settings yet (T18 plan, 2026-11-24): shown as "coming soon" so the wizard promises nothing it does not do.
  var CREDITS_SOON = "Make-up credits come in a later update; for now a make-up is added as a normal lesson.";
  // Centre money (T4, steps S0-S8): the options exist from S0 so owners can see what is coming; nothing reads them until their step ships.
  var DEPOSIT_HELP = "A refundable deposit is money you hold for the family, not income. It is invoiced separately, once, with a student's first invoice. When a student leaves, it is refunded, kept against unpaid invoices or kept by the centre, always approved and recorded step by step. A top-up, and using it as the final month's fee, come in a later update.";
  var LATE_HELP = "When a lesson invoice is still unpaid after its grace period, TutorDeck suggests a late fee. A person approves or waives each one (a reason is needed to waive); nothing is added to a family’s bill on its own. An approved fee is its own small invoice. Adding it as a line on the family’s next invoice comes in a later update.";
  var PAY_SOON = "Percentage pay and pay runs come in a later update.";
  var HOLIDAYS_SOON = "Skipping holidays comes in a later update; for now cancel or delete a holiday lesson by hand.";
  // Field: { path, label, type, options?, help?, soon?, show?(s) }
  // types: text, email, color, toggle, select, number, money (cents), percent (bp), days, list (number list),
  //        note (a paragraph), group (a sub-heading; no value)
  // groupOnly: true / groupOnlyOptions: [...] = only for centres that run group classes (hidden when lessons.class_type is one_to_one)
  var STEPS = [
    { id: "profile", n: 1, title: "Organisation profile", fields: [
      { path: "profile.legal_name", label: "Legal name", type: "text" },
      { path: "profile.trading_name", label: "Trading name", type: "text", required: true },
      { path: "profile.uen", label: "UEN", type: "text" },
      { path: "profile.address", label: "Address", type: "text" },
      { path: "profile.logo_path", label: "Logo", type: "text", soon: true, help: "Logo upload comes with branded invoices." },
      { path: "profile.brand_color", label: "Brand colour (invoices and your pages)", type: "color" },
      { path: "profile.gst_registered", label: "GST registered", type: "toggle" },
      { path: "profile.gst_number", label: "GST registration number", type: "text", show: function (s) { return s.profile.gst_registered; } },
      { path: "profile.gst_rate_bp", label: "GST rate", type: "percent", show: function (s) { return s.profile.gst_registered; } },
      { path: "profile.gst_inclusive", label: "Prices are entered", type: "select", options: [o(false, "Excluding GST"), o(true, "Including GST")],
        show: function (s) { return s.profile.gst_registered; } },
      { path: "profile.timezone", label: "Timezone", type: "select", options: [o("Asia/Singapore", "Singapore (GMT+8)")] },
      { path: "profile.currency", label: "Currency", type: "select", options: [o("SGD", "SGD")] },
      { path: "profile.invoice_prefix", label: "Invoice number prefix", type: "text" },
      { path: "profile.next_invoice_number", label: "Next invoice number", type: "number",
        help: "Used when centre invoicing launches: set it to carry on from your old invoice sheet. Invoices are numbered in one unbroken series, so it can only be set before your first invoice." },
      { path: "profile.reply_to_email", label: "Reply-to email for parent emails", type: "email" },
      { path: "lessons.class_type", label: "Classes you run", type: "select", options: [
        o("one_to_one", "1-to-1 lessons only"), o("group", "Group classes only"), o("both", "Both 1-to-1 and group")],
        help: "1-to-1 centres don't see options that only apply to group classes." }
    ]},
    { id: "calendar", n: 2, title: "Branches, rooms and calendar", custom: "calendar", fields: [
      { path: "calendar.skip_holidays", label: "Don't generate lessons on centre holidays", type: "toggle", soon: true, help: HOLIDAYS_SOON }
    ]},
    { id: "users", n: 3, title: "Users and permissions", custom: "users", fields: [] },
    { id: "billing", n: 4, title: "How lessons are billed", fields: [
      { path: "billing.model", label: "Default billing model", type: "select", options: [
        o("prepaid_packages", "Prepaid packages — parents buy lessons in advance"),
        o("fixed_in_advance", "Fixed fee in advance — per month or term, before it starts"),
        o("postpaid_lessons", "Postpaid — after the month, for lessons held"),
        o("pay_per_lesson", "Pay per lesson — an invoice per lesson or week")] },
      { path: "billing.fixed_period", label: "Fixed fee period", type: "select", options: [o("month", "Per month"), o("term", "Per term")],
        show: function (s) { return s.billing.model === "fixed_in_advance"; } },
      { path: "billing.pay_per_lesson_grouping", label: "Invoice", type: "select", options: [o("lesson", "Every lesson"), o("week", "Every week")],
        show: function (s) { return s.billing.model === "pay_per_lesson"; } },
      { path: "billing.low_balance_credits", label: "Warn parents when credits fall to", type: "number", soon: true, help: CREDITS_SOON,
        show: function (s) { return s.billing.model === "prepaid_packages"; } },
      { path: "billing.credit_expiry_days", label: "Credits expire after (days, 0 = never)", type: "days", soon: true, help: CREDITS_SOON,
        show: function (s) { return s.billing.model === "prepaid_packages"; } },
      { path: "billing.fee_plans_note", label: "Fee plans (per lesson / month / term, by level, subject, class type or duration)", type: "note", soon: true,
        help: "You'll set up fee plans with your classes." },
      { path: "billing.absences.mode", label: "Absent lessons", type: "select", options: [
        o("charged", "Charged"), o("not_charged", "Not charged"), o("charged_unless_notice", "Charged unless notice was given")] },
      { path: "billing.absences.notice_hours", label: "Notice needed (hours before)", type: "number",
        show: function (s) { return s.billing.absences.mode === "charged_unless_notice"; } },
      { path: "billing.makeups.allowed", label: "Makeup lessons allowed", type: "toggle", soon: true, help: CREDITS_SOON },
      { path: "billing.makeups.per_period", label: "Makeups per period", type: "number", soon: true, help: CREDITS_SOON, show: function (s) { return s.billing.makeups.allowed; } },
      { path: "billing.makeups.uses_credit", label: "A makeup uses a credit", type: "toggle", soon: true, help: CREDITS_SOON, show: function (s) { return s.billing.makeups.allowed; } },
      { path: "billing.proration", label: "Joining or leaving mid-period", type: "select", options: [
        o("by_remaining", "Prorate by remaining lessons"), o("full", "Charge the full period"), o("skip", "Skip the partial period")] },
      { path: "billing.sibling_discount.type", label: "Sibling discount (2nd child onwards)", type: "select", options: [
        o("none", "None"), o("percent", "Percentage"), o("fixed", "Fixed amount per lesson")] },
      { path: "billing.sibling_discount.percent_bp", label: "Discount", type: "percent", show: function (s) { return s.billing.sibling_discount.type === "percent"; } },
      { path: "billing.sibling_discount.fixed_cents", label: "Discount", type: "money", show: function (s) { return s.billing.sibling_discount.type === "fixed"; } },
      { path: "billing.adhoc_discounts", label: "Allow one-off discounts (with a reason)", type: "toggle" },
      { path: "billing.one_off_fees.registration_cents", label: "Registration fee", type: "money" },
      { path: "billing.one_off_fees.materials_cents", label: "Materials fee", type: "money" },
      { path: "billing.trials.charged", label: "Charge for trial lessons", type: "toggle", soon: true,
        help: "Off means trial lessons are free. Charging trials comes with centre invoicing." },
      { type: "group", label: "Refundable deposit", help: DEPOSIT_HELP },
      { path: "billing.deposit.mode", label: "Deposit", type: "select", options: [
        o("none", "No deposit"), o("fixed", "A fixed amount"), o("percent_first_month", "A percentage of the first month's fee")] },
      { path: "billing.one_off_fees.deposit_cents", label: "Deposit amount", type: "money",
        show: function (s) { return s.billing.deposit.mode === "fixed"; } },
      { path: "billing.deposit.percent_bp", label: "Deposit as a share of the first month's fee", type: "percent",
        show: function (s) { return s.billing.deposit.mode === "percent_first_month"; },
        help: "For example 50% of the first month's lesson fee. The amount is worked out once, with the first invoice, and then stays fixed." },
      { path: "billing.deposit.taxable", label: "Charge GST on the deposit when it is received", type: "toggle",
        help: "Normally off: a refundable deposit is held for the family and is not income. Ask your accountant." },
      { path: "billing.deposit.due", label: "Deposit is invoiced", type: "select", options: [
        o("with_first_invoice", "Together with the first lesson invoice"), o("before_first_lesson", "Before the first lesson")],
        soonOptions: ["before_first_lesson"] },
      { path: "billing.deposit.waived_by", label: "A deposit can be waived by", type: "select", options: [
        o("owner", "The owner"), o("issue_invoices", "Staff who issue invoices"), o("nobody", "Nobody")],
        help: "Waiving always needs a reason." },
      { path: "billing.deposit.top_up", label: "Ask for a top-up when the required deposit goes up", type: "toggle", soon: true,
        help: "For example a returning student, or a fee increase." },
      { path: "billing.deposit.release", label: "When a student leaves, TutorDeck suggests", type: "select", options: [
        o("refund_full", "Refunding the whole deposit"), o("refund_less_unpaid", "Keeping it against any unpaid invoices, refunding the rest"), o("admin_decides", "Nothing, an admin decides")],
        help: "Only a suggestion: staff can change the amounts, and the refund still needs approval. A deposit that carried GST is refunded, never kept against invoices." },
      { path: "billing.deposit.forfeit_notice_days", label: "Notice needed to get the deposit back (days, 0 = none needed)", type: "days",
        help: "Leaving with less notice suggests keeping the deposit. An admin always confirms." },
      { path: "billing.deposit.set_off_unpaid", label: "Staff may use the deposit to cover unpaid fees", type: "toggle", soon: true },
      { path: "billing.deposit.final_month", label: "Family may use the deposit as the final month's fee", type: "toggle", soon: true },
      { path: "billing.deposit.refund_approved_by", label: "Refunds are approved by", type: "select", options: [
        o("owner", "The owner"), o("staff", "Any staff member who handles that kind of refund"), o("four_eyes", "Someone other than the person who asked")],
        help: "Deposit refunds are handled by the owner and staff who issue invoices; refunds of family credit by the owner and staff who record payments. A refund is paid and recorded only after it is approved. “Someone other than the person who asked” needs a second approver: it can be chosen only while the centre has the owner, a staff member who issues invoices and a staff member who records payments, all switched on. If one of them is later removed, switched off or loses that permission, TutorDeck changes this back to “The owner” and tells the owner." },
      { type: "group", label: "Late fees", help: LATE_HELP },
      { path: "billing.late_fee.enabled", label: "Late fee", type: "toggle" },
      { path: "billing.late_fee.repeat", label: "How often", type: "select", options: [
        o("none", "Never"), o("once", "Once per invoice"), o("monthly", "Every month the invoice stays unpaid")] },
      { path: "billing.late_fee.type", label: "Late fee is", type: "select", options: [
        o("fixed", "A fixed amount"), o("percent", "A percentage of what is still unpaid")] },
      { path: "billing.late_fee.amount_cents", label: "Late fee amount", type: "money" },
      { path: "billing.late_fee.percent_bp", label: "Late fee percentage", type: "percent" },
      { path: "billing.late_fee.after_days", label: "Grace period after the due date (days)", type: "days",
        help: "Paying on the due date, or within this many days after it, is on time." },
      { path: "billing.late_fee.cap_cents", label: "Most late fees one invoice can collect (0 = no limit)", type: "money" },
      { path: "billing.late_fee.show_as", label: "A late fee is added as", type: "select", options: [
        o("next_invoice_line", "A line on the family's next invoice"), o("own_invoice", "Its own small invoice")],
        soonOptions: ["next_invoice_line"] },
      { path: "billing.late_fee.waived_by", label: "A late fee can be waived by", type: "select", options: [
        o("owner", "The owner"), o("issue_invoices", "Staff who issue invoices")],
        help: "TutorDeck suggests late fees; a person applies or waives each one. Make sure your terms for parents mention late fees." }
    ]},
    { id: "invoicing", n: 5, title: "Invoicing", fields: [
      { path: "invoicing.grouping", label: "One invoice per", type: "select", options: [o("family", "Family (household)"), o("student", "Student")] },
      { path: "invoicing.generate.mode", label: "Create invoices", type: "select", options: [o("day_of_month", "On a day of the month"), o("days_before", "Some days before each period")] },
      { path: "invoicing.generate.day", label: "Day of month", type: "number", show: function (s) { return s.invoicing.generate.mode === "day_of_month"; } },
      { path: "invoicing.generate.days_before", label: "Days before the period", type: "days", show: function (s) { return s.invoicing.generate.mode === "days_before"; } },
      { path: "invoicing.due_days", label: "Payment due (days after the invoice date)", type: "days" },
      { path: "invoicing.review_before_sending", label: "Create as drafts for an admin to approve", type: "toggle" },
      { path: "invoicing.delivery.email", label: "Email parents a secure link", type: "toggle", soon: true },
      { path: "invoicing.delivery.share_link", label: "Shareable link for WhatsApp", type: "toggle" },
      { path: "invoicing.whatsapp_template", label: "WhatsApp message for an invoice", type: "textarea",
        help: "Your own wording. {name} {centre} {number} {amount} {due_date} {link} are filled in for each invoice. Leave it as it is to use the standard message." },
      { path: "invoicing.reminders.enabled", label: "Payment reminders", type: "toggle", soon: true },
      { path: "invoicing.reminders.schedule", label: "Remind (days from due date, e.g. -3, 0, 7)", type: "list", soon: true,
        show: function (s) { return s.invoicing.reminders.enabled; } }
    ]},
    { id: "payments", n: 6, title: "How parents pay", fields: [
      { path: "payments.modes", label: "Ways to pay", type: "multi", options: [
        o("manual_paynow", "Manual PayNow — admin marks invoices paid"),
        o("statement_matching", "Bank statement matching"),
        o("hitpay", "HitPay — your own account, “Pay now” link"),
        o("stripe", "Stripe — your own account, “Pay now” link")],
        soonOptions: ["statement_matching", "hitpay", "stripe"],
        help: "Cash, bank transfer and cheque can always be recorded by hand. Money always goes straight to your account." },
      { path: "payments.paynow.type", label: "PayNow to", type: "select", options: [o("uen", "UEN"), o("mobile", "Mobile number")] },
      { path: "payments.paynow.id", label: "PayNow UEN or number", type: "text" },
      { path: "payments.statement_bank", label: "Bank for statement matching", type: "select", soon: true,
        options: [o("DBS", "DBS"), o("OCBC", "OCBC"), o("UOB", "UOB"), o("custom", "Custom CSV columns")] },
      { path: "payments.hitpay.paynow", label: "HitPay: PayNow", type: "toggle", soon: true },
      { path: "payments.hitpay.cards", label: "HitPay: cards (higher fees)", type: "toggle", soon: true },
      { path: "payments.gateway_fees", label: "Gateway fees", type: "select", options: [o("absorb", "Absorbed by the centre"), o("pass_on", "Passed on as a separate line")] },
      { path: "payments.partial_payments", label: "Allow partial payments", type: "toggle" },
      { path: "payments.overpayments", label: "Overpayments", type: "select", options: [o("credit", "Kept as credit for the family"), o("refund", "Refunded manually")] }
    ]},
    { id: "lessons", n: 7, title: "Tutors and lessons", fields: [
      { path: "lessons.timetable_editing", label: "Who edits the timetable", type: "select", options: [o("admin_only", "Admins only"), o("tutors_own", "Tutors may edit their own lessons")],
        soonOptions: ["tutors_own"] },
      { path: "lessons.attendance_by", label: "Attendance is marked by", type: "select", options: [o("tutor", "The tutor"), o("admin", "An admin")] },
      { path: "lessons.attendance_window_days", label: "Tutors can mark or change attendance for (days after the lesson)", type: "number",
        help: "From the lesson's day, for this many days. After that only an admin can." },
      { path: "lessons.cancellations_marked_by", label: "Cancellations (in time or late) are marked by", type: "select", options: [o("admin", "An admin"), o("tutor", "The tutor")],
        help: "Whether a cancellation counts as late depends on your own cancellation policy, so most centres let an admin decide." },
      { path: "lessons.compensation_entered_by", label: "For an absent or cancelled lesson, the charge (compensation) is entered by", type: "select", options: [o("admin", "An admin"), o("tutor", "The tutor")],
        help: "Whoever marks it types the amount to charge, or 0 if the family isn't charged. Most centres keep money with admins." },
      { path: "lessons.trials_flagged_by", label: "Trial lessons are flagged by", type: "select", options: [o("admin", "An admin"), o("tutor", "The tutor")],
        help: "A trial lesson isn't counted as an active student for TutorDeck's fee." },
      { path: "lessons.remarks.required", label: "Lesson remarks are required", type: "toggle" },
      { path: "lessons.remarks.deadline_hours", label: "Remarks due within (hours after the lesson)", type: "number" },
      { path: "lessons.remarks.visibility", label: "Who sees remarks", type: "select", options: [
        o("admin_only", "Admins only"), o("parents_auto", "Sent to parents automatically"), o("parents_after_approval", "Sent to parents after admin approval")],
        soonOptions: ["parents_auto", "parents_after_approval"] },
      { path: "lessons.missed_remarks_reminders", label: "Remind tutors about missing remarks", type: "toggle", soon: true,
        help: "Reminders go by email, which comes with the email provider. Until then the My lessons page shows what's overdue." },
      { path: "lessons.replacement_tutors", label: "Admins can give one lesson to a replacement tutor", type: "toggle" },
      { path: "lessons.tutors_see_parent_contact", label: "Tutors can see parents' contact details", type: "toggle",
        help: "Tutors always see student names and levels." }
    ]},
    { id: "tutor_pay", n: 8, title: "Tutor pay", fields: [
      { path: "tutor_pay.mode", label: "Tutor pay", type: "select", options: [o("off", "Off"), o("report", "Lessons-taught report only"), o("full", "Full pay calculation")],
        soonOptions: ["full"] },
      { path: "tutor_pay.payable_when", label: "Pay tutors for a lesson", type: "select", options: [
        o("parent_paid", "Only after the parent's payment is received and reconciled"), o("taught", "As soon as it is taught")],
        help: "With the first option, unpaid lessons roll into the next pay period and show as pending. Changing this later is recorded in the audit log." },
      { path: "tutor_pay.rate_model", label: "Pay rate", type: "select", options: [
        o("per_lesson", "Per lesson"), o("per_hour", "Per hour"), o("per_student_lesson", "Per student per lesson"), o("monthly_fixed", "Fixed monthly amount"),
        o("percent_of_fee", "A percentage of the fee the family is billed")],
        soonOptions: ["percent_of_fee"], groupOnlyOptions: ["per_student_lesson"], show: function (s) { return s.tutor_pay.mode !== "off"; } },
      { path: "tutor_pay.percent_base", label: "A percentage is worked out on", type: "select", soon: true, options: [
        o("billed_after_discounts", "The fee billed, after discounts and before GST"), o("list_price", "The list price, before discounts and GST")],
        help: "Never includes GST, late fees or deposits. " + PAY_SOON },
      { path: "tutor_pay.part_payments", label: "When the family pays part of an invoice", type: "select", soon: true, options: [
        o("after_full", "Pay the tutor only once that lesson's line is fully paid"), o("pro_rata", "Pay in proportion to what was paid")],
        soonOptions: ["pro_rata"], help: PAY_SOON },
      { path: "tutor_pay.cancelled_lessons", label: "Cancelled lessons with a fixed rate", type: "select", soon: true, options: [
        o("pay_if_charged", "Pay the tutor only if the family is charged"), o("pay_rate", "Pay the usual rate"), o("pay_nothing", "Pay nothing")], help: PAY_SOON },
      { path: "tutor_pay.group_count", label: "A per-student rate counts students who were", type: "select", soon: true, groupOnly: true, options: [
        o("attended", "Present"), o("enrolled", "Enrolled")], help: PAY_SOON },
      { path: "tutor_pay.rates_note", label: "Rates", type: "note", soon: true,
        help: "Each tutor has their own rate, and you can set a different rate for one student. A new rate applies from the date you choose; lessons already taught keep the rate they had. " + PAY_SOON },
      { path: "tutor_pay.adjustments", label: "Bonuses and deductions (with a reason)", type: "toggle", show: function (s) { return s.tutor_pay.mode === "full"; } },
      { path: "tutor_pay.cycle.cutoff_day", label: "Pay period ends on day", type: "number", show: function (s) { return s.tutor_pay.mode !== "off"; } },
      { path: "tutor_pay.cycle.pay_day", label: "Pay day", type: "number", show: function (s) { return s.tutor_pay.mode === "full"; } },
      { path: "tutor_pay.payout_method", label: "Paying tutors", type: "select", options: [o("manual_list", "A list for manual transfers"), o("bank_file", "Bulk payment file for your bank")],
        soonOptions: ["bank_file"], show: function (s) { return s.tutor_pay.mode === "full"; } },
      { path: "tutor_pay.tutor_visibility", label: "Tutors see", type: "select", options: [o("running", "Running earnings during the month"), o("closed_only", "Only closed pay statements")],
        show: function (s) { return s.tutor_pay.mode !== "off"; } },
      { path: "tutor_pay.employment_note", label: "", type: "note",
        help: "Each tutor is an employee or a freelancer (set when you add them). Employees may need itemised payslips and CPF; please confirm your obligations with your accountant." }
    ]},
    { id: "import", n: 9, title: "Import data", custom: "import", fields: [] },
    { id: "review", n: 10, title: "Review and launch", custom: "review", fields: [] }
  ];

  function defaults(preset) {
    var s = {
      schema_version: SCHEMA_VERSION, preset: preset || "centre",
      profile: { legal_name: "", trading_name: "", uen: "", address: "", logo_path: null, brand_color: "#0F766E",
        gst_registered: false, gst_number: "", gst_rate_bp: 900, gst_inclusive: false, timezone: "Asia/Singapore", currency: "SGD",
        invoice_prefix: "INV", next_invoice_number: 1, reply_to_email: "" },
      calendar: { skip_holidays: true },
      billing: { model: "postpaid_lessons", fixed_period: "month", pay_per_lesson_grouping: "lesson", low_balance_credits: 2, credit_expiry_days: 0,
        absences: { mode: "charged_unless_notice", notice_hours: 24 }, makeups: { allowed: true, per_period: 2, uses_credit: false },
        proration: "by_remaining", sibling_discount: { type: "none", percent_bp: 1000, fixed_cents: 500 }, adhoc_discounts: true,
        one_off_fees: { registration_cents: 0, deposit_cents: 0, materials_cents: 0 }, trials: { charged: false },
        deposit: { mode: "none", percent_bp: 5000, taxable: false, due: "with_first_invoice", waived_by: "owner", top_up: false, release: "admin_decides",
          forfeit_notice_days: 0, set_off_unpaid: false, final_month: false, refund_approved_by: "owner" },
        late_fee: { enabled: false, repeat: "once", type: "fixed", amount_cents: 1000, percent_bp: 500, after_days: 7, cap_cents: 0, show_as: "own_invoice", waived_by: "owner" } },
      invoicing: { grouping: "family", generate: { mode: "day_of_month", day: 1, days_before: 7 }, due_days: 7, review_before_sending: true,
        delivery: { email: false, share_link: true },
        whatsapp_template: "Hi {name}, this is {centre}. Invoice {number} for {amount} is due on {due_date}.\nYou can see it and pay by PayNow here: {link}\nThank you!", reminders: { enabled: false, schedule: [-3, 0, 7] } },
      payments: { modes: ["manual_paynow"], paynow: { type: "uen", id: "" }, statement_bank: "DBS", hitpay: { paynow: true, cards: false },
        gateway_fees: "absorb", partial_payments: true, overpayments: "credit" },
      lessons: { class_type: "both", timetable_editing: "admin_only", attendance_by: "tutor", attendance_window_days: 14, cancellations_marked_by: "admin", compensation_entered_by: "admin", trials_flagged_by: "admin", remarks: { required: false, deadline_hours: 24, visibility: "admin_only" },
        missed_remarks_reminders: true, replacement_tutors: true, tutors_see_parent_contact: false },
      tutor_pay: { mode: "report", payable_when: "parent_paid", rate_model: "per_hour", percent_base: "billed_after_discounts", part_payments: "after_full", cancelled_lessons: "pay_if_charged", group_count: "attended", adjustments: true,
        cycle: { cutoff_day: 31, pay_day: 7 }, payout_method: "manual_list", tutor_visibility: "closed_only" },
      data: {}
    };
    if (preset === "solo") {
      s.billing.model = "postpaid_lessons"; s.invoicing.review_before_sending = false;
      s.lessons.attendance_by = "admin"; s.tutor_pay.mode = "off";
    }
    return s;
  }

  function get(obj, path) { return path.split(".").reduce(function (a, k) { return a == null ? undefined : a[k]; }, obj); }
  function set(obj, path, v) {
    var ks = path.split("."), last = ks.pop(), cur = obj;
    ks.forEach(function (k) { if (cur[k] == null || typeof cur[k] !== "object") cur[k] = {}; cur = cur[k]; });
    cur[last] = v; return obj;
  }
  // stored settings + any keys added to the schema since (deep, objects only; arrays/values kept)
  function withDefaults(stored, preset) {
    var d = defaults(preset || (stored && stored.preset));
    (function merge(dst, src) {
      Object.keys(src || {}).forEach(function (k) {
        if (src[k] && typeof src[k] === "object" && !Array.isArray(src[k]) && dst[k] && typeof dst[k] === "object" && !Array.isArray(dst[k])) merge(dst[k], src[k]);
        else if (src[k] !== undefined) dst[k] = src[k];
      });
    })(d, stored || {});
    return d;
  }

  // A field shows when its own rule allows it and, for group-only fields, the centre runs group classes.
  function isVisible(f, s) {
    if (f.show && !f.show(s)) return false;
    if (f.groupOnly && get(s, "lessons.class_type") === "one_to_one") return false;
    return true;
  }
  // Options of a select for the current draft: group-only choices are left out for 1-to-1 centres unless already chosen.
  function visibleOptions(f, s) {
    var v = get(s, f.path), hide = get(s, "lessons.class_type") === "one_to_one" ? (f.groupOnlyOptions || []) : [];
    return (f.options || []).filter(function (x) { return hide.indexOf(x[0]) < 0 || x[0] === v; });
  }

  function fieldOptions(f) { return (f.options || []).map(function (x) { return x[0]; }); }

  // Problems that would stop the settings being saved. Mirrors org_validate_settings() and adds detail.
  function validate(s) {
    var e = [];
    if (s.schema_version !== SCHEMA_VERSION) e.push("Unknown settings version.");
    ["profile", "calendar", "billing", "invoicing", "payments", "lessons", "tutor_pay", "data"].forEach(function (k) {
      if (!s[k] || typeof s[k] !== "object") e.push("Missing section " + k + ".");
    });
    if (e.length) return e;
    STEPS.forEach(function (st) {
      st.fields.forEach(function (f) {
        if (!f.path) return;
        var v = get(s, f.path);
        if (f.type === "select" && f.options && v !== undefined && fieldOptions(f).indexOf(v) < 0) e.push(f.label + ": pick an option.");
        if ((f.type === "money" || f.type === "number" || f.type === "days" || f.type === "percent") && v != null && !(Number.isSafeInteger(v) && v >= 0))
          e.push((f.label || f.path) + " must be a whole number, 0 or more.");
      });
    });
    var p = s.profile;
    if (!String(p.trading_name || "").trim()) e.push("Add a trading name.");
    if (p.gst_registered && !(p.gst_rate_bp >= 0 && p.gst_rate_bp <= 5000)) e.push("GST rate must be between 0% and 50%.");
    if (p.gst_registered && !String(p.gst_number || "").trim()) e.push("Add your GST registration number.");
    if (p.brand_color && !/^#[0-9A-Fa-f]{6}$/.test(p.brand_color)) e.push("Brand colour must look like #0F766E.");
    if (p.reply_to_email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(p.reply_to_email)) e.push("Reply-to email doesn't look right.");
    if (!/^[A-Za-z0-9-]{1,8}$/.test(p.invoice_prefix || "")) e.push("Invoice prefix: 1–8 letters or numbers.");
    if (!(p.next_invoice_number >= 1)) e.push("Next invoice number must be 1 or more.");
    if (!Array.isArray(s.payments.modes) || !s.payments.modes.length) e.push("Pick at least one way for parents to pay.");
    var aw = s.lessons.attendance_window_days; if (aw != null && !(Number.isSafeInteger(aw) && aw >= 1 && aw <= 60)) e.push("Attendance window must be 1–60 days.");
    var gd = s.invoicing.generate.day; if (!(gd >= 1 && gd <= 28)) e.push("Invoice day must be 1–28 (so it exists in every month).");
    var cd = s.tutor_pay.cycle; if (!(cd.cutoff_day >= 1 && cd.cutoff_day <= 31) || !(cd.pay_day >= 1 && cd.pay_day <= 31)) e.push("Pay days must be 1–31.");
    if (s.billing.sibling_discount.type === "percent" && s.billing.sibling_discount.percent_bp > 10000) e.push("Sibling discount can't be over 100%.");
    // centre money options (T4 S0); each rule is repeated in org_validate_settings() in db/migration_money_settings.sql
    var dp = s.billing.deposit, lf = s.billing.late_fee, tr = s.billing.trials;
    if (dp) {
      if (dp.percent_bp != null && !(dp.percent_bp >= (dp.mode === "percent_first_month" ? 1 : 0) && dp.percent_bp <= 10000)) e.push(dp.mode === "percent_first_month" ? "Deposit percentage must be between 0.01% and 100%." : "Deposit percentage can't be over 100%.");
      if (dp.forfeit_notice_days != null && !(dp.forfeit_notice_days >= 0 && dp.forfeit_notice_days <= 90)) e.push("Deposit notice must be 0–90 days.");
    }
    if (lf) {
      if (lf.percent_bp != null && !(lf.percent_bp >= (lf.type === "percent" ? 1 : 0) && lf.percent_bp <= 10000)) e.push(lf.type === "percent" ? "Late fee percentage must be between 0.01% and 100%." : "Late fee percentage can't be over 100%.");
      if (lf.after_days != null && !(lf.after_days >= 0 && lf.after_days <= 365)) e.push("Late fee grace period must be 0–365 days.");
    }
    if (tr && tr.charged != null && typeof tr.charged !== "boolean") e.push("Trial lessons charged must be yes or no.");
    return e;
  }

  // Billing, invoicing, payments and pay changes apply from the next billing cycle (1st of next month);
  // everything else applies today. Issued invoices are never rewritten either way.
  var CYCLE_SECTIONS = ["billing", "invoicing", "payments", "tutor_pay"];
  function effectiveFrom(before, after, todayISO) {
    var changed = CYCLE_SECTIONS.some(function (k) { return JSON.stringify(before && before[k]) !== JSON.stringify(after[k]); });
    if (!changed) return todayISO;
    var y = +todayISO.slice(0, 4), m = +todayISO.slice(5, 7);
    m += 1; if (m > 12) { m = 1; y += 1; }
    return y + "-" + (m < 10 ? "0" : "") + m + "-01";
  }


  // Four-eyes refund approval needs a SECOND person. Same rule as org_four_eyes_status() in db/migration_centre_credit_undo.sql (the database enforces it; this
  // only explains it before a save): an active owner, plus active staff who issue invoices (deposit refunds) and active staff who record payments (credit refunds).
  // `members` = rows of memberships ({ role, status, permissions, user_id }). A pending invite (no user yet) or a switched-off account doesn't count.
  function fourEyes(members) {
    var act = (members || []).filter(function (m) { return m && m.status === "active" && m.user_id; });
    var staffWith = function (perm) { return act.some(function (m) { return m.role === "staff" && (m.permissions || []).indexOf(perm) > -1; }); };
    var owner = act.some(function (m) { return m.role === "owner"; }), deposit = staffWith("issue_invoices"), credit = staffWith("record_payments");
    var need = [];
    if (!owner) need.push("an active owner");
    if (!deposit) need.push("a staff member who issues invoices (for deposit refunds)");
    if (!credit) need.push("a staff member who records payments (for credit refunds)");
    var ready = owner && deposit && credit;
    return { ready: ready, owner: owner, deposit: deposit, credit: credit, missing: need,
      reason: ready ? "" : "Not available yet: it needs a second person to approve. Add " + need.join(" and ") + " in step 3 (Users and permissions) and make sure they are switched on." };
  }

  // Human-readable value for the review step.
  function display(f, v) {
    if (f.type === "toggle") return v ? "Yes" : "No";
    if (f.type === "money") return "S$" + (Math.floor(v / 100)) + "." + ("0" + (v % 100)).slice(-2);
    if (f.type === "percent") return (v / 100) + "%";
    if (f.type === "list") return (v || []).join(", ");
    if (f.type === "multi") return (v || []).map(function (x) { var hit = (f.options || []).filter(function (op) { return op[0] === x; })[0]; return hit ? hit[1].split(" — ")[0] : x; }).join(", ");
    if (f.options) { var h = f.options.filter(function (op) { return op[0] === v; })[0]; return h ? h[1] : String(v); }
    return v == null || v === "" ? "—" : String(v);
  }

  return { SCHEMA_VERSION: SCHEMA_VERSION, STAFF_PERMISSIONS: STAFF_PERMISSIONS, STEPS: STEPS, defaults: defaults, withDefaults: withDefaults,
    get: get, set: set, validate: validate, isVisible: isVisible, visibleOptions: visibleOptions, effectiveFrom: effectiveFrom, display: display, fourEyes: fourEyes, CYCLE_SECTIONS: CYCLE_SECTIONS };
});
