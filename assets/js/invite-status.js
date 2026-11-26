// What the people list says about a person who has been invited but has not signed in yet, and whether "Resend invite" is available.
// Pure logic, no DOM: used by assets/js/org.js and unit-tested in tests/invite-status.test.js.
// Facts come from the member row (created_at = when they were invited) and org_invite_mail_status() (last_sent_at = when the last
// email went out, can_resend_at = last email + 10 minutes, sent_24h = emails in the last 24 hours). The link in an email works for 24 hours.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.InviteStatus = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  var DAY = 24 * 3600e3, LINK_MS = DAY, MAX_PER_DAY = 5;
  function ms(x) { var t = x ? new Date(x).getTime() : NaN; return isNaN(t) ? null : t; }
  function agoText(t, now) {
    var d = Math.floor((now - t) / DAY);
    if (d <= 0) return "today";
    if (d === 1) return "yesterday";
    return d + " days ago";
  }
  // member: { created_at }   mail: { last_sent_at, can_resend_at, sent_24h } or null (status unknown / no email yet)
  function describe(member, mail, now) {
    now = now == null ? Date.now() : now;
    var made = ms(member && member.created_at), sent = ms(mail && mail.last_sent_at), can = ms(mail && mail.can_resend_at);
    var n24 = (mail && +mail.sent_24h) || 0;
    var o = { invited: made == null ? "Invited" : "Invited " + agoText(made, now), neverSent: sent == null, expired: false, emailed: null,
              waitMinutes: 0, dailyLimit: n24 >= MAX_PER_DAY, buttonLabel: "Resend invite" };
    if (sent != null) { o.expired = now - sent > LINK_MS; o.emailed = "Emailed " + agoText(sent, now); }
    else o.buttonLabel = "Send invite email";
    if (can != null && can > now) o.waitMinutes = Math.max(1, Math.ceil((can - now) / 60000));
    o.canPress = o.waitMinutes === 0 && !o.dailyLimit;
    o.hint = o.neverSent ? "No email sent yet" : o.expired ? "Link expired, send a new one" : o.emailed;
    return o;
  }
  return { LINK_MS: LINK_MS, MAX_PER_DAY: MAX_PER_DAY, describe: describe };
});
