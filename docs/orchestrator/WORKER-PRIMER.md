# Worker primer (read this INSTEAD of CLAUDE.md and BOARD.md unless your brief says otherwise)

Short on purpose: it exists so workers do not spend tokens re-reading long files. Read only what your brief names, plus this page. Open CLAUDE.md only for a specific section when the brief points to one.

## Rules that never change
- Branch: work and push ONLY on your own branch named in the brief. Never push to `main` or `dev`, never force-push, no PRs unless told. Commit with the usual trailers.
- Data: LIVE Supabase project `rnjvswkejbrhbaytutai` is never touched. DEV `tuzxsqkfzrjssnpcoale` (dummy data) may be READ; apply SQL there only if your brief says so. No secrets in files, chat or commits. No customer names, agreed prices or phone numbers in the repo (say "the first managed centre"); fixtures are invented, `@example.test` emails.
- Product principle: anything a centre could reasonably decide differently is a SETTING (org_settings, assets/js/org-settings.js, validated in SQL by org_validate_settings, enum test in tests/org-settings.test.js, a test per value; unbuilt values marked `soon`). Fixed (never settings): integrity (nobody marks before the day, nobody overwrites another's mark, tutors never see parents' fees/rates/amount/paid or edit price/date/time, tutors have NO table access, only SECURITY DEFINER functions with explicit column lists; a tutor MAY see their own pay if the centre setting allows).
- Money: integer cents only, maths in assets/js/money.js, GST once per invoice half-up. Append-only: audit log, org_settings, issued invoices (fix with credit notes / reversal rows).
- SQL gotcha: the Supabase API layer refuses `DELETE`/`UPDATE` without `WHERE` (SQLSTATE 21000); the local test Postgres does not. Use `where true` in functions. New migrations are NEW files with a `_down`, idempotent (safe to run twice), applied in the order listed in CLAUDE.md.
- House style: Manrope, ink #13233F, teal #0F766E the only accent, CSS variables from assets/css/app.css, phone-first (breakpoint 820px), one primary action per screen, own distinct icon per destination. Saved per-user state via `TL.store`, never raw localStorage. Pages call `TL.requireAuth("navId", init)`.
- Every JS/CSS change: bump `?v=N` with `bash bump-version.sh N` (next number above the highest on your branch), regenerate dark.css if CSS changed, add a README "Raphael's updates" entry (newest first), keep a minimal CLAUDE.md migration-order note.

## Tests (run locally; GitHub checks do not run on branches)
- Targeted first: `node --test tests/<name>.test.js`; one file of SQL: see tests/sql/run.sh.
- Before finishing, once each: `node --test tests/*.test.js`; `bash tests/sql/run.sh` (all migrations in order, applied twice, undo check); the browser check for the pages you touched (`python3 tests/server.py 8765` then `node tests/<page>.check.js`), at 390px width.

## Being economical
- Read only the files your brief names and the code you change; do not read whole plans if a section is named; do not re-read files you already read; do not re-run the full suite after every small edit.
- If blocked (permission prompt, missing connector, 503 after a few retries with pauses), stop and report what you need instead of looping.
- Finish with a block headed `ORCHESTRATOR SUMMARY`: what changed (3-6 lines), tests and results, what you did NOT test, decisions for the owner (with your recommendation), files touched, migration names in apply order.
