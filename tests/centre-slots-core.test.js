// Unit tests for the centre weekly-slots page logic (T3 step 7). No DOM, no network.  node --test tests/centre-slots-core.test.js
const test = require("node:test");
const assert = require("node:assert");
const SC = require("../assets/js/centre-slots-core.js");

const form = (o) => Object.assign({ students: ["s1"], weekday: "2", start: "16:00", end: "17:30", tutor: "", subject: "Math", rate: "60" }, o);

test("days: Monday is 0, like the Planner", () => {
  assert.strictEqual(SC.DAYS[0], "Monday"); assert.strictEqual(SC.DAYS[6], "Sunday");
  assert.strictEqual(SC.isoWeekday("2026-11-23"), 0);   // a Monday
  assert.strictEqual(SC.isoWeekday("2026-11-29"), 6);   // a Sunday
  assert.strictEqual(SC.isoWeekday("2026-11-26"), 3);   // Thursday
});

test("the form is checked the way the database checks it", () => {
  assert.deepStrictEqual(SC.validate(form(), "add"), {});
  assert.ok(SC.validate(form({ students: [] }), "add").students);
  assert.ok(SC.validate(form({ students: new Array(31).fill("x") }), "add").students);
  assert.deepStrictEqual(SC.validate(form({ students: [] }), "edit"), {}, "edit has no students to pick");
  assert.ok(SC.validate(form({ weekday: "" }), "add").weekday);
  assert.ok(SC.validate(form({ weekday: "7" }), "add").weekday);
  assert.ok(SC.validate(form({ weekday: "-1" }), "add").weekday);
  assert.deepStrictEqual(SC.validate(form({ weekday: "0" }), "add"), {}, "Monday (0) is a real day");
  assert.ok(SC.validate(form({ start: "" }), "add").start);
  assert.ok(SC.validate(form({ end: "" }), "add").end);
  assert.match(SC.validate(form({ start: "17:00", end: "16:00" }), "add").end, /end after it starts/);
  assert.match(SC.validate(form({ start: "17:00", end: "17:10" }), "add").end, /15 minutes to 8 hours/);
  assert.deepStrictEqual(SC.validate(form({ start: "17:00", end: "17:15" }), "add"), {}, "15 minutes is fine");
  assert.deepStrictEqual(SC.validate(form({ start: "08:00", end: "16:00" }), "add"), {}, "8 hours is fine");
  assert.ok(SC.validate(form({ start: "08:00", end: "16:01" }), "add").end, "more than 8 hours is not");
  assert.ok(SC.validate(form({ rate: "" }), "add").rate, "a new slot needs a rate");
  assert.deepStrictEqual(SC.validate(form({ rate: "" }), "edit"), {}, "an empty rate on edit means keep");
  assert.deepStrictEqual(SC.validate(form({ rate: "0" }), "add"), {});
  assert.deepStrictEqual(SC.validate(form({ rate: "1000" }), "add"), {});
  assert.ok(SC.validate(form({ rate: "1000.01" }), "add").rate);
  assert.ok(SC.validate(form({ rate: "-5" }), "add").rate);
  assert.ok(SC.validate(form({ rate: "abc" }), "add").rate);
  assert.ok(SC.validate(form({ rate: "45.555" }), "add").rate);
  assert.deepStrictEqual(SC.validate(form({ rate: "45.5" }), "add"), {});
  assert.ok(SC.validate(form({ subject: "x".repeat(61) }), "add").subject);
});

test("the arguments of staff_save_slot", () => {
  assert.deepStrictEqual(SC.saveArgs("c1", null, form({ tutor: "m1", students: ["a", "b"] }), "add"),
    { p_org: "c1", p_slot: null, p_students: ["a", "b"], p_weekday: 2, p_start: "16:00", p_end: "17:30", p_tutor: "m1", p_subject: "Math", p_rate: 60 });
  assert.deepStrictEqual(SC.saveArgs("c1", "sl1", form({ rate: "", subject: "  ", start: "16:00:00" }), "edit"),
    { p_org: "c1", p_slot: "sl1", p_students: null, p_weekday: 2, p_start: "16:00", p_end: "17:30", p_tutor: null, p_subject: null, p_rate: null });
  assert.strictEqual(SC.saveArgs("c1", null, form({ weekday: "0" }), "add").p_weekday, 0, "Monday stays 0, not null");
});

test("how a slot reads in the list", () => {
  const one = { students: [{ name: "Aiden" }], is_group: false, no_tutor: false, tutor_name: "Tutor One", start_time: "16:00:00", end_time: "17:30:00" };
  assert.strictEqual(SC.studentsText(one), "Aiden"); assert.strictEqual(SC.kindText(one), "");
  const cls = { students: [{ name: "A" }, { name: "B" }, { name: "C" }, { name: "D" }, { name: "E" }], is_group: true };
  assert.strictEqual(SC.studentsText(cls), "A, B, C +2"); assert.strictEqual(SC.kindText(cls), "Class of 5");
  assert.deepStrictEqual(SC.tutorLine(one), { text: "Tutor One", warn: false });
  assert.deepStrictEqual(SC.tutorLine({ no_tutor: true, tutor_name: null }), { text: "No tutor yet", warn: true });
  assert.match(SC.tutorLine({ no_tutor: true, tutor_name: "Former tutor" }).text, /Former tutor/);
  assert.strictEqual(SC.tutorLine({ no_tutor: true, tutor_name: "Former tutor" }).warn, true);
  assert.match(SC.timeText(one), /4(:00)? ?pm.*5:30 ?pm/i);
  assert.strictEqual(SC.rateText(60), "S$60/hr"); assert.strictEqual(SC.rateText("45.5"), "S$45.50/hr"); assert.strictEqual(SC.rateText(null), "");
  const g = SC.byDay([{ weekday: 2, id: "a" }, { weekday: 0, id: "b" }, { weekday: 2, id: "c" }]);
  assert.deepStrictEqual(g.map((d) => d.name), ["Monday", "Wednesday"]); assert.deepStrictEqual(g[1].rows.map((r) => r.id), ["a", "c"]);
  assert.strictEqual(SC.countText(0), ""); assert.match(SC.countText(1, null), /^1 weekly slot · no lessons made yet$/);
  assert.match(SC.countText(3, "2026-12-20", (d) => "20 Dec"), /3 weekly slots · lessons made up to 20 Dec/);
  assert.notStrictEqual(SC.emptyText(true).title, SC.emptyText(false).title);
});

test("the generator's answer, in the words the button shows", () => {
  assert.strictEqual(SC.generateMessage({ created: 12, skipped: 0, holidays: 2, ended: 0, no_tutor: 0, on_holiday: 0, slots: 3 }).head, "12 created, 0 skipped, 2 holidays");
  assert.strictEqual(SC.generateMessage({ created: 1, skipped: 1, holidays: 1, slots: 1 }).head, "1 created, 1 skipped, 1 holiday");
  assert.strictEqual(SC.generateMessage({ created: 0, skipped: 12, holidays: 0, slots: 3 }).text, "0 created, 12 skipped, 0 holidays Nothing new: these weeks were already created.");
  assert.match(SC.generateMessage({ created: 0, skipped: 0, holidays: 0, slots: 0 }).text, /no weekly slots yet/);
  assert.match(SC.generateMessage({ created: 4, skipped: 0, holidays: 0, slots: 1, no_tutor: 4 }).text, /4 new lessons have no tutor yet/);
  assert.match(SC.generateMessage({ created: 1, skipped: 0, holidays: 0, slots: 1, no_tutor: 1 }).text, /1 new lesson has no tutor yet/);
  assert.match(SC.generateMessage({ created: 4, skipped: 0, holidays: 0, slots: 1, ended: 2 }).text, /2 lessons were left out because the student has finished/);
  assert.match(SC.generateMessage({ created: 1, skipped: 0, holidays: 0, slots: 1, on_holiday: 1 }).text, /falls on a holiday, because this centre doesn’t skip holidays/);
  assert.strictEqual(SC.generateMessage({ created: 3, skipped: 0, holidays: 0, slots: 1 }).more.length, 0, "no second line when there is nothing to add");
  assert.strictEqual(SC.generateMessage(null).head, "0 created, 0 skipped, 0 holidays");
});

test("the saved / stopped notes say what was left alone", () => {
  assert.strictEqual(SC.savedText({ added: 1 }, "add"), "Weekly slot added");
  assert.strictEqual(SC.savedText({ added: 3 }, "add"), "Weekly slot added for 3 students");
  assert.strictEqual(SC.savedText({ lessons_left: 0 }, "edit"), "Weekly slot changed");
  assert.match(SC.savedText({ lessons_left: 4 }, "edit"), /4 lessons already created keep the old time and tutor/);
  assert.match(SC.savedText({ lessons_left: 1 }, "edit"), /1 lesson already created keep/);
  assert.strictEqual(SC.stoppedText({ lessons_left: 0 }), "Weekly slot stopped");
  assert.match(SC.stoppedText({ lessons_left: 3 }), /3 upcoming lessons already created stay in the timetable/);
});

test("assigned tutors and the online link", () => {
  assert.strictEqual(SC.assignedText([{ name: "A" }, { name: "B" }]), "A, B"); assert.strictEqual(SC.assignedText([]), "");
  assert.ok(SC.sameSet(["b", "a"], ["a", "b"])); assert.ok(!SC.sameSet(["a"], ["a", "b"])); assert.ok(SC.sameSet(null, []));
  assert.strictEqual(SC.linkProblem(""), ""); assert.strictEqual(SC.linkProblem("  "), "");
  assert.strictEqual(SC.linkProblem("https://meet.example.com/a?b=1"), "");
  assert.ok(SC.linkProblem("http://meet.example.com/a")); assert.ok(SC.linkProblem("javascript:alert(1)")); assert.ok(SC.linkProblem("https://a b"));
  assert.ok(SC.linkProblem("https://a.example.com/" + "x".repeat(500))); assert.ok(SC.linkProblem("meet.example.com"));
});

test("the database's refusals, in plain words", () => {
  const e = (m) => SC.errorText({ message: m });
  assert.match(e("NOT_ALLOWED: your account can't change the timetable at this centre"), /can’t change the timetable/);
  assert.match(e("NOT_FOUND"), /isn’t available any more/);
  assert.match(e("BAD_TIME: the lesson must end after it starts"), /must end after it starts/);
  assert.match(e("BAD_TIME: a lesson lasts 15 minutes to 8 hours"), /15 minutes to 8 hours/);
  assert.match(e("BAD_RATE: type the rate per hour"), /Type the rate/); assert.match(e("BAD_RATE: the rate per hour must be between 0 and 1000"), /between 0 and 1000/);
  assert.match(e("BAD_STUDENTS: pick at least one student"), /at least one student/); assert.match(e("BAD_STUDENTS: a class has at most 30 students"), /at most 30/);
  assert.match(e("BAD_STUDENTS: to change who is in a slot, stop it and add a new one"), /stop it and add a new one/);
  assert.match(e("STUDENT_ENDED: Kid s7's lessons have ended"), /^Kid s7’s lessons have ended/);
  assert.strictEqual(e("SLOT_CLASH: Kid s1 already has a weekly lesson at that time"), "Kid s1 already has a weekly lesson at that time.");
  assert.match(e("NOT_AVAILABLE: that person can't be given lessons at this centre"), /Pick someone else/);
  assert.match(e("BAD_LINK: the link must start with https://"), /https:\/\//);
  assert.match(e("BAD_TUTORS: a student has at most 20 assigned tutors"), /at most 20/);
  assert.match(e("BAD_RANGE: lessons can't be created for days that have passed"), /days that have passed/);
  assert.match(e("Failed to fetch"), /Couldn’t reach the server/);
  assert.ok(SC.isMissing({ code: "PGRST202" })); assert.ok(!SC.isMissing({ message: "NOT_FOUND" }));
});

test("B5-FIX H1: every save with a tutor says what happened to the assigned tutors", () => {
  assert.match(SC.savedText({ added: 1, assigned: [{ tutor_name: "Tutor One", student_name: "Kid 1" }], assign: { state: "added", tutor_name: "Tutor One" } }, "add"), /Tutor One was added to Kid 1’s assigned tutors/);
  assert.match(SC.savedText({ added: 1, assigned: [], assign: { state: "already", tutor_name: "Tutor One", already: 1 } }, "add"), /Tutor One is already one of the student’s assigned tutors/);
  assert.match(SC.savedText({ added: 3, assigned: [], assign: { state: "already", tutor_name: "Tutor One", already: 3 } }, "add"), /already one of the students’ assigned tutors/);
  assert.match(SC.savedText({ added: 1, assigned: [], assign: { state: "off", tutor_name: "Tutor One" } }, "add"), /Tutor One was not added to the student’s assigned tutors, because that option is switched off in settings/);
  assert.match(SC.savedText({ lessons_left: 2, assigned: [{ tutor_name: "Tutor Two", student_name: "Kid 2" }], assign: { state: "added" } }, "edit"), /Tutor Two was added to Kid 2’s assigned tutors/);
  assert.strictEqual(SC.savedText({ added: 1, assign: { state: "no_tutor" } }, "add"), "Weekly slot added");
  assert.strictEqual(SC.savedText({ added: 1, assigned: [] }, "add"), "Weekly slot added", "an older database answers without assign: nothing extra");
});
test("B5-FIX F: a student who is leaving can be kept in the class", () => {
  assert.match(SC.memberPreview("add", { returned: true, dry: true, would_create: 6 }, "Kid 4", "21 Dec"), /Kid 4 stays in the class.*6 lessons will be made again/);
  assert.match(SC.memberPreview("add", { returned: true, would_create: 0 }, "Kid 4", "21 Dec"), /No lessons need to be made again/);
  assert.strictEqual(SC.memberDone("add", { returned: true, created: 6 }, "Kid 4"), "Kid 4 stays in the class. 6 lessons made again");
  assert.strictEqual(SC.memberDone("add", { already: true }, "Kid 4"), "Kid 4 is already in this slot");
});
