// Emails to families — the pure part (T7.3). Used by the server (api/email-send.js, api/email-cron.js) to WRITE each message and by the Money > Email screen
// (assets/js/centre-email.js) to word what the database says. No network, no secrets, no DOM: tests/invoice-email-core.test.js covers every function.
// The rules themselves (who gets what, the caps, retries, bounces) live in db/migration_invoice_email.sql; this file must agree with it
// (the placeholder list, the masking, the retry delays, the defaults: the tests compare them with the SQL file).
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.InvoiceEmailCore = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  var KINDS = ["invoice", "receipt", "reminder", "late_fee"];
  var MODES = ["off", "staff_send", "auto_on_issue"];
  // the only {fields} a centre may use in its own wording (same list as org_validate_settings())
  var FIELDS = ["name", "centre", "number", "amount", "due_date", "link", "contact", "paid_on", "days_overdue"];
  var FIELD_HELP = {
    name: "the parent’s name", centre: "your centre’s name", number: "the invoice number", amount: "the amount (still owed, or paid for a receipt)",
    due_date: "the due date", link: "the secure invoice link", contact: "your reply-to email", paid_on: "the day a payment was received", days_overdue: "days past the due date"
  };
  var LIMITS = { subject: 120, body: 1000 };
  var DEFAULTS = { mode: "off", receipts: false, late_fee_notice: false,
    reminders: { enabled: false, first_after_days: 3, repeat_days: 7, max_count: 3 }, daily_cap: 200, per_hour: 60, templates: {} };
  var RETRY_MINUTES = [15, 60, 360];            // after attempt 1, 2, 3 (attempt 3 is the last: a third failure is final)
  var MAX_ATTEMPTS = 3;
  var PLATFORM_DAILY_CAP = 250;                 // Brevo's free plan is 300 a day for everything TutorDeck sends; keep headroom for sign-up and invite emails
  var SENDER_PRODUCT = "TutorDeck";

  // The wording we use until a centre writes its own. Plain text, one blank line between paragraphs.
  var TEMPLATES = {
    invoice: { subject: "Invoice {number} from {centre}",
      body: "Hi {name},\n\nHere is invoice {number} from {centre} for {amount}, due on {due_date}.\n\nYou can see it and pay by PayNow here:\n{link}\n\nThank you!\n{centre}" },
    receipt: { subject: "Payment received: thank you from {centre}",
      body: "Hi {name},\n\nThank you. {centre} received your payment of {amount} on {paid_on} (invoice {number}).\n\nThank you!\n{centre}" },
    reminder: { subject: "Reminder: invoice {number} from {centre}",
      body: "Hi {name},\n\nA friendly reminder that invoice {number} from {centre} for {amount} was due on {due_date}.\n\nYou can see it and pay by PayNow here:\n{link}\n\nIf you have already paid, thank you, and please ignore this email.\n{centre}" },
    late_fee: { subject: "Late fee {number} from {centre}",
      body: "Hi {name},\n\nA late fee of {amount} has been added because an invoice was paid late. It is invoice {number}, due on {due_date}.\n\nYou can see it here:\n{link}\n\n{centre}" }
  };

  // ------------------------------------------------------------------ small helpers
  function validEmail(e) { e = String(e == null ? "" : e); return e.length <= 254 && /^[^@\s<>,;]+@[^@\s<>,;]+\.[^@\s<>,;]{2,}$/.test(e); }
  // "jane.tan@gmail.com" → "j***@g***.com" (the only form of an address that is ever kept). Same as email_mask() in the database.
  function maskEmail(e) {
    e = String(e == null ? "" : e).trim();
    if (!validEmail(e)) return "***";
    var at = e.indexOf("@"), local = e.slice(0, at), dom = e.slice(at + 1), tld = dom.replace(/^.*\./, "");
    return local.charAt(0) + "***@" + dom.charAt(0) + "***." + tld;
  }
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }
  function money(c) {
    c = Math.round(Number(c) || 0);
    var neg = c < 0, a = Math.abs(c), d = Math.floor(a / 100), cents = a % 100;
    return (neg ? "-" : "") + "S$" + String(d).replace(/\B(?=(\d{3})+(?!\d))/g, ",") + "." + (cents < 10 ? "0" : "") + cents;
  }
  var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  function dateText(iso) {
    var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || ""));
    return m ? (+m[3]) + " " + MONTHS[+m[2] - 1] + " " + m[1] : "";
  }
  function addDays(iso, n) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(iso || "")); if (!m) return "";
    var d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3] + n));
    return d.getUTCFullYear() + "-" + ("0" + (d.getUTCMonth() + 1)).slice(-2) + "-" + ("0" + d.getUTCDate()).slice(-2);
  }

  // ------------------------------------------------------------------ the centre's own wording
  // Problems with a template set (same rules as org_validate_settings()). templates = { invoice: { subject, body }, ... }
  function checkTemplates(templates) {
    var e = [];
    if (templates == null) return e;
    if (typeof templates !== "object" || Array.isArray(templates)) return ["Email wording is malformed."];
    KINDS.forEach(function (k) {
      var t = templates[k]; if (t == null) return;
      ["subject", "body"].forEach(function (part) {
        var v = t[part]; if (v == null) return;
        if (typeof v !== "string") { e.push("Email wording must be text."); return; }
        if (v.length > LIMITS[part]) e.push("The " + k.replace("_", "-") + " email " + part + " is too long (" + LIMITS[part] + " characters at most).");
        var left = v.replace(new RegExp("\\{(" + FIELDS.join("|") + ")\\}", "g"), "");
        if (/[{}]/.test(left)) e.push("The " + k.replace("_", "-") + " email " + part + " can only use " + FIELDS.map(function (f) { return "{" + f + "}"; }).join(" ") + ".");
      });
    });
    return e;
  }
  // Fill in {fields}. Unknown or missing fields become empty text (never "undefined"); no HTML is ever interpreted.
  function fill(text, fields) {
    return String(text == null ? "" : text).replace(/\{([a-z_]+)\}/g, function (m, k) { return FIELDS.indexOf(k) > -1 && fields[k] != null ? String(fields[k]) : ""; });
  }
  function oneLine(s) { return String(s).replace(/[\r\n\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim(); }

  // What goes into the {fields} for one claimed message (see email_claim() in the migration for the item's shape)
  function fieldsFor(item, origin) {
    var v = item.vars || {}, base = String(origin || "").replace(/\/+$/, "");
    return {
      name: oneLine(item.name || "there"), centre: oneLine(item.centre || "your centre"), number: oneLine(v.number || ""),
      amount: money(v.amount_cents), due_date: dateText(v.due_date), paid_on: dateText(v.paid_on), contact: oneLine(item.reply_to || ""),
      days_overdue: v.days_overdue != null ? String(v.days_overdue) : "",
      link: v.token && base ? base + "/pay?t=" + encodeURIComponent(v.token) : ""
    };
  }
  // The message: subject, plain text and HTML. A blank custom subject or body falls back to our default (so a centre can change just one of them).
  function compose(item, origin) {
    var kind = KINDS.indexOf(item.kind) > -1 ? item.kind : "invoice", cust = (item.templates && typeof item.templates === "object") ? item.templates : {};
    var cs = typeof cust.subject === "string" && cust.subject.trim() ? cust.subject : null, cb = typeof cust.body === "string" && cust.body.trim() ? cust.body : null;
    var f = fieldsFor(item, origin);
    var subject = oneLine(fill(cs || TEMPLATES[kind].subject, f)) || (f.centre + " — " + SENDER_PRODUCT);
    var body = fill(cb || TEMPLATES[kind].body, f).replace(/\r\n?/g, "\n").trim();
    var foot = "This is a message about your account with " + f.centre + ", so it has no unsubscribe link. To change who receives these emails, contact " + f.centre +
      (f.contact ? " (" + f.contact + ")" : "") + ". Sent through " + SENDER_PRODUCT + ".";
    var text = body + "\n\n--\n" + foot + "\n";
    var MARK = "\u0001LINK\u0001", withMark = fill(cb || TEMPLATES[kind].body, Object.assign({}, f, { link: f.link ? MARK : "" })).replace(/\r\n?/g, "\n").trim();
    var html = esc(withMark).split("\n\n").map(function (p) { return '<p style="margin:0 0 14px">' + p.replace(/\n/g, "<br>") + "</p>"; }).join("");
    if (f.link) html = html.split(esc(MARK)).join('<a href="' + esc(f.link) + '" style="color:#0F766E;font-weight:700">' + esc(f.link) + "</a>");
    var page = '<!doctype html><html><body style="margin:0;background:#FAF9F6;font-family:Manrope,Arial,Helvetica,sans-serif;color:#13233F">' +
      '<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:24px 12px">' +
      '<table role="presentation" width="540" cellpadding="0" cellspacing="0" style="max-width:540px;width:100%;background:#ffffff;border:1px solid #E8E5DE;border-radius:12px">' +
      '<tr><td style="padding:24px 26px 6px;font-size:18px;font-weight:800;color:#13233F">' + esc(f.centre) + "</td></tr>" +
      '<tr><td style="padding:10px 26px 4px;font-size:15px;line-height:1.55">' + html + "</td></tr>" +
      '<tr><td style="padding:14px 26px 24px;font-size:12px;line-height:1.5;color:#5B6678;border-top:1px solid #E8E5DE">' + esc(foot) + "</td></tr>" +
      "</table></td></tr></table></body></html>";
    return { kind: kind, subject: subject, text: text, html: page, custom: !!(cs || cb), template: kind + ((cs || cb) ? ":custom" : "") };
  }

  // ------------------------------------------------------------------ what Brevo's answer means (the server then tells the database)
  // → { outcome: sent | retry | failed | invalid, detail, delayMinutes? }.   200/201 sent; 400 about the recipient = invalid (marks the address bad);
  // 401/403 = our key or sender is wrong (failed, nothing to retry); 402/429 = Brevo's own limit (retry in 12 hours); 5xx and network errors retry.
  function classifyBrevo(status, body) {
    var s = Number(status) || 0, msg = body && (body.message || body.code) ? String(body.message || body.code) : "";
    if (s === 200 || s === 201 || s === 202) return { outcome: "sent", detail: null };
    if (s === 400) return /email|recipient|address|invalid.*to|to.*invalid/i.test(msg) ? { outcome: "invalid", detail: "invalid_recipient" } : { outcome: "failed", detail: "http_400" };
    if (s === 401 || s === 403) return { outcome: "failed", detail: "http_" + s, fatal: true };
    if (s === 402 || s === 429) return { outcome: "retry", detail: "http_" + s, delayMinutes: 720 };
    if (s >= 500 || s === 0) return { outcome: "retry", detail: s ? "http_" + s : "network" };
    return { outcome: "failed", detail: "http_" + s };
  }
  function retryDelayMinutes(attempt) { return RETRY_MINUTES[Math.min(Math.max(attempt, 1), RETRY_MINUTES.length) - 1]; }

  // ------------------------------------------------------------------ reminders and the queue, in words
  // The dates reminders would go for an invoice due on `dueISO` (what the reminder preview shows).
  function reminderDates(dueISO, rem) {
    var out = [], n = rem.repeat_days === 0 ? 1 : rem.max_count;
    for (var i = 0; i < n; i++) out.push(addDays(dueISO, rem.first_after_days + i * rem.repeat_days));
    return out;
  }
  function reminderLine(rem) {
    if (!rem || !rem.enabled) return "Reminders are off.";
    var s = "First reminder " + rem.first_after_days + (rem.first_after_days === 1 ? " day" : " days") + " after the due date";
    if (rem.repeat_days > 0 && rem.max_count > 1) s += ", then every " + rem.repeat_days + (rem.repeat_days === 1 ? " day" : " days") + ", " + rem.max_count + " reminders at most";
    else s += ", once only";
    return s + ".";
  }
  function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }
  // the confirmation under the "Email invoice" button (B8-FIX F3): shown the moment the email is in the queue
  function queuedText(n) { return "Queued for " + plural(n, "email", "emails") + ". It goes out within minutes, or tomorrow if today’s limit has been reached (see Money > Email)."; }
  // "12 queued · sends over 2 days (200 a day)"
  function queueLine(st) {
    if (!st) return "";
    if (st.mode === "off") return "Email is switched off.";
    var q = st.queued || 0, parts = [];
    if (q === 0) parts.push("Nothing is waiting to be sent");
    else parts.push(q + " queued · " + (st.sends_over_days <= 1 ? "all go today" : "sends over " + st.sends_over_days + " days") + " (" + st.daily_cap + " a day)");
    if (st.sending) parts.push(st.sending + " sending now");
    parts.push(st.sent_today + " sent today");
    return parts.join(" · ");
  }
  var REASONS = {
    no_email: "No valid email address for the billing contact", bad_address: "That email address bounced", no_contact: "No parent or guardian on file", no_recipient: "The contact was removed",
    paid: "Already paid", void: "Cancelled or fully credited", not_issued: "Not issued yet", not_billable: "Not an invoice that can be emailed", not_found: "Not found", no_household: "No family on this invoice",
    email_off: "Email was switched off", receipts_off: "Receipts were switched off", reminders_off: "Reminders were switched off", no_link: "The shareable link is switched off",
    reversed: "The payment was reversed", cancelled_by_staff: "Cancelled by staff", preview: "Test site: this address isn’t on the allow-list", stuck: "Sending didn’t finish",
    invalid_recipient: "Brevo says the address is invalid", already_sent: "Already queued or sent", too_soon: "Sent a moment ago", daily_limit: "Already sent three times today",
    http_400: "Brevo refused the message", http_401: "Brevo key problem", http_403: "Brevo sender problem", http_429: "Brevo daily limit", http_402: "Brevo account limit", http_500: "Brevo had a problem", http_503: "Brevo was busy", network: "Couldn’t reach Brevo", gave_up: "Gave up after three tries"
  };
  function reasonText(code) { return REASONS[code] || (code ? String(code).replace(/_/g, " ") : ""); }
  var KIND_TEXT = { invoice: "Invoice", receipt: "Receipt", reminder: "Reminder", late_fee: "Late-fee notice" };
  function kindText(k, n) { return (KIND_TEXT[k] || k) + (k === "reminder" && n ? " " + n : ""); }
  var STATUS_TEXT = { queued: "Queued", sending: "Sending", sent: "Sent", failed: "Failed", cancelled: "Cancelled", skipped: "Not sent" };
  var RESULT_TEXT = { sent: "Sent", retry: "Will retry", failed: "Failed", bounced: "Bounced", blocked_preview: "Test site", skipped: "Not sent", cancelled: "Cancelled" };
  // what a database error says, in plain words (the functions raise "NOT_ALLOWED: ...", "BAD_VALUE: ..." with the sentence after the colon)
  var CODED = /^(NOT_ALLOWED|BAD_VALUE|TOO_LONG): ([\s\S]*)$/;
  function isMissing(err) { var m = String((err && err.message) || err || ""); return /Could not find the function|PGRST202|42883|does not exist/i.test(m); }
  function errorText(err) {
    var m = String((err && err.message) || err || ""), c = CODED.exec(m);
    if (c) return c[2].charAt(0).toUpperCase() + c[2].slice(1) + (/[.!?]$/.test(c[2]) ? "" : ".");
    if (/NOT_FOUND/.test(m)) return "That isn’t available any more. Refresh the page and try again.";
    if (isMissing(err)) return "Family email isn’t switched on in this database yet (db/migration_invoice_email.sql).";
    if (/permission denied/i.test(m)) return "Your account isn’t allowed to do that at this centre.";
    return "Something went wrong. Refresh the page and try again; if it happens again, tell TutorDeck.";
  }
  // what the server's "send now" answer means, in words (counts only)
  function sentLine(r) {
    if (!r) return "";
    if (r.stopped === "off") return "Email is switched off.";
    var bits = [];
    if (r.sent) bits.push(plural(r.sent, "email", "emails") + " sent");
    if (r.retried) bits.push(r.retried + " will be tried again");
    if (r.invalid) bits.push(plural(r.invalid, "address", "addresses") + " not valid");
    if (r.failed) bits.push(r.failed + " failed");
    if (r.blocked) bits.push(r.blocked + " not sent (test site)");
    if (r.stopped === "platform_cap") bits.push("TutorDeck’s email limit for today is reached, so the rest waits for tomorrow");
    else if (/^brevo_/.test(r.stopped || "")) bits.push("the email service refused us; this is on TutorDeck’s side and the messages will be tried again");
    return bits.length ? bits.join(" · ") + "." : "Nothing was due to be sent right now.";
  }
  // how much room the whole platform has left today (Brevo's free plan)
  function platformRoom(sent24h, cap) { return Math.max((cap == null ? PLATFORM_DAILY_CAP : cap) - (Number(sent24h) || 0), 0); }

  return { KINDS: KINDS, MODES: MODES, FIELDS: FIELDS, FIELD_HELP: FIELD_HELP, LIMITS: LIMITS, DEFAULTS: DEFAULTS, TEMPLATES: TEMPLATES, RETRY_MINUTES: RETRY_MINUTES, MAX_ATTEMPTS: MAX_ATTEMPTS,
    PLATFORM_DAILY_CAP: PLATFORM_DAILY_CAP, validEmail: validEmail, maskEmail: maskEmail, money: money, dateText: dateText, addDays: addDays, checkTemplates: checkTemplates, fill: fill,
    fieldsFor: fieldsFor, compose: compose, classifyBrevo: classifyBrevo, retryDelayMinutes: retryDelayMinutes, reminderDates: reminderDates, reminderLine: reminderLine,
    queueLine: queueLine, reasonText: reasonText, kindText: kindText, STATUS_TEXT: STATUS_TEXT, RESULT_TEXT: RESULT_TEXT, platformRoom: platformRoom, esc: esc, plural: plural, errorText: errorText, isMissing: isMissing, sentLine: sentLine, queuedText: queuedText };
});
