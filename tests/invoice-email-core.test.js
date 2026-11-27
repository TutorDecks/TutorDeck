// node --test tests/ — the pure part of family emails (assets/js/invoice-email-core.js) and its agreement with db/migration_invoice_email.sql and the settings schema.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const E = require("../assets/js/invoice-email-core.js");
const S = require("../assets/js/org-settings.js");
const SQL = fs.readFileSync(require.resolve("../db/migration_invoice_email.sql"), "utf8");

const item = (over) => Object.assign({ kind: "invoice", name: "Mrs Tan", centre: "Alpha Tuition", reply_to: "office@alpha.example.test", templates: {},
  vars: { number: "INV-12", amount_cents: 123456, total_cents: 150000, due_date: "2026-12-07", days_overdue: 0, token: "11111111-2222-3333-4444-555555555555" } }, over || {});
const ORIGIN = "https://www.tutordeck.com.sg";

test("the placeholder list agrees with org_validate_settings() in the migration, and every default uses only allowed fields", () => {
  const m = SQL.match(/\\\{\(([a-z_|]+)\)\\\}/);
  assert.ok(m, "the validator's placeholder pattern is in the migration");
  assert.deepEqual(m[1].split("|").sort(), E.FIELDS.slice().sort());
  const msg = SQL.match(/Email wording can only use ([^']+)'/)[1].split(" ").map((x) => x.replace(/[{}]/g, "")).sort();
  assert.deepEqual(msg, E.FIELDS.slice().sort());
  for (const k of E.KINDS) for (const part of ["subject", "body"]) assert.deepEqual(E.checkTemplates({ [k]: { [part]: E.TEMPLATES[k][part] } }), [], k + " " + part);
  assert.deepEqual(Object.keys(E.TEMPLATES).sort(), E.KINDS.slice().sort());
});

test("the wording limits and the sending modes agree with the migration", () => {
  assert.match(SQL, /case tp when 'subject' then 120 else 1000 end/);
  assert.equal(E.LIMITS.subject, 120); assert.equal(E.LIMITS.body, 1000);
  assert.deepEqual(E.MODES, ["off", "staff_send", "auto_on_issue"]);
  assert.match(SQL, /not in \('off','staff_send','auto_on_issue'\)/);
  for (const [p, lo, hi] of [["first_after_days", 1, 90], ["repeat_days", 0, 90], ["max_count", 1, 10], ["daily_cap", 1, 300], ["per_hour", 1, 300]]) assert.match(SQL, new RegExp("\\{email," + (p.includes("_") && !["daily_cap", "per_hour"].includes(p) ? "reminders," : "") + p + "\\}', " + lo + ", " + hi));
});

test("the retry delays and the attempt limit agree with email_complete()", () => {
  assert.deepEqual(E.RETRY_MINUTES, [15, 60, 360]);
  assert.match(SQL, /case q\.attempts when 1 then 15 when 2 then 60 else 360 end/);
  assert.equal(E.MAX_ATTEMPTS, 3);
  assert.match(SQL, /p_outcome = 'retry' and q\.attempts >= 3/);
  assert.equal(E.retryDelayMinutes(1), 15); assert.equal(E.retryDelayMinutes(2), 60); assert.equal(E.retryDelayMinutes(3), 360); assert.equal(E.retryDelayMinutes(9), 360); assert.equal(E.retryDelayMinutes(0), 15);
});

test("the defaults agree with email_cfg() and with the settings schema", () => {
  const d = S.defaults("centre").email;
  assert.equal(d.mode, E.DEFAULTS.mode); assert.equal(d.receipts, false); assert.equal(d.late_fee_notice, false);
  assert.deepEqual(d.reminders, E.DEFAULTS.reminders); assert.equal(d.daily_cap, E.DEFAULTS.daily_cap); assert.equal(d.per_hour, E.DEFAULTS.per_hour);
  assert.equal(d.mode, "off", "default = manual sharing as today");
  for (const [k, re] of [["mode", /'mode',\s+coalesce\(s#>>'\{email,mode\}', 'off'\)/], ["daily_cap", /coalesce\(\(s#>>'\{email,daily_cap\}'\)::int, 200\)/], ["per_hour", /coalesce\(\(s#>>'\{email,per_hour\}'\)::int, 60\)/],
    ["first", /first_after_days\}'\)::int, 3\)/], ["repeat", /repeat_days\}'\)::int, 7\)/], ["max", /max_count\}'\)::int, 3\)/]]) assert.match(SQL, re, k);
});

test("masking an address: first letters only, same vectors as the database test", () => {
  assert.equal(E.maskEmail("jane.tan@gmail.com"), "j***@g***.com");
  assert.equal(E.maskEmail("A@mail.example.test"), "A***@m***.test");
  assert.equal(E.maskEmail("  padded@x.org "), "p***@x***.org");
  assert.equal(E.maskEmail("bad"), "***"); assert.equal(E.maskEmail(null), "***"); assert.equal(E.maskEmail(""), "***");
  assert.ok(!/jane|tan|gmail/.test(E.maskEmail("jane.tan@gmail.com")));
});

test("valid addresses: same vectors as email_valid()", () => {
  for (const ok of ["a.b@example.test", "x@y.co"]) assert.equal(E.validEmail(ok), true, ok);
  for (const bad of ["x@y", "x y@z.com", "a@b@c.com", "", null, "a@b.c", "a".repeat(250) + "@b.com", "a@b.com,c@d.com", "<a@b.com>"]) assert.equal(E.validEmail(bad), false, String(bad));
});

test("every kind has a default message with a subject, a body, the centre's name and the footer", () => {
  for (const k of E.KINDS) {
    const m = E.compose(item({ kind: k, vars: Object.assign(item().vars, { paid_on: "2026-12-01" }) }), ORIGIN);
    assert.ok(m.subject.length > 3 && !/\{|undefined|null/.test(m.subject), k + " subject: " + m.subject);
    assert.ok(m.text.includes("Alpha Tuition") && m.text.includes("INV-12") && !/\{[a-z_]+\}|undefined|null/.test(m.text), k + " text");
    assert.ok(m.text.includes("no unsubscribe link") && m.text.includes("office@alpha.example.test") && m.text.includes("Sent through TutorDeck"), k + " footer says who to contact");
    assert.ok(/^<!doctype html>/.test(m.html) && m.html.includes("Alpha Tuition"), k + " html");
    assert.equal(m.template, k);
    assert.ok(!/<script|javascript:/i.test(m.html));
  }
});

test("the invoice email: amount owed, due date, a secure link on OUR address, nothing else", () => {
  const m = E.compose(item(), ORIGIN);
  assert.equal(m.subject, "Invoice INV-12 from Alpha Tuition");
  assert.match(m.text, /Hi Mrs Tan,/); assert.match(m.text, /S\$1,234\.56/); assert.match(m.text, /due on 7 Dec 2026/);
  assert.match(m.text, /https:\/\/www\.tutordeck\.com\.sg\/pay\?t=11111111-2222-3333-4444-555555555555/);
  assert.match(m.html, /<a href="https:\/\/www\.tutordeck\.com\.sg\/pay\?t=11111111-2222-3333-4444-555555555555"/);
  assert.ok(!/student|lesson|phone/i.test(m.text.split("--")[0]), "no student or lesson detail");
});

test("a receipt shows the payment, not the invoice balance, and has no link", () => {
  const m = E.compose(item({ kind: "receipt", vars: { number: "INV-12, INV-13", amount_cents: 5000, paid_on: "2026-12-01" } }), ORIGIN);
  assert.match(m.text, /payment of S\$50\.00 on 1 Dec 2026 \(invoice INV-12, INV-13\)/);
  assert.ok(!/pay\?t=/.test(m.text));
});

test("a reminder and a late-fee notice carry the link and the days overdue is available to the centre's wording", () => {
  const r = E.compose(item({ kind: "reminder", vars: Object.assign(item().vars, { days_overdue: 10 }) }), ORIGIN);
  assert.match(r.subject, /^Reminder: invoice INV-12/); assert.match(r.text, /pay\?t=/);
  const c = E.compose(item({ kind: "reminder", templates: { body: "{days_overdue} days late: {number}" }, vars: Object.assign(item().vars, { days_overdue: 10 }) }), ORIGIN);
  assert.match(c.text, /^10 days late: INV-12/);
  const l = E.compose(item({ kind: "late_fee", vars: Object.assign(item().vars, { amount_cents: 1000 }) }), ORIGIN);
  assert.match(l.subject, /^Late fee INV-12/); assert.match(l.text, /late fee of S\$10\.00/);
});

test("the centre's own wording replaces ours, field by field; blank falls back; marked as custom", () => {
  const a = E.compose(item({ templates: { subject: "Fees for {name}", body: "Dear {name}\n\nPlease pay {amount} by {due_date}.\n{link}" } }), ORIGIN);
  assert.equal(a.subject, "Fees for Mrs Tan"); assert.match(a.text, /^Dear Mrs Tan\n\nPlease pay S\$1,234\.56 by 7 Dec 2026\.\nhttps:/); assert.equal(a.template, "invoice:custom"); assert.equal(a.custom, true);
  const b = E.compose(item({ templates: { subject: "", body: "Only the body {number}" } }), ORIGIN);
  assert.equal(b.subject, "Invoice INV-12 from Alpha Tuition"); assert.match(b.text, /^Only the body INV-12/); assert.equal(b.template, "invoice:custom");
  const c = E.compose(item({ templates: { subject: "  ", body: "" } }), ORIGIN);
  assert.equal(c.template, "invoice"); assert.equal(c.custom, false);
  const d = E.compose(item({ templates: { body: "Hi {name} {unknown} {link}" } }), "");
  assert.match(d.text, /^Hi Mrs Tan\n\n--/, "an unknown field and a missing link become empty text, never 'undefined'");
});

test("nothing a parent, a centre or a family name contains can inject HTML or headers", () => {
  const evil = item({ name: "<img src=x onerror=alert(1)>", centre: 'A "B" <b>Tuition</b>', templates: { subject: "Hi\r\nBcc: x@y.com {name}", body: "<script>alert(1)</script> {name} {centre}" },
    vars: { number: "<b>1</b>", amount_cents: 100, due_date: "2026-12-07", token: 'a"><script>' } });
  const m = E.compose(evil, ORIGIN);
  assert.ok(!/[\r\n]/.test(m.subject), "no line break in the subject");
  assert.ok(!/<script|<img|<b>/.test(m.html), "no markup survives into the HTML");
  assert.match(m.html, /&lt;script&gt;/);
  assert.ok(!/href="[^"]*"><script/.test(m.html));
});

test("amounts and dates", () => {
  assert.equal(E.money(0), "S$0.00"); assert.equal(E.money(5), "S$0.05"); assert.equal(E.money(100), "S$1.00"); assert.equal(E.money(123456789), "S$1,234,567.89"); assert.equal(E.money(-250), "-S$2.50");
  assert.equal(E.dateText("2026-02-01"), "1 Feb 2026"); assert.equal(E.dateText("2028-02-29"), "29 Feb 2028"); assert.equal(E.dateText(""), ""); assert.equal(E.dateText(null), "");
  assert.equal(E.addDays("2026-12-30", 3), "2027-01-02"); assert.equal(E.addDays("2028-02-28", 1), "2028-02-29"); assert.equal(E.addDays("2026-03-01", -1), "2026-02-28");
});

test("template checks: every rule of the database validator", () => {
  assert.deepEqual(E.checkTemplates(null), []); assert.deepEqual(E.checkTemplates({}), []);
  assert.deepEqual(E.checkTemplates({ invoice: { subject: "", body: "" } }), []);
  assert.deepEqual(E.checkTemplates({ invoice: { body: "Hi {name}, {link} {contact} {paid_on} {days_overdue}" } }), []);
  assert.match(E.checkTemplates({ invoice: { body: "Hi {nam}" } })[0], /can only use/);
  assert.match(E.checkTemplates({ invoice: { body: "Hi {name" } })[0], /can only use/);
  assert.match(E.checkTemplates({ reminder: { subject: "{{name}}" } })[0], /can only use/);
  assert.match(E.checkTemplates({ late_fee: { subject: "x".repeat(121) } })[0], /too long/);
  assert.deepEqual(E.checkTemplates({ late_fee: { subject: "x".repeat(120) } }), []);
  assert.match(E.checkTemplates({ receipt: { body: "x".repeat(1001) } })[0], /too long/);
  assert.deepEqual(E.checkTemplates({ receipt: { body: "x".repeat(1000) } }), []);
  assert.match(E.checkTemplates({ invoice: { body: 5 } })[0], /must be text/);
  assert.match(E.checkTemplates([])[0], /malformed/);
});

test("Brevo's answer: what is sent, retried, refused or marks an address bad", () => {
  assert.deepEqual(E.classifyBrevo(201, { messageId: "<x>" }), { outcome: "sent", detail: null });
  assert.equal(E.classifyBrevo(200).outcome, "sent");
  assert.deepEqual(E.classifyBrevo(400, { code: "invalid_parameter", message: "email is not valid in to" }), { outcome: "invalid", detail: "invalid_recipient" });
  assert.deepEqual(E.classifyBrevo(400, { message: "templateId missing" }), { outcome: "failed", detail: "http_400" });
  assert.equal(E.classifyBrevo(401).fatal, true); assert.equal(E.classifyBrevo(403).outcome, "failed");
  assert.deepEqual(E.classifyBrevo(429), { outcome: "retry", detail: "http_429", delayMinutes: 720 });
  assert.equal(E.classifyBrevo(402).delayMinutes, 720);
  assert.deepEqual(E.classifyBrevo(500), { outcome: "retry", detail: "http_500" });
  assert.deepEqual(E.classifyBrevo(503), { outcome: "retry", detail: "http_503" });
  assert.deepEqual(E.classifyBrevo(0), { outcome: "retry", detail: "network" });
  assert.equal(E.classifyBrevo(404).outcome, "failed");
});

test("the reminder schedule in words and dates", () => {
  const rem = { enabled: true, first_after_days: 3, repeat_days: 7, max_count: 3 };
  assert.deepEqual(E.reminderDates("2026-12-15", rem), ["2026-12-18", "2026-12-25", "2027-01-01"]);
  assert.deepEqual(E.reminderDates("2026-12-15", { enabled: true, first_after_days: 1, repeat_days: 0, max_count: 5 }), ["2026-12-16"], "repeat 0 = one reminder only");
  assert.deepEqual(E.reminderDates("2026-12-15", { enabled: true, first_after_days: 90, repeat_days: 90, max_count: 1 }), ["2027-03-15"]);
  assert.equal(E.reminderLine(rem), "First reminder 3 days after the due date, then every 7 days, 3 reminders at most.");
  assert.equal(E.reminderLine({ enabled: true, first_after_days: 1, repeat_days: 0, max_count: 3 }), "First reminder 1 day after the due date, once only.");
  assert.equal(E.reminderLine({ enabled: true, first_after_days: 2, repeat_days: 1, max_count: 1 }), "First reminder 2 days after the due date, once only.");
  assert.equal(E.reminderLine({ enabled: false }), "Reminders are off.");
});

test("the queue line: 'N queued, sends over M days'", () => {
  const st = { mode: "staff_send", queued: 450, sends_over_days: 3, daily_cap: 200, sent_today: 0, sending: 0 };
  assert.equal(E.queueLine(st), "450 queued · sends over 3 days (200 a day) · 0 sent today");
  assert.equal(E.queueLine(Object.assign({}, st, { queued: 12, sends_over_days: 1, sent_today: 5, sending: 2 })), "12 queued · all go today (200 a day) · 2 sending now · 5 sent today");
  assert.equal(E.queueLine(Object.assign({}, st, { queued: 0, sends_over_days: 0, sent_today: 7 })), "Nothing is waiting to be sent · 7 sent today");
  assert.equal(E.queueLine({ mode: "off" }), "Email is switched off.");
  assert.equal(E.queueLine(null), "");
});

test("reasons and labels are plain words; unknown codes are still readable", () => {
  for (const c of ["no_email", "bad_address", "no_contact", "paid", "void", "email_off", "preview", "stuck", "already_sent", "too_soon", "daily_limit", "http_429", "gave_up"]) assert.ok(E.reasonText(c).length > 4, c);
  assert.equal(E.reasonText("something_new"), "something new"); assert.equal(E.reasonText(null), "");
  assert.equal(E.kindText("reminder", 2), "Reminder 2"); assert.equal(E.kindText("late_fee"), "Late-fee notice");
});

test("the platform room is what is left of Brevo's day", () => {
  assert.equal(E.PLATFORM_DAILY_CAP, 250); assert.equal(E.platformRoom(0), 250); assert.equal(E.platformRoom(249), 1); assert.equal(E.platformRoom(250), 0); assert.equal(E.platformRoom(400), 0); assert.equal(E.platformRoom(10, 20), 10); assert.equal(E.platformRoom(null), 250);
});
