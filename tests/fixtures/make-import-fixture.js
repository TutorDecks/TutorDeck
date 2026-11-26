#!/usr/bin/env node
// Fake data for the centre import (T33 plan section 7). Seeded random: the same arguments always give the same files.
// ALL names, phone numbers and emails are made up (syllable lists, @example.test). Nothing here is real; never put real data in this folder.
//
//   node tests/fixtures/make-import-fixture.js --students 400 --tutors 200 --lessons 1640 --deposits 37 --invoices 12 --errors 0 [--seed 1] [--out DIR]
//
// Writes the six CSV files (and planted.json: the errors put in on purpose) to DIR, default <tmp>/td-import-fixture. Keep DIR OUTSIDE the repo.
// Also usable from tests:  require("./make-import-fixture").generate({ errors: 3 }) → { files, planted, counts }
"use strict";
const fs = require("fs"), os = require("os"), path = require("path");
const IC = require("../../assets/js/import-core.js");

function rng(seed) {                       // mulberry32
  let a = seed >>> 0;
  return function () { a = (a + 0x6D2B79F5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}
const FIRST_A = ["Ka", "Mi", "Ra", "Li", "To", "Ni", "Sa", "Ju", "Be", "Da", "Ev", "Fa", "Gr", "Ha", "Ia", "Jo", "Ke", "Lu", "Ma", "No"];
const FIRST_B = ["ra", "lo", "ni", "mo", "ta", "vi", "le", "su", "na", "ri", "do", "ke"];
const FIRST_C = ["n", "h", "a", "l", "s", "y", ""];
const LAST_A = ["Ta", "Li", "Wo", "Ch", "Ng", "Ko", "Ba", "Pe", "Ra", "Sa", "Yo", "Zh"];
const LAST_B = ["n", "m", "k", "ng", "w", "r", "s", "o"];
const SUBJECTS = ["Mathematics", "English", "Science", "Chinese", "Physics", "Chemistry", "Biology"];
const LEVELS = ["P1", "P2", "P3", "P4", "P5", "P6", "S1", "S2", "S3", "S4", "S5", "JC1", "JC2"];

function generate(o) {
  o = Object.assign({ students: 400, tutors: 200, lessons: 1640, deposits: 37, invoices: 12, errors: 0, seed: 20261126, today: "2026-11-26" }, o || {});
  const R = rng(o.seed), pick = (a) => a[Math.floor(R() * a.length)], int = (lo, hi) => lo + Math.floor(R() * (hi - lo + 1));
  const pad = (n, w) => String(n).padStart(w, "0");
  const person = () => pick(FIRST_A) + pick(FIRST_B) + pick(FIRST_C);
  const surname = () => pick(LAST_A) + pick(LAST_B);
  const iso = (y, m, d) => y + "-" + pad(m, 2) + "-" + pad(d, 2);

  // ---- families, guardians, students
  const families = [], students = [];
  let famN = 0, phoneN = 0;
  while (students.length < o.students) {
    famN++;
    const ref = "F" + pad(famN, 4), sn = surname(), kids = R() < 0.25 ? (R() < 0.8 ? 2 : 3) : 1;
    const nG = R() < 0.6 ? 2 : 1;
    for (let g = 0; g < nG; g++) {
      phoneN++;
      const nm = person() + " " + sn;
      families.push({ family_ref: ref, family_name: sn + " family", guardian_name: nm, relation: g === 0 ? "Mother" : "Father",
        phone: g === 0 ? "9" + pad(phoneN + 1000000, 7) : "8" + pad(phoneN + 1000000, 7), email: g === 0 ? "guardian" + famN + "@example.test" : "", main: g === 0 ? "Y" : "N" });
    }
    for (let k = 0; k < kids && students.length < o.students; k++) {
      const n = students.length + 1, lv = pick(LEVELS);
      students.push({ student_ref: "S" + pad(n, 4), family_ref: ref, student_name: person() + " " + sn, level: lv, lesson_location: R() < 0.6 ? "Online" : "Centre",
        online_link: R() < 0.5 ? "https://meet.example.test/s" + n : "", start_date: iso(2025 + int(0, 1), int(1, 10), int(1, 28)), notes: R() < 0.1 ? "Prefers mornings" : "" });
    }
  }
  // ---- tutors
  const tutors = [];
  for (let i = 1; i <= o.tutors; i++) {
    const fn = person(), ln = surname(), method = pick(["per_lesson", "per_hour", "monthly_fixed", "percent_of_fee", "", ""]);
    tutors.push({ tutor_email: (fn + "." + ln + i).toLowerCase() + "@example.test", tutor_name: fn + " " + ln, phone: (i % 2 ? "9" : "8") + pad(2000000 + i, 7),
      subjects: pick(SUBJECTS) + ";" + pick(SUBJECTS), employment: pick(["employee", "freelancer"]),
      pay_method: method, pay_amount: !method ? "" : method === "percent_of_fee" ? String(int(30, 60)) + ".5" : String(int(20, 60)) + ".00", pay_from: method ? "2026-12-01" : "" });
  }
  // ---- weekly 1-to-1 lessons: no overlap for a student, none for a tutor (so the clean fixture has no warnings either)
  const lessons = [], occS = {}, occT = {}, D = IC.DAYS;
  const free = (m, k, s, e) => !(m[k] || []).some((x) => s < x[1] && x[0] < e);
  const mins = (h, m) => h * 60 + m, hhmm = (x) => pad(Math.floor(x / 60), 2) + ":" + pad(x % 60, 2);
  const per = Math.floor(o.lessons / Math.max(1, o.students)), extra = o.lessons - per * o.students;
  for (let si = 0; si < students.length && lessons.length < o.lessons; si++) {
    const want = per + (si < extra ? 1 : 0), st = students[si];
    for (let w = 0; w < want; w++) {
      for (let tries = 0; tries < 400; tries++) {
        const day = pick(D), weekend = day === "Sat" || day === "Sun", dur = pick([60, 60, 90, 120]);
        const lo = weekend ? mins(9, 0) : mins(15, 0), hi = weekend ? mins(18, 0) : mins(21, 0);
        const s = lo + 30 * int(0, Math.floor((hi - lo - dur) / 30)), e = s + dur, tu = pick(tutors).tutor_email;
        if (!free(occS, st.student_ref + day, s, e) || !free(occT, tu + day, s, e)) continue;
        (occS[st.student_ref + day] = occS[st.student_ref + day] || []).push([s, e]); (occT[tu + day] = occT[tu + day] || []).push([s, e]);
        const lv = R() < 0.5 ? st.level : "";
        lessons.push({ student_ref: st.student_ref, tutor_email: tu, day, start: hhmm(s), end: hhmm(e), subject: pick(SUBJECTS), level: lv,
          family_rate_per_hour: String(int(35, 95)) + (R() < 0.3 ? ".50" : ".00") });
        break;
      }
    }
  }
  // ---- deposits, unpaid invoices
  const dep = [], used = {};
  for (let i = 0; i < o.deposits && i < students.length; i++) {
    let s; do { s = pick(students); } while (used[s.student_ref]);
    used[s.student_ref] = 1;
    dep.push({ student_ref: s.student_ref, amount: String(int(2, 20) * 25) + ".00", received_date: iso(2026, int(8, 11), int(1, 25)), reference: "PayNow " + pick(["Aug", "Sep", "Oct", "Nov"]) });
  }
  const inv = [];
  for (let i = 0; i < o.invoices; i++) {
    const s = students[(i * 7) % students.length], amt = int(8, 40) * 10, paid = i % 3 === 0 ? int(1, 7) * 10 : 0;
    inv.push({ invoice_number: "OLD-" + pad(400 + i, 4), family_ref: s.family_ref, invoice_date: iso(2026, 11, 1), due_date: iso(2026, 11, 8), amount: amt + ".00", paid_so_far: paid + ".00",
      covers: "Nov 2026 lessons " + s.student_name, student_ref: s.student_ref });
  }
  const data = { families, students, tutors, weekly_lessons: lessons, deposits: dep, unpaid_invoices: inv };

  // ---- planted errors: (file, line, column, code, severity) each on its own untouched row, so every one is found exactly once
  const planted = [], touched = {}, extraCols = {}, invStu = {};
  inv.forEach((r) => { invStu[r.student_ref] = 1; });
  const recipes = [
    ["students", "start_date", "BAD_DATE", "error", (r) => { r.start_date = "31/02/2026"; }],
    ["students", "family_ref", "UNKNOWN_FAMILY", "error", (r) => { r.family_ref = "F9999"; }],
    ["tutors", "phone", "BAD_PHONE", "error", (r) => { r.phone = "12345678"; }],
    ["tutors", "employment", "BAD_VALUE", "error", (r) => { r.employment = "contractor"; }],
    ["students", "level", "UNKNOWN_LEVEL", "warning", (r) => { r.level = "Pri 5"; }],
    ["weekly_lessons", "family_rate_per_hour", "BAD_MONEY", "error", (r) => { r.family_rate_per_hour = "54.999"; }],
    ["weekly_lessons", "end", "END_BEFORE_START", "error", (r) => { r.end = r.start; }],
    ["weekly_lessons", "day", "BAD_VALUE", "error", (r) => { r.day = "Funday"; }],
    ["weekly_lessons", "student_ref", "UNKNOWN_STUDENT", "error", (r) => { r.student_ref = "S9999"; }],
    ["weekly_lessons", "subject", "TOO_LONG", "error", (r) => { r.subject = "x".repeat(61); }],
    ["weekly_lessons", "end", "BAD_DURATION", "error", (r) => { const m = r.start.split(":"); const t = +m[0] * 60 + +m[1] + 14; r.end = pad(Math.floor(t / 60), 2) + ":" + pad(t % 60, 2); }],
    ["deposits", "received_date", "FUTURE_DATE", "error", (r) => { r.received_date = "2027-12-31"; }],
    ["deposits", "amount", "OUT_OF_RANGE", "error", (r) => { r.amount = "0"; }],
    ["unpaid_invoices", "paid_so_far", "PAID_TOO_MUCH", "error", (r) => { r.paid_so_far = r.amount; }],
    ["unpaid_invoices", "invoice_number", "DUPLICATE_KEY", "error", (r, rows) => { r.invoice_number = rows[0].invoice_number; }, 1],
    ["families", "phone", "NEED_CONTACT", "error", (r) => { r.phone = ""; r.email = ""; }],
    ["students", "birth_date", "FORBIDDEN_COLUMN", "error", null]
  ];
  for (let n = 0; n < o.errors; n++) {
    const rc = recipes[n % recipes.length], file = rc[0];
    if (!rc[4]) { extraCols[file] = rc[1]; planted.push({ severity: rc[3], file: file + ".csv", line: 1, column: rc[1], code: rc[2] }); continue; }
    const rows = data[file], lo = rc[5] || 0;
    let idx; do { idx = int(lo, rows.length - 1); } while (touched[file + idx] || (file === "unpaid_invoices" && idx === 0) || (file === "students" && invStu[rows[idx].student_ref]));
    touched[file + idx] = 1;
    rc[4](rows[idx], rows);
    planted.push({ severity: rc[3], file: file + ".csv", line: idx + 2, column: rc[1], code: rc[2] });
  }
  const files = {};
  Object.keys(data).forEach((k) => {
    const cols = IC.FILES[k].cols.map((c) => c.name), head = cols.concat(extraCols[k] ? [extraCols[k]] : []);
    files[k + ".csv"] = toText([head].concat(data[k].map((r) => head.map((c) => (r[c] == null ? (c === extraCols[k] ? "1990-01-01" : "") : r[c])))));
  });
  return { files, planted, counts: { families: new Set(families.map((f) => f.family_ref)).size, guardians: families.length, students: students.length, tutors: tutors.length, weekly_lessons: lessons.length, deposits: dep.length, invoices: inv.length } };
}
function toText(rows) { return IC.toCsv(rows); }

if (require.main === module) {
  const a = {}; for (let i = 2; i < process.argv.length; i += 2) a[process.argv[i].replace(/^--/, "")] = process.argv[i + 1];
  const num = (k) => (a[k] != null ? Number(a[k]) : undefined);
  const out = a.out || path.join(os.tmpdir(), "td-import-fixture");
  const r = generate({ students: num("students"), tutors: num("tutors"), lessons: num("lessons"), deposits: num("deposits"), invoices: num("invoices"), errors: num("errors"), seed: num("seed") });
  fs.mkdirSync(out, { recursive: true });
  Object.keys(r.files).forEach((f) => fs.writeFileSync(path.join(out, f), r.files[f]));
  fs.writeFileSync(path.join(out, "planted.json"), JSON.stringify(r.planted, null, 2));
  console.log("Wrote " + Object.keys(r.files).length + " files to " + out + " " + JSON.stringify(r.counts) + "; planted errors: " + r.planted.length);
  if (/TutorDeck|tutordeck/i.test(out) && !/tmp|scratch/i.test(out)) console.log("Reminder: keep fixtures outside the repo.");
}
module.exports = { generate };
