-- =====================================================================================================
-- UNDO of db/seed_dev_demo_money.sql (T47). DEV DATABASE ONLY (project tuzxsqkfzrjssnpcoale). NEVER run this on the live project.
-- Removes only what the money seed created, found by its markers, and leaves everything else (the demo centre, its tutors, staff, students,
-- lessons and settings from db/seed_dev_demo.sql, and anything you added yourself) alone:
--   * the 26 demo students (ids 00000000-0000-0000-0000-0000000e0101 … 0e0135) and everything that hangs from them: lessons, tutor links,
--     invoices and their lines, late-fee proposals, payments and allocations, family credit, deposits and their ledger, refunds and their events,
--     and the households that only those students belonged to (with their guardians);
--   * the settings versions the seed saved (marked data.seed_money = "t47"); the settings in force before the seed come back by themselves;
--   * the invoice number counters, but ONLY when no numbered document is left at the centre (so numbers start from 1 again on the next run);
--   * the two extra staff logins centre.billing@ and centre.cashier@example.test (their membership first, then the login; the sign-up safety
--     net removes their solo organisation).
-- Money records are append-only on purpose. They are removed here the way the app removes a whole organisation (the session flag
-- td.deleting_org, which the guards accept only for the row's own organisation and never for a browser login), narrowed to the rows above.
-- The audit log keeps its history (it is append-only and is not touched). Every DELETE has a WHERE (the Supabase API refuses one without).
-- Safe to run twice: the second run finds nothing to remove.
-- =====================================================================================================
do $down$
declare
  c uuid; n int; found_list text; sids uuid[]; hhs uuid[]; invs uuid[]; pays uuid[]; refs uuid[]; k int;
  billing_id constant uuid := '00000000-0000-0000-0000-00000000d108';
  cashier_id constant uuid := '00000000-0000-0000-0000-00000000d109';
begin
  select count(*), string_agg(o.trading_name || ' (' || o.id || ')', '; '), (array_agg(o.id))[1] into n, found_list, c
    from organisations o
    where o.kind = 'centre'
      and exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = o.id and m.role = 'owner' and m.status = 'active' and u.email = 'centre.owner@example.test')
      and exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = o.id and m.role = 'tutor' and m.status = 'active' and u.email = 'tutor.one@example.test')
      and exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = o.id and m.role = 'tutor' and m.status = 'active' and u.email = 'tutor.two@example.test');
  if n = 0 then raise exception 'REFUSED: the DEV demo centre was not found. This is not the DEV demo database.'; end if;
  if n > 1 then raise exception using message = 'REFUSED: ' || n || ' centres match the demo centre (' || found_list || '). Not guessing: ask the project owner.'; end if;
  if exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = c and u.email not like '%@example.test') then
    raise exception 'REFUSED: the centre has a member whose login is not an @example.test address. This does not look like the DEV demo data.'; end if;

  select coalesce(array_agg(id), '{}'), coalesce(array_agg(distinct household_id) filter (where household_id is not null), '{}') into sids, hhs
    from students where org_id = c and id::text like '00000000-0000-0000-0000-0000000e01%';
  select coalesce(array_agg(id), '{}') into invs from centre_invoices where org_id = c and (student_id = any(sids) or household_id = any(hhs));
  select coalesce(array_agg(id), '{}') into pays from centre_payments where org_id = c and household_id = any(hhs);
  select coalesce(array_agg(id), '{}') into refs from centre_refunds where org_id = c and (student_id = any(sids) or household_id = any(hhs));

  -- the whole-organisation exception, narrowed by the WHERE clauses below; transaction-local, cleared at the end
  perform set_config('td.deleting_org', c::text, true);
  perform set_config('td.skip_audit', '1', true);

  delete from centre_deposit_ledger where org_id = c and student_id = any(sids);
  delete from centre_family_credit where org_id = c and household_id = any(hhs);
  delete from centre_refund_events where org_id = c and refund_id = any(refs);
  delete from centre_refunds where org_id = c and id = any(refs);
  delete from centre_deposits where org_id = c and student_id = any(sids);
  delete from centre_late_fees where org_id = c and (invoice_id = any(invs) or household_id = any(hhs));
  delete from centre_payment_allocations where org_id = c and (invoice_id = any(invs) or payment_id = any(pays));
  delete from centre_payments where org_id = c and id = any(pays) and kind = 'reversal';
  delete from centre_payments where org_id = c and id = any(pays);
  delete from centre_invoices where org_id = c and id = any(invs) and kind = 'credit_note';      -- credit notes point at their invoice: first
  delete from centre_invoices where org_id = c and id = any(invs);                                 -- their lines go with them (cascade)
  delete from lessons where org_id = c and student_id = any(sids);
  delete from student_tutors where org_id = c and student_id = any(sids);
  delete from students where org_id = c and id = any(sids);
  delete from guardians where org_id = c and household_id = any(hhs) and not exists (select 1 from students s where s.household_id = guardians.household_id);
  delete from households where org_id = c and id = any(hhs) and not exists (select 1 from students s where s.household_id = households.id);
  delete from org_settings where org_id = c and settings #>> '{data,seed_money}' = 't47';
  delete from org_counters where org_id = c and not exists (select 1 from centre_invoices i where i.org_id = c and i.number_seq is not null);

  perform set_config('td.deleting_org', '', true);
  perform set_config('td.skip_audit', '', true);

  -- the two extra staff logins (membership first; the sign-up safety net then removes each one's solo organisation with the login)
  delete from memberships where org_id = c and user_id in (billing_id, cashier_id);
  delete from auth.identities where user_id in (billing_id, cashier_id);
  delete from auth.users where id in (billing_id, cashier_id);
  raise notice 'Money demo data removed (students %, invoices %, payments %, refunds %).', cardinality(sids), cardinality(invs), cardinality(pays), cardinality(refs);
end $down$;
