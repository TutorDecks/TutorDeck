#!/usr/bin/env node
// Prints the JSON the import page would send for the generated fake fixture (400 students, 200 tutors, 1,640 weekly lessons by default).
// tests/sql/run.sh feeds it to import_dry_run / import_commit, so the page's checks and the database's checks are proved to agree on the SAME
// data in the SAME shape. Fake data only (see make-import-fixture.js). Usage: node make-import-payload.js [--students N --tutors N --lessons N]
"use strict";
const IC = require("../../assets/js/import-core.js"), { generate } = require("./make-import-fixture.js");
const a = {}; for (let i = 2; i < process.argv.length; i += 2) a[process.argv[i].replace(/^--/, "")] = Number(process.argv[i + 1]);
const g = generate(Object.assign({ errors: 0 }, a));
const r = IC.validateFiles(IC.STAGE_A.map((k) => ({ name: IC.FILES[k].file, text: g.files[IC.FILES[k].file] })));
if (!r.ready) { console.error("fixture did not pass the page's own checks: " + r.errors.slice(0, 3).map(IC.describe).join(" | ")); process.exit(1); }
process.stdout.write(JSON.stringify(r.payload));
