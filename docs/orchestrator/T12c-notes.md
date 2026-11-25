# T12c notes: solo pages filter by the current organisation (steps 3 and 4 of T12)

Branch `claude/t12c-org-filter` (off `claude/t12b-current-org`, T12b's last commit merged in). Version v269 (T12b = 267, T18b = 268).

## How it works
- `assets/js/org-scope.js` (pure, unit-tested in `tests/org-scope.test.js`) + `TL.scope(query)`, `TL.orgFields(row|rows)`, `TL.orgId()` in `app.js`.
- Current organisation is a solo org with a uuid id: reads add `or=(org_id.eq.<id>,org_id.is.null)`; inserts get `org_id`.
- Id null (organisation tables missing, as on LIVE today), a centre, or any error: NO filter, no extra field = exactly the old behaviour.
- **Null `org_id` choice:** per T12 plan section 7, null counts as mine (`NULL_IS_MINE = true` in org-scope.js) until a LIVE preview shows zero null rows; then flip to a strict `.eq`.
- Step 4: while the current organisation is a centre the menu is Centre home (`org?id=`) / Centres (`org`) / Settings; solo pages redirect to `org?id=<id>` (a centre tutor goes to `tutor`). Allowed on a centre: org, settings, tutor. Tutor-only logins unchanged.
- `promotePastLessons()` (bulk scheduled->done) now scoped to the solo org and skipped while in a centre.

## Call sites changed (59 reads/inserts)
| where | kind | table |
|---|---|---|
| `students.js:37` | insert (TL.orgFields) | students |
| `students.js:242` | read (TL.scope) | students |
| `ledger.js:73` | read (TL.scope) | lessons |
| `ledger.js:89` | insert (TL.orgFields) | lessons |
| `ledger.js:111` | read (TL.scope) | invoices |
| `ledger.js:671` | insert (TL.orgFields) | invoices |
| `ledger.js:689` | read (TL.scope) | invoices |
| `ledger.js:698` | read (TL.scope) | lessons |
| `ledger.js:732` | read (TL.scope) | invoices |
| `ledger.js:884` | insert (TL.orgFields) | lessons |
| `ledger.js:900` | read (TL.scope) | lessons |
| `ledger.js:914` | insert (TL.orgFields) | lessons |
| `ledger.js:922` | read (TL.scope) | lessons |
| `ledger.js:933` | insert (TL.orgFields) | lessons |
| `ledger.js:1064` | read (TL.scope) | invoices |
| `ledger.js:1248` | read (TL.scope) | invoices |
| `ledger.js:1262` | read (TL.scope) | invoices |
| `ledger.js:1315` | read (TL.scope) | invoices |
| `ledger.js:1409` | insert (TL.orgFields) | invoices |
| `ledger.js:1557` | read (TL.scope) | students |
| `ledger.js:1561` | read (TL.scope) | recurring_slots |
| `ledger.js:1565` | read (TL.scope) | lessons |
| `ledger.js:1567` | read (TL.scope) | lessons |
| `dashboard.js:400` | read (TL.scope) | students |
| `dashboard.js:414` | read (TL.scope) | recurring_slots |
| `dashboard.js:416` | read (TL.scope) | lessons |
| `dashboard.js:468` | read (TL.scope) | exams |
| `planner.js:150` | read (TL.scope) | students |
| `planner.js:155` | read (TL.scope) | recurring_slots |
| `planner.js:193` | insert (TL.orgFields) | recurring_slots |
| `invoices.js:240` | read (TL.scope) | students |
| `invoices.js:243` | read (TL.scope) | invoices |
| `invoices.js:247` | read (TL.scope) | invoices |
| `student.js:21` | read (TL.scope) | students |
| `student.js:26` | read (TL.scope) | lessons |
| `student.js:27` | read (TL.scope) | lessons |
| `student.js:32` | read (TL.scope) | exams |
| `student.js:34` | read (TL.scope) | recurring_slots |
| `student.js:487` | insert (TL.orgFields) | exams |
| `student.js:503` | insert (TL.orgFields) | exams |
| `exams.js:55` | insert (TL.orgFields) | exams |
| `exams.js:71` | insert (TL.orgFields) | exams |
| `exams.js:144` | read (TL.scope) | students |
| `exams.js:148` | read (TL.scope) | recurring_slots |
| `exams.js:154` | read (TL.scope) | exams |
| `settings.js:184` | read (TL.scope) | students |
| `settings.js:188` | read (TL.scope) | lessons |
| `calendar.js:76` | read (TL.scope) | students |
| `calendar.js:77` | read (TL.scope) | recurring_slots |
| `calendar.js:78` | read (TL.scope) | exams |
| `calendar.js:80` | read (TL.scope) | lessons |
| `calendar.js:119` | read (TL.scope) | lessons |
| `calendar.js:617` | insert (TL.orgFields) | lessons |
| `calendar.js:701` | insert (TL.orgFields) | lessons |
| `calendar.js:761` | insert (TL.orgFields) | lessons |
| `calendar.js:1114` | read (TL.scope) | lessons |
| `calendar.js:1115` | read (TL.scope) | lessons |
| `calendar.js:1116` | read (TL.scope) | lessons |
| `calendar.js:1201` | read (TL.scope) | lessons |
Also in `app.js`: `promotePastLessons` (2 updates, scoped), `syncInvoicesForLessons` (invoices read + lessons read, scoped).

## Deliberately NOT changed
- Updates/deletes by row id (`.eq("id", …)`): they only reach ids a scoped page already loaded.
- `materials.js` (not in the brief), `detectRole()` student count (runs before the organisation is known), `profiles` queries (own row).
- Calendar's 4 `tutor_id` queries keep their `tutor_id` filter and are now also scoped.

## Results (DEV dummy data, local server, `.html` addresses, Playwright)
Crawl of 9 solo pages x 4 demo logins, base (T12b) vs this branch:
- solo.tutor: students, ledger, planner, invoices, exams, calendar, settings, insights text IDENTICAL; home figures identical (only differed by still-loading placeholders at the 3 s mark).
- both.tutor (solo org): all 9 pages identical.
- tutor.one: unchanged (one-item menu, /tutor, settings allowed).
- centre.owner: before, solo pages showed centre students/money (students 541 chars, ledger 639, calendar 700 vs solo-only); after, no centre names or money anywhere; with T12b's default the owner lands on `/org?id=…`, all solo pages redirect there, menu `Centre home | Centres | Settings` (desktop and 390px phone, no horizontal overflow); `/org` highlights Centres.
- both.tutor switcher: chip shows, menu lists "Your tuition" and the centre; choosing the centre (role tutor) lands on `/tutor` with the My lessons menu; `students` typed while there redirects to `/tutor`.
- No console/page errors in any run. `node --test tests/*.test.js`: 120 pass, 0 fail.

## Not tested
- `bash tests/sql/run.sh`: no Postgres in this container ("server not running"). No SQL or db/ file was touched (`git diff origin/claude/t12b-current-org -- db` is empty).
- Write flows (add student/lesson/payment) were not clicked through in the browser; covered by the unit guard that every insert carries `TL.orgFields`, and DEV rows are dummy. A staff (non-owner) centre login and a user with two centres were not tried.
- Real `.or()` behaviour of PostgREST on update (`promotePastLessons`) was exercised only implicitly (no errors on home/ledger loads).
