// Google Calendar sync — the reconcile logic, shared by the browser (calendar.js) and the server
// (api/gcal.js "sync"), so both build exactly the same events and never fight over them.
// No DOM, no Supabase client, no Google library: the caller passes small adapter functions.
//
//   TDGcalCore.syncAll(ctx) → { created, updated, deleted, skipped, unknown, fail, months, secs, text }
//   ctx = {
//     owner:     this tutor's TutorDeck user id (stamped on every event as tlOwner)
//     cal:       Google calendar id ("primary" or an id)
//     today:     "YYYY-MM-DD" in Singapore time
//     names:     { student_id: name },  locs: { student_id: location }
//     google:    async (method, path, body) → JSON | null; throws err.code=401 when the Google pass expired
//     lessons:   async (firstISO, lastISO) → this tutor's lessons in that date range (all statuses)
//     ownLessonIds: async ([ids]) → the subset that are this tutor's lessons
//     lastLessonDate: async (fromISO) → latest lesson_date on/after fromISO, or null
//     progress:  optional (label) → void, called as each month starts
//   }
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.TDGcalCore = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  var GTZ = "Asia/Singapore";
  var MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  function pad(n) { return (n < 10 ? "0" : "") + n; }
  function hhmm(t) { return t ? String(t).slice(0, 5) : ""; }

  function gEvent(l, ctx) {
    var sym = (l.postponed ? "↻" : "") + (l.one_off ? "✦" : "");     // ↻ postponed, ✦ one-off — same keys as the app
    var summary = (sym ? sym + " " : "") + [ctx.names[l.student_id] || "Lesson", l.subject].filter(Boolean).join(" · ");
    var d = []; if (l.level) d.push("Level: " + l.level); if (l.amount != null) d.push("Amount: S$" + l.amount);
    d.push(l.status === "scheduled" ? "Scheduled" : (l.paid ? "Paid" : (Number(l.amount) > 0 ? "Unpaid" : "No charge")));
    if (l.postponed) d.push("Postponed (↻)"); if (l.one_off) d.push("One-off (✦)");
    var e = { summary: summary, description: d.join("\n"),
      start: { dateTime: l.lesson_date + "T" + hhmm(l.start_time) + ":00", timeZone: GTZ },
      end: { dateTime: l.lesson_date + "T" + hhmm(l.end_time) + ":00", timeZone: GTZ },
      reminders: { useDefault: false },                                // no notification spam on re-create
      extendedProperties: { private: { tlengSync: "1", tlLessonId: String(l.id), tlOwner: String(ctx.owner) } } };
    var loc = ctx.locs[l.student_id]; if (loc) e.location = loc;
    return e;
  }
  // Comparable fingerprint of the fields we sync — used to detect drift (incl. Google-side edits).
  function gFP(x) {
    return [x.summary || "", ((x.start && x.start.dateTime) || "").slice(0, 19),
      ((x.end && x.end.dateTime) || "").slice(0, 19), x.location || "", x.description || ""].join("|");
  }
  // Month y/m (m 0-based) as lesson-date bounds and RFC3339 Singapore times.
  function monthWindow(y, m) {
    var lastDay = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
    var ny = m === 11 ? y + 1 : y, nm = m === 11 ? 0 : m + 1;
    return { firstISO: y + "-" + pad(m + 1) + "-01", lastISO: y + "-" + pad(m + 1) + "-" + pad(lastDay),
      tmin: y + "-" + pad(m + 1) + "-01T00:00:00+08:00", tmax: ny + "-" + pad(nm + 1) + "-01T00:00:00+08:00", label: MON[m] + " " + y };
  }
  function ownerOf(ev) { try { return ev.extendedProperties.private.tlOwner || ""; } catch (e) { return ""; } }
  function lessonOf(ev) { try { return ev.extendedProperties.private.tlLessonId || ""; } catch (e) { return ""; } }
  var UUID = /^[0-9a-f-]{36}$/i;

  // All app-created events on a calendar (optionally within a time window), following pages.
  async function listAppEvents(ctx, tmin, tmax) {
    var out = [], page = null;
    do {
      var q = "/calendars/" + encodeURIComponent(ctx.cal) + "/events?privateExtendedProperty=" + encodeURIComponent("tlengSync=1") + "&maxResults=250&singleEvents=true";
      if (tmin) q += "&timeMin=" + encodeURIComponent(tmin);
      if (tmax) q += "&timeMax=" + encodeURIComponent(tmax);
      if (page) q += "&pageToken=" + encodeURIComponent(page);
      var d = await ctx.google("GET", q);
      ((d && d.items) || []).forEach(function (e) { if (e.id) out.push(e); });
      page = d && d.nextPageToken;
    } while (page);
    return out;
  }
  // Run jobs a few at a time (Google is happy with this, and it's several times faster than one by one).
  async function pool(jobs, n) {
    var i = 0, first401 = null;
    async function worker() {
      while (i < jobs.length && !first401) {
        var j = jobs[i++];
        try { await j(); } catch (e) { if (e && e.code === 401) first401 = e; }
      }
    }
    var ws = []; for (var k = 0; k < Math.min(n, jobs.length); k++) ws.push(worker());
    await Promise.all(ws);
    if (first401) throw first401;
  }

  // Reconcile ONE month on the target calendar against the ledger (app is source of truth):
  // create missing lessons, update any that drifted (incl. Google-side edits), delete orphans.
  //
  // Ownership rules (several tutors can sync into one shared Google calendar):
  //  • tagged with this tutor's id (tlOwner)  → ours: kept, updated or removed as the ledger says.
  //  • tagged with ANOTHER tutor's id         → never touched.
  //  • untagged "legacy" event (made before tlOwner existed) → ours ONLY if its tlLessonId is one of
  //    this tutor's lessons. Then it's adopted (re-stamped with tlOwner) if the lesson is live in this
  //    month, removed if the lesson is cancelled or now sits in another month. Legacy events whose
  //    lesson no longer exists can't be proven ours, so they're left alone and counted in `unknown`.
  async function syncMonth(ctx, y, m) {
    var w = monthWindow(y, m), calP = "/calendars/" + encodeURIComponent(ctx.cal) + "/events", owner = String(ctx.owner);
    if (ctx.progress) ctx.progress(w.label);
    var events = await listAppEvents(ctx, w.tmin, w.tmax);
    var mine = events.filter(function (ev) { return ownerOf(ev) === owner; });
    var legacy = events.filter(function (ev) { return !ownerOf(ev) && lessonOf(ev); });
    var all = await ctx.lessons(w.firstISO, w.lastISO);
    if (!all) return { created: 0, updated: 0, deleted: 0, skipped: 0, unknown: 0, fail: 1 };
    var ownIds = {};
    all.forEach(function (l) { ownIds[String(l.id)] = 1; });
    var ask = [];
    legacy.forEach(function (ev) { var lid = lessonOf(ev); if (!ownIds[lid] && UUID.test(lid) && ask.indexOf(lid) < 0) ask.push(lid); });
    for (var a = 0; a < ask.length; a += 100) {
      var got = await ctx.ownLessonIds(ask.slice(a, a + 100));
      if (!got) return { created: 0, updated: 0, deleted: 0, skipped: 0, unknown: 0, fail: 1 };
      got.forEach(function (id) { ownIds[String(id)] = 1; });
    }
    var rows = all.filter(function (l) { return l.status !== "cancelled"; });   // what should be on the calendar
    var byLesson = {}, toDel = [], unknown = 0;
    mine.forEach(function (ev) { var lid = lessonOf(ev); if (lid && !byLesson[lid]) byLesson[lid] = ev; else toDel.push(ev); });
    legacy.forEach(function (ev) {
      var lid = lessonOf(ev);
      if (!ownIds[lid]) { unknown++; return; }
      if (!byLesson[lid]) byLesson[lid] = Object.assign({ _legacy: true }, ev); else toDel.push(ev);
    });
    var r = { created: 0, updated: 0, deleted: 0, skipped: 0, unknown: unknown, fail: 0 }, keep = {}, jobs = [];
    rows.forEach(function (l) {
      var want = gEvent(l, ctx), ev = byLesson[String(l.id)]; keep[String(l.id)] = 1;
      if (!ev) jobs.push(function () { return ctx.google("POST", calP, want).then(function () { r.created++; }, function (e) { if (e && e.code === 401) throw e; r.fail++; }); });
      else if (ev._legacy || gFP(ev) !== gFP(want))
        jobs.push(function () { return ctx.google("PUT", calP + "/" + encodeURIComponent(ev.id), want).then(function () { r.updated++; }, function (e) { if (e && e.code === 401) throw e; r.fail++; }); });
      else r.skipped++;
    });
    Object.keys(byLesson).forEach(function (lid) { if (!keep[lid]) toDel.push(byLesson[lid]); });
    toDel.forEach(function (ev) {
      jobs.push(function () { return ctx.google("DELETE", calP + "/" + encodeURIComponent(ev.id)).then(function () { r.deleted++; }, function (e) { if (e && e.code === 401) throw e; r.fail++; }); });
    });
    await pool(jobs, 4);
    return r;
  }

  // Sync from the 1st of LAST month through the last month that has a lesson (capped +6 months) — so
  // last week's cancellations are caught even across a month boundary, and lessons logged for future
  // months go too. Older months are left untouched.
  async function syncAll(ctx) {
    var t0 = Date.now(), ty = +ctx.today.slice(0, 4), tm = +ctx.today.slice(5, 7) - 1;
    var fy = tm === 0 ? ty - 1 : ty, fm = tm === 0 ? 11 : tm - 1;
    var fromISO = fy + "-" + pad(fm + 1) + "-01";
    var lastISO = (await ctx.lastLessonDate(fromISO)) || fromISO;
    var ly = +lastISO.slice(0, 4), lm = +lastISO.slice(5, 7) - 1;
    var cap = ty * 12 + tm + 6; if (ly * 12 + lm > cap) { ly = Math.floor(cap / 12); lm = cap % 12; }
    var tot = { created: 0, updated: 0, deleted: 0, skipped: 0, unknown: 0, fail: 0, months: 0 };
    for (var k = fy * 12 + fm; k <= ly * 12 + lm; k++) {
      var r = await syncMonth(ctx, Math.floor(k / 12), k % 12);
      ["created", "updated", "deleted", "skipped", "unknown", "fail"].forEach(function (f) { tot[f] += r[f] || 0; });
      tot.months++;
    }
    tot.secs = Math.max(1, Math.round((Date.now() - t0) / 1000));
    tot.text = summary(tot);
    return tot;
  }
  function summary(t) {
    var total = t.created + t.updated + t.skipped, parts = [];
    if (t.created) parts.push(t.created + " added"); if (t.updated) parts.push(t.updated + " updated");
    if (!parts.length && !t.deleted) parts.push("already up to date");
    if (t.deleted) parts.push(t.deleted + " removed");                 // cancelled / deleted lessons taken off Google
    if (t.fail) parts.push(t.fail + " failed");
    return "Synced ✓ " + total + " lesson" + (total === 1 ? "" : "s") + " in " + t.secs + "s · " + parts.join(" · ");
  }
  // Today's date in Singapore, whatever clock the caller runs on (the server runs on UTC).
  function sgToday(now) {
    var d = new Date((now || Date.now()) + 8 * 3600e3);
    return d.getUTCFullYear() + "-" + pad(d.getUTCMonth() + 1) + "-" + pad(d.getUTCDate());
  }
  return { gEvent: gEvent, gFP: gFP, monthWindow: monthWindow, listAppEvents: listAppEvents, syncMonth: syncMonth,
    syncAll: syncAll, summary: summary, sgToday: sgToday, ownerOf: ownerOf, lessonOf: lessonOf };
});
