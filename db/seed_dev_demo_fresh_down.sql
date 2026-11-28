-- =====================================================================================================
-- UNDO of db/seed_dev_demo_fresh.sql (T52). DEV DATABASE ONLY (project tuzxsqkfzrjssnpcoale). NEVER run this on the live project.
-- Removes the whole "Demo Fresh Centre" (found by its owner login fresh.owner@example.test, never by name) with everything a tester added to
-- it (students, lessons, invoices, payments, refunds, settings, tutor pay ...), then the six fresh logins. The old demo centre, its logins and
-- every other organisation are not touched.
-- Refuses (nothing removed) unless every member of that centre is an @example.test login.
-- A centre's money records are append-only on purpose. The centre is removed the way the app removes a whole organisation: the transaction-local
-- session flag td.deleting_org, which the guards accept only for the row's own organisation and never for a browser login. Every table with an
-- org_id cascades from organisations. The audit log keeps its history (append-only; not touched). The DELETEs have WHERE clauses.
-- Safe to run twice: the second run finds nothing to remove.
-- =====================================================================================================
do $down$
declare
  c uuid;
  ids constant uuid[] := array['00000000-0000-0000-0000-00000000d201', '00000000-0000-0000-0000-00000000d202', '00000000-0000-0000-0000-00000000d203',
                               '00000000-0000-0000-0000-00000000d204', '00000000-0000-0000-0000-00000000d205', '00000000-0000-0000-0000-00000000d206']::uuid[];
begin
  select o.id into c from organisations o join memberships m on m.org_id = o.id and m.role = 'owner' and m.user_id = ids[1] where o.kind = 'centre' limit 1;
  if c is not null then
    if exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = c and u.email not like '%@example.test') then
      raise exception 'REFUSED: the fresh centre has a member whose login is not an @example.test address. Not removing it.'; end if;
    perform set_config('td.deleting_org', c::text, true);
    perform set_config('td.skip_audit', '1', true);
    delete from organisations where id = c;
    perform set_config('td.deleting_org', '', true);
    perform set_config('td.skip_audit', '', true);
  end if;
  -- the six logins (the sign-up safety net removes each one's solo organisation with the login)
  delete from auth.identities where user_id = any(ids);
  delete from auth.users where id = any(ids) and email like 'fresh.%@example.test';
  raise notice 'Fresh demo centre removed (%).', coalesce(c::text, 'it was not there');
end $down$;
