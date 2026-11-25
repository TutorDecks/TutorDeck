# DEV apply pack (T26)
1. Open the **DEV** Supabase project (`tuzxsqkfzrjssnpcoale`) → SQL Editor → New query. NEVER LIVE (part 4 makes demo logins with a known password).
2. Paste the first block of `dev-apply-pack.sql` (up to "PART 1") and Run: it lists which earlier migrations are present and ends with `ready` or `NOT READY`. Fix anything `MISSING` first.
3. Paste the **whole** file and Run. The editor runs it as one batch: all-or-nothing, so a failure keeps nothing; search the file for the nearest `### PART` line above the reported error line.
4. Expected result (last query): 10 `POST-CHECK` rows, every line `present`. Running it again is safe and changes nothing.
5. Parts: 1 `staff_home` · 2 invite emails · 3 tutor profile (phone) · 4 demo logins `centre.staff@` / `centre.frontdesk@example.test` (password `Demo-Pass-2026`, needs the original demo seed's Demo Learning Centre).
6. Not included yet (branches don't exist): t3-2 `migration_staff_students.sql`, t24c-2 `migration_tutor_payout.sql`. Rebuild the pack when they land.
7. Undo, newest first: `migration_tutor_profile_down.sql`, `migration_invites_down.sql`, `migration_staff_home_down.sql` (files live on their branches until merged).
8. Undo part 4: on DEV delete the two users (`delete from auth.users where email in ('centre.staff@example.test','centre.frontdesk@example.test')`); not needed otherwise, they are dummy.
9. Tested on a throwaway Postgres: after the 7 standard migrations, applied 3 times, then the repo SQL tests, staff_home / invites / tutor_profile tests and the undo chain all passed.
10. Needs `extensions.crypt` (present on every Supabase project) for part 4.
