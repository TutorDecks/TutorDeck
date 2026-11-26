// Unit tests for the centre Timetable page logic (T3 step 6). No DOM, no network.  node --test tests/centre-timetable-core.test.js
const test = require("node:test");
const assert = require("node:assert");
const TT = require("../assets/js/centre-timetable-core.js");

const ID = "11111111-1111-4111-8111-111111111111";
const row = (o) => Object.assign({ lesson_id: "l", lesson_date: "2026-11-23", start_time: "15:00:00", end_time: "16:30:00", minutes: 90, student_name: "Aiden", student_level: "P5",
  subject: "Math", tutor_id: "m1", tutor_name: "Tutor One", no_tutor: false, trial: false, attendance: null, state: "future", cancelled: false, postponed: false, holiday: null, online_link: null }, o);

test("a week is Monday to Sunday, a day is itself (same rule as Attendance)", () => {
  assert.deepStrictEqual(TT.range("week", "2026-11-26"), { from: "2026-11-23", to: "2026-11-29" });
  assert.deepStrictEqual(TT.range("day", "2026-11-26"), { from: "2026-11-26", to: "2026-11-26" });
  assert.deepStrictEqual(TT.range("anything", "2026-11-26"), { from: "2026-11-23", to: "2026-11-29" });
  assert.deepStrictEqual(TT.range("next14", "2026-11-26"), { from: "2026-11-26", to: "2026-12-09" });
  assert.strictEqual(TT.datesIn("2026-11-26", "2026-12-09").length, 14);
  assert.strictEqual(TT.shift("next14", "2026-11-26", 1), "2026-12-10");
  assert.strictEqual(TT.rangeLabel("next14", "2026-11-26", "2026-11-26"), "Thu 26 Nov – Wed 9 Dec");
  assert.strictEqual(TT.shift("week", "2026-11-26", 1), "2026-12-03");
  assert.strictEqual(TT.shift("day", "2026-11-26", -1), "2026-11-25");
  assert.strictEqual(TT.rangeLabel("week", "2026-11-26", "2026-11-26"), "23 Nov – 29 Nov");
  assert.deepStrictEqual(TT.datesIn("2026-11-23", "2026-11-29").length, 7);
});

test("holidays: which cover a day, and how the band reads", () => {
  const H = [{ name: "Deepavali", starts_on: "2026-11-08", ends_on: "2026-11-08", branch_id: null, branch_name: null },
             { name: "Renovation", starts_on: "2026-11-24", ends_on: "2026-11-25", branch_id: "b", branch_name: "Bishan" },
             { name: "Break", starts_on: "2026-11-20", ends_on: "2026-12-10", branch_id: null, branch_name: null }];
  assert.deepStrictEqual(TT.holidaysOn("2026-11-24", H).map((h) => h.name), ["Renovation", "Break"]);
  assert.deepStrictEqual(TT.holidaysOn("2026-11-26", H).map((h) => h.name), ["Break"]);
  assert.deepStrictEqual(TT.holidaysOn("2026-11-01", H), []);
  assert.strictEqual(TT.bandText(TT.holidaysOn("2026-11-24", H)), "Renovation (Bishan) · Break");
  assert.deepStrictEqual(TT.holidaysOn("2026-11-24", null), []);
});

test("days: a one-page week lists every day, empty ones too; a later page only the days it has", () => {
  const rows = [row({ lesson_id: "a", lesson_date: "2026-11-23" }), row({ lesson_id: "b", lesson_date: "2026-11-23" }), row({ lesson_id: "c", lesson_date: "2026-11-25" })];
  const H = [{ name: "Day off", starts_on: "2026-11-24", ends_on: "2026-11-24" }];
  const all = TT.days(rows, H, "2026-11-23", "2026-11-29", true);
  assert.strictEqual(all.length, 7);
  assert.deepStrictEqual(all.map((d) => d.rows.length), [2, 0, 1, 0, 0, 0, 0]);
  assert.deepStrictEqual(all[1].holidays.map((h) => h.name), ["Day off"], "a holiday with no lessons still has its day, with the band");
  const later = TT.days(rows, H, "2026-11-23", "2026-11-29", false);
  assert.deepStrictEqual(later.map((d) => d.date), ["2026-11-23", "2026-11-25"]);
  assert.deepStrictEqual(TT.days([], [], "2026-11-23", "2026-11-23", true).map((d) => d.rows.length), [0]);
});

test("chips: trial, cancelled, moved, attendance, holiday; upcoming lessons carry no attendance chip", () => {
  const t = (r) => TT.chips(row(r)).map((c) => c.text + ":" + c.tone);
  assert.deepStrictEqual(t({}), []);
  assert.deepStrictEqual(t({ state: "open" }), ["Not marked:warn"]);
  assert.deepStrictEqual(t({ state: "marked", attendance: "attended" }), ["Attended:ok"]);
  assert.deepStrictEqual(t({ state: "marked", attendance: "absent" }), ["Absent:muted"]);
  assert.deepStrictEqual(t({ trial: true, state: "open" }), ["Trial:trial", "Not marked:warn"]);
  assert.deepStrictEqual(t({ cancelled: true, state: "cancelled" }), ["Cancelled:muted"]);
  assert.deepStrictEqual(t({ cancelled: true, trial: true, state: "marked", attendance: "late_cancelled" }), ["Trial:trial", "Cancelled:muted"], "a cancelled lesson says Cancelled once, not also its mark");
  assert.deepStrictEqual(t({ postponed: true }), ["Moved:muted"]);
  assert.deepStrictEqual(t({ holiday: "Deepavali" }), ["Holiday:muted"]);
  assert.deepStrictEqual(t({ postponed: true, holiday: "X", state: "open" }), ["Moved:muted", "Not marked:warn", "Holiday:muted"]);
});

test("a lesson with no tutor is the amber warning; a cancelled one nobody teaches is not", () => {
  assert.deepStrictEqual(TT.tutorLine(row({ no_tutor: true, tutor_id: null, tutor_name: null })), { text: "No tutor yet", warn: true });
  assert.deepStrictEqual(TT.tutorLine(row({})), { text: "Tutor One", warn: false });
  assert.deepStrictEqual(TT.tutorLine(row({ tutor_name: "Former tutor" })), { text: "Former tutor", warn: false });
  assert.deepStrictEqual(TT.tutorLine(row({ no_tutor: false, cancelled: true, tutor_id: null, tutor_name: null })), { text: "No tutor", warn: false });
});

test("duration and the lesson facts (online link says Not set; nothing about money)", () => {
  assert.strictEqual(TT.durationLabel(45), "45 min");
  assert.strictEqual(TT.durationLabel(60), "1 h");
  assert.strictEqual(TT.durationLabel(90), "1 h 30 min");
  assert.strictEqual(TT.durationLabel(0), "");
  assert.strictEqual(TT.durationLabel(null), "");
  const f = TT.facts(row({ trial: true, holiday: "Deepavali" }));
  const get = (k) => (f.filter((x) => x[0] === k)[0] || [])[1];
  assert.strictEqual(get("Time"), "3:00 pm – 4:30 pm (1 h 30 min)");
  assert.strictEqual(get("Online link"), "Not set");
  assert.strictEqual(get("Tutor"), "Tutor One");
  assert.strictEqual(get("Status"), "Trial · Holiday");
  assert.strictEqual(get("Holiday"), "Deepavali");
  assert.strictEqual(TT.facts(row({ online_link: "https://meet.example/x" })).filter((x) => x[0] === "Online link")[0][1], "https://meet.example/x");
  assert.ok(!f.some((x) => /price|rate|fee|charge|amount|paid|S\$/i.test(x[0] + " " + x[1])), "no money anywhere in the sheet");
});

test("the filters become the database call, and an odd address is ignored, not an error", () => {
  const s = { view: "week", anchor: "2026-11-26", tutor: ID, branch: "", student: "", notutor: true, page: 2 };
  assert.deepStrictEqual(TT.args("c1", s), { p_org: "c1", p_from: "2026-11-23", p_to: "2026-11-29", p_tutor: ID, p_branch: null, p_student: null, p_page: 2, p_notutor: true, p_size: 50 });
  assert.strictEqual(TT.args("c1", { view: "day", anchor: "2026-11-26" }).p_from, "2026-11-26");
  assert.strictEqual(TT.args("c1", { view: "day", anchor: "2026-11-26" }).p_notutor, false);
  const q = (str) => new URLSearchParams(str);
  assert.deepStrictEqual(TT.fromQuery(q("id=c1")), { view: "week", anchor: null, tutor: "", branch: "", student: "", notutor: false, page: 1 });
  assert.deepStrictEqual(TT.fromQuery(q("view=day&date=2026-11-24&tutor=" + ID + "&f=notutor")), { view: "day", anchor: "2026-11-24", tutor: ID, branch: "", student: "", notutor: true, page: 1 });
  assert.strictEqual(TT.fromQuery(q("view=next14&f=notutor")).view, "next14");
  assert.strictEqual(TT.toQuery("c1", { view: "next14", anchor: null, tutor: "", branch: "", student: "", notutor: true }, "2026-11-26"), "id=c1&view=next14&f=notutor");
  const odd = TT.fromQuery(q("view=month&date=2026-13-45&tutor=not-a-uuid&student='%3Bdrop&branch=1&f=other"));
  assert.deepStrictEqual(odd, { view: "week", anchor: null, tutor: "", branch: "", student: "", notutor: false, page: 1 });
  // and back to an address
  assert.strictEqual(TT.toQuery("c1", { view: "week", anchor: null, tutor: "", branch: "", student: "", notutor: false }, "2026-11-26"), "id=c1");
  assert.strictEqual(TT.toQuery("c1", { view: "day", anchor: "2026-11-24", tutor: ID, branch: "", student: ID, notutor: true }, "2026-11-26"),
                     "id=c1&view=day&date=2026-11-24&tutor=" + ID + "&student=" + ID + "&f=notutor");
  assert.strictEqual(TT.toQuery("c1", { view: "week", anchor: "2026-11-26", tutor: "", branch: "", student: "", notutor: false }, "2026-11-26"), "id=c1", "today is not written into the address");
  assert.strictEqual(TT.anyFilter({ tutor: "", student: "", notutor: false, branch: ID }), false, "a branch only chooses holidays, it is not a lesson filter");
  assert.strictEqual(TT.anyFilter({ tutor: ID }), true);
});

test("student picker narrows by what is typed", () => {
  const L = [{ id: "1", name: "Aiden Tan" }, { id: "2", name: "Mei Ling Koh" }, { id: "3", name: "Daniel Ong" }];
  assert.strictEqual(TT.matchStudents(L, "").length, 3);
  assert.deepStrictEqual(TT.matchStudents(L, " ling ").map((x) => x.id), ["2"]);
  assert.deepStrictEqual(TT.matchStudents(L, "AN").map((x) => x.id), ["1", "3"]);
  assert.deepStrictEqual(TT.matchStudents(null, "x"), []);
});

test("paging and wording", () => {
  assert.strictEqual(TT.pageCount(0), 1);
  assert.strictEqual(TT.pageCount(101, 50), 3);
  assert.strictEqual(TT.pagerLabel(2, 50, 120), "51–100 of 120");
  assert.strictEqual(TT.countText(0, { n_notutor: 0 }, {}), "");
  assert.strictEqual(TT.countText(1, { n_notutor: 0 }, {}), "1 lesson");
  assert.strictEqual(TT.countText(12, { n_notutor: 2 }, {}), "12 lessons · 2 with no tutor");
  assert.strictEqual(TT.countText(2, { n_notutor: 2 }, { notutor: true }), "2 lessons");
  assert.match(TT.emptyText({ notutor: true, view: "week" }).title, /Every lesson has a tutor/);
  assert.match(TT.emptyText({ tutor: ID, view: "day" }).hint, /Clear them/);
  assert.match(TT.emptyText({ view: "week" }).title, /No lessons this week/);
  assert.match(TT.emptyText({ view: "next14", notutor: true }).hint, /next 14 days|waiting for a tutor/);
});

test("errors are plain words; a missing function is recognised", () => {
  assert.match(TT.errorText({ message: "NOT_FOUND" }), /isn’t available/);
  assert.match(TT.errorText({ message: "BAD_RANGE: ask for at most 62 days" }), /shorter period/);
  assert.match(TT.errorText({ message: "Failed to fetch" }), /Couldn’t reach the server/);
  assert.strictEqual(TT.isMissing({ code: "PGRST202", message: "x" }), true);
  assert.strictEqual(TT.isMissing({ code: "42883", message: "x" }), true);
  assert.strictEqual(TT.isMissing({ message: "NOT_FOUND" }), false);
});
