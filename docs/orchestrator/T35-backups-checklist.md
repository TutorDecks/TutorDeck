# T35 — Backups checklist for the owner

Written 2026-11-27 (T35-E). Plain words, no secrets: nothing in this file is a password, a key or a database address. Read together with README → **Backups** and **How to restore**, and `.github/workflows/db-backup.yml`.

**Where we really are today (checked in the files, not assumed):**
- A nightly encrypted copy of the live database (`public` + `auth` schemas) is made by GitHub Actions at 02:00 Singapore time and kept **30 days** as a workflow artifact.
- **No restore into a Supabase project has ever been recorded.** The steps were only tried on a local test database on 2026-10-20. Until the drill below is done, treat the backup as *unproven*.
- Nobody is told when a nightly run is **missed**; only a *failed* run sends GitHub's default email.
- Files in Supabase **Storage** (payment screenshots, teaching materials) are **not** in the dump.
- The workflow's sanity check does **not** look at the centre tables (`memberships`, `org_settings`, `audit_log`, `centre_invoices`…) that arrive when the organisation migrations reach LIVE.

**Do not promise "daily backups" to a paying centre in writing until items 1 to 3 are ticked.** Wording we can use after that: *"Nightly encrypted backups kept 30 days, plus Supabase's own daily backups."* And, for the export feature: *"Self-service export of all records (CSV, owner only, excludes passwords and billing-provider ids)."*

---

## 1. Restore drill (about 1 hour) — do this first

Goal: prove last night's backup really restores, and learn how long it takes. Nobody's real data leaves your own machine; the scratch project is deleted at the end.

1. GitHub → **Actions → DB backup → latest green run → Artifacts**: download `tutordeck-YYYY-MM-DD.dump.gpg` and unzip it. (If there is no green run in the last 2 days, stop: that is the problem to fix first.)
2. Decrypt it with the passphrase from your password manager (README step 2).
3. Create a **new, empty Supabase project** named like `restore-drill-YYYY-MM-DD` (free plan is fine). Copy its *Session pooler* connection string into a shell variable. **Never use the live project's string.**
4. Restore `public`, then the `auth` data (README steps 4 and 5). "schema public already exists" is expected.
5. Check, and write the numbers in the table below:
   - row counts of `students`, `lessons`, `invoices` (and `memberships`, `audit_log` once the organisation migrations are on LIVE) match the live Table editor within what changed since 02:00;
   - Authentication → Users has the same number of accounts;
   - sign in to a local copy of the app pointed at the scratch project (README / `assets/js/config.js` by hostname is DEV-by-default; for the drill temporarily use a local copy, do not commit it) with one real user, if you can, or just query a few rows.
6. **Delete the scratch project.** Delete the decrypted `.dump` file from your computer (keep only the `.gpg`).
7. Write the date, backup file name, minutes taken and pass / fail in README → Backups (one line).

| Date | Backup file | Minutes taken | students / lessons / users counted | Result | Done by |
|---|---|---|---|---|---|
| | | | | | |

If it fails, copy the error text and send it to the engineering chat: do not try to "fix" the live project.

## 2. Alert when a backup is missed (about 20 minutes, one small change)

Right now only a *failed* run is emailed. Two ways to also catch a run that never happened (the schedule can switch itself off after 60 days with no commits, a secret can be deleted, the database password can expire):
- **Easiest:** a second tiny workflow that runs every morning (09:00 Singapore), looks at the newest artifact of *DB backup*, and **fails if it is older than 26 hours** (GitHub then emails the repo admins). No secrets needed (it only reads artifact dates).
- **Or:** a last step in the backup workflow that pings a monitoring service's "heartbeat" address (a non-secret URL, no data in the request); the service emails you if the ping is missing. Free tiers exist; pick one with email *and* a second contact.

Either way, confirm **which email addresses GitHub actually notifies** (repo → Settings → Notifications / your own GitHub notification settings, "Actions" section) and that at least two people receive them. This is a change to `.github/workflows/`, so the engineering chat builds it when you say go (CI minutes are limited: it is one short run a day).

## 3. Supabase's own backups — plan tier (decide before the first paying centre)

What Supabase says today (docs and pricing pages read on 2026-11-27; **check the pages again on the day you decide**, prices and terms change):
- **Free plan:** no daily backups listed. Free projects also **pause after a week of inactivity**.
- **Pro plan** (listed at US$25 a month): **daily backups kept 7 days**, restorable from the dashboard (Database → Backups).
- **Team plan:** daily backups kept 14 days. Enterprise: up to 30 days.
- **Point-in-time recovery (PITR)** is an add-on (listed at US$100 a month per 7 days of retention, Pro and above). With it you can restore to a chosen minute; it **replaces** the daily snapshots rather than adding to them.
- Our nightly dump then becomes the **second, independent copy** (different company, different place), which is what you want.

Recommendation: move LIVE to **Pro** before the first paying centre goes live (this is also needed for Vercel Pro / non-commercial reasons already on the go-live list). Keep PITR as "only if a centre asks", because losing up to a day of data is already covered by the export + nightly dump for the size we are today. Write down the decision and the date here: ______________.

## 4. A second copy of the passphrase

The nightly dumps are useless without the passphrase (the secret named `BACKUP_PASSPHRASE` in GitHub). **If it is lost, every backup is lost.**
- Keep it in your password manager **and** one more place: a second person's password manager, or printed and kept in a safe.
- Name one trusted person who knows where it is and how to use it (README → How to restore).
- Do not put it in this repo, in chat, or in an email. Never paste it into the GitHub log.
- Test once a year: decrypt one old artifact with the stored copy.

## 5. Files in Storage (payment screenshots, materials) — decide

The dump only has the *paths* of these files, not the files. Choose one and write it down:
- **A. Accept the gap, in writing:** "payment screenshots and uploaded materials are not backed up" (fine while few are used; say so in the Service Agreement).
- **B. Back them up:** a separate job copies the Storage buckets nightly (engineering task, phase 2; the data-export ZIP will also gain a "files" ZIP then).

Recommendation: A for now, B before a centre relies on payment screenshots as its proof of payment. Decision and date: ______________.

## 6. When the organisation migrations reach LIVE

Ask the engineering chat to extend the backup workflow's sanity check so it also fails when `memberships`, `org_settings`, `audit_log` and `centre_invoices` have no data section (and the new data-export functions are present). Until then a dump that silently misses them would still pass.

## 7. Closing a centre (what to tell the customer)

A closed centre's data stays in the encrypted nightly dumps for **up to 30 more days**, then ages out (we do not edit old backups). If Supabase daily backups are on, they keep it for their own retention (7 days on Pro). Say so in the closure message. Design: `docs/orchestrator/T35-closure-design.md`.

---

### Running list (tick when done)
- [ ] 1 Restore drill done, result written in README → Backups
- [ ] 2 Missed-backup alert live, two people receive it
- [ ] 3 Supabase plan decided (and moved), date written above
- [ ] 4 Second copy of the passphrase + named person
- [ ] 5 Storage files decision written down
- [ ] 6 Backup check extended for the organisation tables (at the LIVE migration)
