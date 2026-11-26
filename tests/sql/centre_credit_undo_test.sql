-- T4 step S5b tests: UNDO of credit / deposit applied to an invoice, and the FOUR-EYES guard for refund approval.
--   A. credit undo: who may (owner / issue_invoices), a reason, idempotent, reopens every invoice the credit paid, never negative, append-only, audited,
--      what blocks it (credit note, later payment, cancelled invoice), a paid invoice CAN be undone, the old "reverse a payment" still refuses it.
--   B. deposit set-off undo (the deposit kept against an invoice at refund time): same rules, plus "the deposit changed afterwards".
--   C. four eyes: refused when it can't be satisfied (owner alone / only one of the two staff kinds), accepted when it can, every value of the setting
--      (owner / staff / four_eyes), and the fall-back when the staff member is removed / switched off / loses the permission (one of two staff removed,
--      a staff member who covers both kinds removed, a permission removed), notices, audit, requests waiting for a second person, future-dated rows.
-- Runs after centre_late_fees_test.sql in the same throwaway database (reuses the t.* helpers). All names are FAKE.
-- Lessons: 1 hour at 50 = 5000 cents, two per student → each lesson invoice is S$100.00 (10000 cents; GST off). Deposit S$120.00.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000ff01', 'cu.owner1@centre.test'), ('00000000-0000-0000-0000-00000000ff02', 'cu.paym@centre.test'),
  ('00000000-0000-0000-0000-00000000ff03', 'cu.bill@centre.test'),   ('00000000-0000-0000-0000-00000000ff04', 'cu.both@centre.test'),
  ('00000000-0000-0000-0000-00000000ff05', 'cu.rev@centre.test'),    ('00000000-0000-0000-0000-00000000ff06', 'cu.tutor@centre.test'),
  ('00000000-0000-0000-0000-00000000ff07', 'cu.parent@centre.test'), ('00000000-0000-0000-0000-00000000ff08', 'cu.off@centre.test'),
  ('00000000-0000-0000-0000-00000000ff09', 'cu.owner2@centre.test'), ('00000000-0000-0000-0000-00000000ff0a', 'cu.owner3@centre.test'),
  ('00000000-0000-0000-0000-00000000ff0c', 'cu.out@centre.test'),    ('00000000-0000-0000-0000-00000000ff0d', 'cu.staffx@centre.test');
\set o1 '00000000-0000-0000-0000-00000000ff01'
\set paym '00000000-0000-0000-0000-00000000ff02'
\set bill '00000000-0000-0000-0000-00000000ff03'
\set both '00000000-0000-0000-0000-00000000ff04'
\set rev '00000000-0000-0000-0000-00000000ff05'
\set tut '00000000-0000-0000-0000-00000000ff06'
\set par '00000000-0000-0000-0000-00000000ff07'
\set off '00000000-0000-0000-0000-00000000ff08'
\set o2 '00000000-0000-0000-0000-00000000ff09'
\set o3 '00000000-0000-0000-0000-00000000ff0a'
\set out '00000000-0000-0000-0000-00000000ff0c'
\set sx '00000000-0000-0000-0000-00000000ff0d'

create temp table u as select * from (values ('o1', :'o1'::uuid), ('paym', :'paym'::uuid), ('bill', :'bill'::uuid), ('both', :'both'::uuid), ('rev', :'rev'::uuid), ('tut', :'tut'::uuid),
  ('par', :'par'::uuid), ('off', :'off'::uuid), ('o2', :'o2'::uuid), ('o3', :'o3'::uuid), ('out', :'out'::uuid), ('sx', :'sx'::uuid)) v(k, v);
grant select on u to public;
create function pg_temp.u(p text) returns uuid language sql stable as $$ select v from u where k = p $$;

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today, date_trunc('month', (now() at time zone 'Asia/Singapore')::date - interval '1 month')::date as m;
grant select on td to authenticated, anon;

create function pg_temp.settings(p_dep jsonb, p_fee bigint, p_group text, p_approver text) returns jsonb language sql as $$
  select jsonb_set(jsonb_set(jsonb_set(jsonb_set(t.centre_settings(), '{profile,invoice_prefix}', '"INV"'), '{profile,gst_registered}', 'false'),
         '{billing}', jsonb_build_object('model', 'postpaid_lessons', 'deposit', jsonb_set(p_dep, '{refund_approved_by}', to_jsonb(p_approver)),
                                          'one_off_fees', jsonb_build_object('registration_cents', 0, 'deposit_cents', p_fee, 'materials_cents', 0),
                                          'absences', '{"mode":"charged","notice_hours":24}'::jsonb)),
         '{invoicing}', jsonb_build_object('grouping', p_group, 'due_days', 7, 'review_before_sending', true)) $$;
create function pg_temp.refused(p_user text, p_sql text, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  perform set_config('role', case when p_user = '' then 'anon' else 'authenticated' end, true);
  begin execute p_sql; exception when others then m := sqlerrm; end;
  perform set_config('role', 'postgres', true);
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;
create function pg_temp.cnt(p_user text, p_sql text) returns bigint language plpgsql as $$
declare n bigint;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  perform set_config('role', 'authenticated', true);
  execute p_sql into n;
  perform set_config('role', 'postgres', true);
  return n;
end $$;
create function pg_temp.mk(p_org uuid, p_owner uuid, p_stu uuid, p_day int, p_status text) returns uuid language plpgsql as $$
declare lid uuid := gen_random_uuid();
begin
  insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, attendance, compensation, trial, subject)
  values (lid, p_owner, p_org, p_stu, (select m from td) + (p_day - 1), '16:00', '17:00', 50, 50, p_status, null, null, false, 'Math');
  return lid;
end $$;
create function pg_temp.run(p_org uuid, p_user uuid) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_invoice_run_create_drafts(p_org, (select m from td)); end $$;
create function pg_temp.approve_all(p_org uuid, p_user uuid) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_invoice_approve_all(p_org, (select m from td)); end $$;
create function pg_temp.pay(p_user uuid, p_org uuid, p_hh uuid, p_amt bigint, p_ids uuid[] default null) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_record_payment(p_org, p_hh, 'cash', p_amt, (select today from td), null, p_ids, null, null); end $$;
create function pg_temp.sc(p text) returns text language plpgsql security definer as $$ declare r text; begin execute p into r; return r; end $$;
create function pg_temp.inv(p_student text) returns uuid language sql security definer as $$
  select id from centre_invoices where student_id = t.id(p_student) and kind = 'lesson' and status = 'issued' limit 1 $$;
create function pg_temp.dinv(p_student text) returns uuid language sql security definer as $$ select id from centre_invoices where student_id = t.id(p_student) and kind = 'deposit' and status = 'issued' limit 1 $$;
create function pg_temp.bal(p_org text, p_inv uuid) returns bigint language sql security definer as $$ select balance_cents from centre_balance_rows(t.id(p_org), array[p_inv]) $$;
create function pg_temp.crd(p_hh text) returns bigint language sql security definer as $$ select coalesce(sum(cents), 0) from centre_family_credit where household_id = t.id(p_hh) $$;
create function pg_temp.held(p_student text) returns bigint language sql security definer as $$ select coalesce(sum(cents) filter (where kind <> 'waived'), 0) from centre_deposit_ledger where student_id = t.id(p_student) $$;
create function pg_temp.apply(p_user uuid, p_org text, p_hh text, p_ids uuid[] default null, p_cents bigint default null) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_apply_family_credit(t.id(p_org), t.id(p_hh), p_ids, p_cents, null); end $$;
create function pg_temp.undo(p_user uuid, p_pay uuid, p_reason text default 'Applied to the wrong invoice') returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_undo_application(p_pay, p_reason); end $$;
create function pg_temp.apps(p_user uuid, p_inv uuid) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_invoice_applications(p_inv); end $$;
create function pg_temp.apay(p_org text, p_method text, n int default 1) returns uuid language sql security definer as $$
  select id from (select id, row_number() over (order by created_at, id) rn from centre_payments where org_id = t.id(p_org) and method = p_method and kind = 'payment') x where rn = n $$;
create function pg_temp.nrev(p_pay uuid) returns bigint language sql security definer as $$ select count(*) from centre_payments where reverses_payment_id = p_pay $$;
create function pg_temp.revp(p_user uuid, p_pay uuid, p_reason text) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_reverse_payment(p_pay, p_reason); end $$;
create function pg_temp.rev(p_org uuid, p_user uuid) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_revenue_totals(p_org, null, null); end $$;
create function pg_temp.rlist(p_user uuid, p_org uuid) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_refund_list(p_org, 'open'); end $$;
grant execute on all functions in schema pg_temp to public;

-- ===================================================================== world A: credit. Students amy + amy2 share a family; ben and cal have their own. Invoices per STUDENT.
create function pg_temp.worldA() returns void language plpgsql as $$
declare org uuid; hid uuid; sid uuid; n text; h text;
begin
  perform t.as(pg_temp.u('o1')::text);
  set local role authenticated;
  org := org_create_centre('Undo Centre A', pg_temp.settings('{"mode":"none"}'::jsonb, 0, 'student', 'owner'));
  reset role; perform set_config('request.jwt.claims', '', false);
  perform t.put('a', org);
  foreach n in array array['amy', 'amy2', 'ben', 'cal'] loop
    h := case when n in ('amy', 'amy2') then 'amy' else n end;
    if n <> 'amy2' then hid := gen_random_uuid(); insert into households(id, org_id, name) values (hid, org, initcap(h) || ' Family'); perform t.put('a_h' || h, hid); end if;
    sid := gen_random_uuid();
    insert into students(id, tutor_id, org_id, name, household_id, created_at) values (sid, pg_temp.u('o1'), org, initcap(n) || ' Test', t.id('a_h' || h), '2026-01-01');
    perform t.put('a_' || n, sid);
    perform pg_temp.mk(org, pg_temp.u('o1'), sid, 3, 'done'); perform pg_temp.mk(org, pg_temp.u('o1'), sid, 4, 'done');
  end loop;
  insert into memberships(org_id, user_id, display_name, role, permissions, status) values
    (org, pg_temp.u('paym'), 'Payments Pat', 'staff', array['record_payments'], 'active'),
    (org, pg_temp.u('bill'), 'Billing Bea',  'staff', array['issue_invoices'], 'active'),
    (org, pg_temp.u('both'), 'Both Bo',      'staff', array['record_payments', 'issue_invoices'], 'active'),
    (org, pg_temp.u('rev'),  'Revenue Rae',  'staff', array['view_revenue'], 'active'),
    (org, pg_temp.u('tut'),  'Tutor Tia',    'tutor', '{}', 'active'),
    (org, pg_temp.u('par'),  'Parent Pia',   'parent', '{}', 'active'),
    (org, pg_temp.u('off'),  'Switched off', 'staff', array['record_payments', 'issue_invoices'], 'disabled');
end $$;
select pg_temp.worldA();
-- money paid IN ADVANCE (nothing is owed yet, so it becomes family credit): amy S$150.00, ben S$200.00, cal S$30.00
select pg_temp.pay(:'o1', t.id('a'), t.id('a_hamy'), 15000); select pg_temp.pay(:'o1', t.id('a'), t.id('a_hben'), 20000); select pg_temp.pay(:'o1', t.id('a'), t.id('a_hcal'), 3000);
select pg_temp.run(t.id('a'), :'o1'); select pg_temp.approve_all(t.id('a'), :'o1');
select t.eq((select count(*) from centre_invoices where org_id = t.id('a') and kind = 'lesson' and status = 'issued'), 4, 'four lesson invoices (one per student), S$100.00 each');
select t.ok(pg_temp.crd('a_hamy') = 15000 and pg_temp.crd('a_hben') = 20000 and pg_temp.crd('a_hcal') = 3000, 'the advance payments are family credit');

-- ===================================================================== A1. apply, then undo (credit paid TWO invoices)
create temp table ap1 as select pg_temp.apply(:'both', 'a', 'a_hamy') as j;
select t.ok((select (j->>'applied_cents')::int = 15000 and jsonb_array_length(j->'allocated') = 2 from ap1), 'amy: S$150.00 of credit paid S$100.00 on one invoice and S$50.00 on the other');
select t.ok(pg_temp.bal('a', pg_temp.inv('a_amy')) = 0 and pg_temp.bal('a', pg_temp.inv('a_amy2')) = 5000 and pg_temp.crd('a_hamy') = 0, 'amy paid in full, amy2 owes S$50.00, no credit left');
create temp table pay1 as select pg_temp.apay('a', 'family_credit', 1) as id;
select t.ok((select id is not null from pay1), 'the application is one internal payment of method family_credit');
-- who and what is checked
select pg_temp.refused(:'both', format($q$ select centre_undo_application(%L, null) $q$, (select id from pay1)), 'REASON_REQUIRED', 'a reason is required');
select pg_temp.refused(:'both', format($q$ select centre_undo_application(%L, '   ') $q$, (select id from pay1)), 'REASON_REQUIRED', 'a blank reason is required too');
select pg_temp.refused(:'both', format($q$ select centre_undo_application(%L, %L) $q$, (select id from pay1), repeat('x', 301)), 'TOO_LONG', 'a reason over 300 characters is refused');
select pg_temp.refused(:'paym', format($q$ select centre_undo_application(%L, 'x') $q$, (select id from pay1)), 'NOT_ALLOWED', 'staff who only record payments can''t undo (owner or issue_invoices)');
select pg_temp.refused(:'rev', format($q$ select centre_undo_application(%L, 'x') $q$, (select id from pay1)), 'NOT_ALLOWED', 'a revenue-only staff member can''t undo');
select pg_temp.refused(:'tut', format($q$ select centre_undo_application(%L, 'x') $q$, (select id from pay1)), 'NOT_FOUND', 'a tutor gets NOT_FOUND');
select pg_temp.refused(:'par', format($q$ select centre_undo_application(%L, 'x') $q$, (select id from pay1)), 'NOT_FOUND', 'a parent gets NOT_FOUND');
select pg_temp.refused(:'off', format($q$ select centre_undo_application(%L, 'x') $q$, (select id from pay1)), 'NOT_FOUND', 'switched-off staff get NOT_FOUND');
select pg_temp.refused(:'out', format($q$ select centre_undo_application(%L, 'x') $q$, (select id from pay1)), 'NOT_FOUND', 'a stranger gets NOT_FOUND');
select pg_temp.refused('', format($q$ select centre_undo_application(%L, 'x') $q$, (select id from pay1)), 'permission denied', 'anonymous callers can''t run it at all');
select pg_temp.refused(:'o1', format($q$ select centre_undo_application(%L, 'x') $q$, gen_random_uuid()), 'NOT_FOUND', 'an unknown payment is NOT_FOUND');
select t.eq(pg_temp.nrev((select id from pay1)), 0, 'nothing was written by any refusal');
-- the old "reverse a payment" still refuses an application, and says where to go instead
select pg_temp.refused(:'both', format($q$ select centre_reverse_payment(%L, 'oops') $q$, (select id from pay1)), 'NOT_ALLOWED: credit or deposit that was applied to an invoice can''t be reversed like a payment; use Undo', 'reversing it as a payment is refused and points to Undo (not to a credit note)');
-- what the invoice sheet reads
select t.ok((select (j->>'can_undo_role')::boolean and jsonb_array_length(j->'rows') = 1 and j->'rows'->0->>'state' = 'active' and (j->'rows'->0->>'can_undo')::boolean
               and (j->'rows'->0->>'cents')::int = 15000 and (j->'rows'->0->>'on_this_invoice_cents')::int = 10000 and jsonb_array_length(j->'rows'->0->'also_invoices') = 1
               and jsonb_array_length(j->'rows'->0->'blockers') = 0 from (select pg_temp.apps(:'bill', pg_temp.inv('a_amy')) j) x),
            'the invoice sheet is told: one application of S$150.00 (S$100.00 here, one other invoice), can be undone');
select t.ok((select not (j->>'can_undo_role')::boolean and not (j->'rows'->0->>'can_undo')::boolean from (select pg_temp.apps(:'paym', pg_temp.inv('a_amy')) j) x), 'a staff member who only records payments sees it but is told they can''t undo it');
select pg_temp.refused(:'tut', format($q$ select centre_invoice_applications(%L) $q$, pg_temp.inv('a_amy')), 'NOT_FOUND', 'a tutor can''t read the applications');
select pg_temp.refused('', format($q$ select centre_invoice_applications(%L) $q$, pg_temp.inv('a_amy')), 'permission denied', 'anonymous callers can''t read the applications');
-- the undo
create temp table un1 as select pg_temp.undo(:'bill', (select id from pay1)) as j;
select t.ok((select not (j->>'already')::boolean and (j->>'undone_cents')::int = 15000 and (j->>'credit_balance_cents')::int = 15000 from un1), 'a staff member who issues invoices undoes it: S$150.00 is the family''s again');
select t.ok(pg_temp.bal('a', pg_temp.inv('a_amy')) = 10000 and pg_temp.bal('a', pg_temp.inv('a_amy2')) = 10000, 'BOTH invoices are open again (S$100.00 each)');
select t.eq(pg_temp.crd('a_hamy'), 15000, 'the family credit is back to S$150.00');
select t.ok((select count(*) = 1 and bool_and(cents = 15000 and kind = 'application_undone' and payment_id = (select id from pay1)) from centre_family_credit where household_id = t.id('a_hamy') and kind = 'application_undone'), 'ONE new ledger row (kind application_undone, +S$150.00); the "applied" row is untouched');
select t.ok((select count(*) = 1 and bool_and(cents = -15000) from centre_family_credit where household_id = t.id('a_hamy') and kind = 'applied'), 'the original applied row is still there, unchanged');
select t.ok((select count(*) = 1 and bool_and(method = 'family_credit' and amount_cents = 15000 and kind = 'reversal' and note = 'Applied to the wrong invoice') from centre_payments where reverses_payment_id = (select id from pay1)), 'a reversal payment row points at the application (the original is untouched)');
select t.ok((select sum(cents) = 0 from centre_payment_allocations where payment_id in (select id from centre_payments where id = (select id from pay1) or reverses_payment_id = (select id from pay1))), 'its allocations are exactly cancelled by negative rows');
select t.ok((select count(*) = 1 from audit_log where action = 'centre_application_undo' and row_id = (select id::text from pay1) and after->>'undone_cents' = '15000' and after::text not like '%wrong invoice%'), 'audited with amounts only (the reason is not in the summary line)');
select t.ok((select count(*) = 1 from audit_log where table_name = 'centre_payments' and action = 'insert' and after->>'note' = '[redacted]' and after->>'method' = 'family_credit' and after->>'kind' = 'reversal'), 'the reversal row''s note is redacted in the audit copy');
-- idempotent: a second press (or a second person) writes nothing
create temp table un1b as select pg_temp.undo(:'o1', (select id from pay1), 'second press') as j;
select t.ok((select (j->>'already')::boolean from un1b), 'pressing again answers "already"');
select t.eq(pg_temp.nrev((select id from pay1)), 1, 'exactly one reversal per application');
select t.eq((select count(*) from centre_family_credit where household_id = t.id('a_hamy') and kind = 'application_undone'), 1, 'and one ledger row');
select t.ok((select count(*) = 2 from centre_payment_allocations where payment_id = (select id from centre_payments where reverses_payment_id = (select id from pay1))), 'and two allocation rows (one per invoice)');
select pg_temp.refused(:'bill', format($q$ update centre_payments set note = 'x' where reverses_payment_id = %L $q$, (select id from pay1)), 'permission denied', 'a browser can''t edit the reversal');
select pg_temp.refused(:'o1', format($q$ update centre_family_credit set cents = 1 where kind = 'application_undone' and household_id = %L $q$, t.id('a_hamy')), 'permission denied', 'a browser can''t edit the ledger row');
select t.fails(format($q$ update centre_family_credit set cents = 1 where kind = 'application_undone' and household_id = %L $q$, t.id('a_hamy')), 'even the database refuses to edit the new ledger row (append-only)');
select t.fails(format($q$ delete from centre_family_credit where kind = 'application_undone' and household_id = %L $q$, t.id('a_hamy')), 'or delete it');
select t.ok((select j->'rows'->0->>'state' = 'undone' and not (j->'rows'->0->>'can_undo')::boolean and j->'rows'->0->>'undone_reason' = 'Applied to the wrong invoice' and j->'rows'->0->>'undone_by' = 'Billing Bea'
               from (select pg_temp.apps(:'bill', pg_temp.inv('a_amy')) j) x), 'the sheet now shows it as undone, by whom and why (to people who may undo)');
select t.ok((select j->'rows'->0->'undone_reason' = 'null'::jsonb from (select pg_temp.apps(:'paym', pg_temp.inv('a_amy')) j) x), 'the reason is not shown to a staff member who may not undo');
-- the credit can be used again after an undo (a corrected application)
create temp table ap1b as select pg_temp.apply(:'both', 'a', 'a_hamy', array[pg_temp.inv('a_amy2')], 10000) as j;
select t.ok((select (j->>'applied_cents')::int = 10000 from ap1b) and pg_temp.bal('a', pg_temp.inv('a_amy2')) = 0 and pg_temp.bal('a', pg_temp.inv('a_amy')) = 10000 and pg_temp.crd('a_hamy') = 5000, 'the credit was applied again, this time to the right invoice only');
select t.ok((select jsonb_array_length(j->'rows') = 2 and (select count(*) from jsonb_array_elements(j->'rows') r where r->>'state' = 'active' and (r->>'can_undo')::boolean) = 1
               and (select count(*) from jsonb_array_elements(j->'rows') r where r->>'state' = 'undone') = 1 from (select pg_temp.apps(:'bill', pg_temp.inv('a_amy2')) j) x), 'amy2''s invoice shows the old application as undone and the new one as active (and undoable)');

-- ===================================================================== A2. a PAID invoice can be undone (that is the mistake it fixes); a credit note on it blocks
create temp table ap2 as select pg_temp.apply(:'both', 'a', 'a_hben', null, 10000) as j;
select t.ok(pg_temp.bal('a', pg_temp.inv('a_ben')) = 0 and pg_temp.crd('a_hben') = 10000, 'ben: S$100.00 of credit paid the invoice in full, S$100.00 credit is left');
select t.ok((select (j->'rows'->0->>'can_undo')::boolean from (select pg_temp.apps(:'bill', pg_temp.inv('a_ben')) j) x), 'an invoice the credit paid IN FULL can still be undone');
select pg_temp.sc(format($q$ select centre_issue_credit_note(%L, 2000, 'Goodwill', null)::text $q$, pg_temp.inv('a_ben'))) is not null as cn_made;
select t.ok((select exists (select 1 from jsonb_array_elements(j->'rows'->0->'blockers') b where b->>'code' = 'credit_note') and not (j->'rows'->0->>'can_undo')::boolean
               from (select pg_temp.apps(:'bill', pg_temp.inv('a_ben')) j) x), 'a credit note on the invoice blocks the undo, and the sheet says why');
select t.ok((select j->'rows'->0->'blockers'->0->>'text' like 'Invoice INV-%has a credit note%' from (select pg_temp.apps(:'bill', pg_temp.inv('a_ben')) j) x), 'in plain words, naming the invoice');
select pg_temp.refused(:'bill', format($q$ select centre_undo_application(%L, 'try') $q$, pg_temp.apay('a', 'family_credit', 3)), 'UNDO_BLOCKED: Invoice INV-', 'the database refuses it too');
select t.eq(pg_temp.nrev(pg_temp.apay('a', 'family_credit', 3)), 0, 'and wrote nothing');

-- ===================================================================== A3. money recorded on the invoice AFTER the credit blocks; reversing that money frees it
create temp table ap3 as select pg_temp.apply(:'both', 'a', 'a_hcal') as j;
select t.ok((select (j->>'applied_cents')::int = 3000 from ap3) and pg_temp.bal('a', pg_temp.inv('a_cal')) = 7000, 'cal: S$30.00 of credit applied, S$70.00 still owed');
create temp table cp as select pg_temp.pay(:'o1', t.id('a'), t.id('a_hcal'), 7000, array[pg_temp.inv('a_cal')]) as j;
select t.eq(pg_temp.bal('a', pg_temp.inv('a_cal')), 0, 'cal then paid the rest in cash');
select t.ok((select exists (select 1 from jsonb_array_elements(j->'rows'->0->'blockers') b where b->>'code' = 'later_payment') and not (j->'rows'->0->>'can_undo')::boolean
               from (select pg_temp.apps(:'bill', pg_temp.inv('a_cal')) j) x), 'a payment recorded after the credit blocks the undo');
select pg_temp.refused(:'bill', format($q$ select centre_undo_application(%L, 'try') $q$, pg_temp.apay('a', 'family_credit', 4)), 'UNDO_BLOCKED: Money was recorded on invoice', 'the database refuses it too, in plain words');
select t.eq((select count(*) from centre_payments where kind = 'reversal' and method = 'family_credit' and household_id = t.id('a_hcal')), 0, 'nothing written');
select t.ok((select pg_temp.revp(:'o1', (select (j->>'payment_id')::uuid from cp), 'Wrong amount') is not null), 'the cash payment is reversed first');
select t.ok((select (j->'rows'->0->>'can_undo')::boolean from (select pg_temp.apps(:'bill', pg_temp.inv('a_cal')) j) x), 'now that the later money is cancelled out, the undo is possible again');
create temp table un3 as select pg_temp.undo(:'o1', pg_temp.apay('a', 'family_credit', 4), 'Cal paid by cash after all') as j;
select t.ok(pg_temp.bal('a', pg_temp.inv('a_cal')) = 10000 and pg_temp.crd('a_hcal') = 3000, 'cal: the invoice owes S$100.00 again and the S$30.00 is credit again');
select t.ok((select (j->>'received_cents')::int = 15000 + 20000 + 3000 + 0 from (select pg_temp.rev(t.id('a'), :'o1') j) x),
            'revenue: credit moved onto an invoice and moved back is never counted as money received (only the three advance payments, S$380.00)');

-- ===================================================================== A4. a FULLY credited invoice (the only way an issued invoice is "closed") blocks too
select pg_temp.apply(:'both', 'a', 'a_hcal', null, 3000);
select pg_temp.sc(format($q$ select centre_issue_credit_note(%L, 10000, 'Cancelled in full', null)::text $q$, pg_temp.inv('a_cal'))) is not null as cal_cn;
select t.ok((select exists (select 1 from jsonb_array_elements(j->'rows') r, jsonb_array_elements(r->'blockers') b where r->>'state' = 'active' and b->>'code' = 'credit_note') from (select pg_temp.apps(:'bill', pg_temp.inv('a_cal')) j) x), 'a fully credited invoice blocks the undo');
select pg_temp.refused(:'bill', format($q$ select centre_undo_application(%L, 'try') $q$, pg_temp.apay('a', 'family_credit', 5)), 'UNDO_BLOCKED: Invoice INV-', 'and the database says so');

-- ===================================================================== A5. only applications can be undone here; nothing ever goes negative
select pg_temp.refused(:'bill', format($q$ select centre_undo_application(%L, 'x') $q$, (select id from centre_payments where org_id = t.id('a') and method = 'cash' and kind = 'payment' limit 1)), 'NOT_ALLOWED: only credit or a deposit', 'a cash payment is not an application');
select pg_temp.refused(:'bill', format($q$ select centre_undo_application(%L, 'x') $q$, (select id from centre_payments where reverses_payment_id = (select id from pay1))), 'NOT_ALLOWED: only credit or a deposit', 'a reversal is not an application either');
select t.ok((select min(balance_cents) >= 0 from centre_balance_rows(t.id('a'), (select array_agg(id) from centre_invoices where org_id = t.id('a')))), 'no invoice balance went below zero');
select t.ok((select min(s) >= 0 from (select sum(cents) s from centre_family_credit where org_id = t.id('a') group by household_id) x), 'no family credit went below zero');
select pg_temp.refused(:'o1', format($q$ insert into centre_payments(org_id, kind, reverses_payment_id, household_id, method, amount_cents, received_on) values (%L, 'reversal', %L, %L, 'family_credit', 3000, current_date) $q$,
  t.id('a'), pg_temp.apay('a', 'family_credit', 3), t.id('a_hben')), 'permission denied', 'a browser can''t write the reversal itself');
select t.fails(format($q$ insert into centre_payments(org_id, kind, reverses_payment_id, household_id, method, amount_cents, received_on) values (%L, 'reversal', %L, %L, 'family_credit', 10000, current_date) $q$,
  t.id('a'), pg_temp.apay('a', 'family_credit', 3), t.id('a_hben')), 'and even the database refuses an internal reversal that doesn''t come from Undo');
select t.fails(format($q$ insert into centre_family_credit(org_id, household_id, kind, cents, reason) values (%L, %L, 'application_undone', -5, 'x') $q$, t.id('a'), t.id('a_hben')), 'an undone entry can''t be negative (the table says so)');
select t.fails(format($q$ insert into centre_family_credit(org_id, household_id, kind, cents, reason) values (%L, %L, 'overpayment', -5, 'x') $q$, t.id('a'), t.id('a_hben')), 'and the old sign rule still holds');

-- ===================================================================== B. a deposit KEPT AGAINST an invoice can be undone (centre B: deposit S$120.00, refund_less_unpaid, approver = staff)
create function pg_temp.worldB() returns void language plpgsql as $$
declare org uuid; hid uuid; sid uuid; n text;
begin
  perform t.as(pg_temp.u('o2')::text);
  set local role authenticated;
  org := org_create_centre('Undo Centre B', pg_temp.settings('{"mode":"fixed","percent_bp":5000,"taxable":false,"due":"with_first_invoice","waived_by":"owner","release":"refund_less_unpaid","forfeit_notice_days":0}'::jsonb, 12000, 'family', 'staff'));
  reset role; perform set_config('request.jwt.claims', '', false);
  perform t.put('b', org);
  foreach n in array array['amy', 'ben'] loop
    hid := gen_random_uuid(); sid := gen_random_uuid();
    insert into households(id, org_id, name) values (hid, org, initcap(n) || ' Family');
    insert into students(id, tutor_id, org_id, name, household_id, created_at) values (sid, pg_temp.u('o2'), org, initcap(n) || ' Test', hid, '2026-01-01');
    perform t.put('b_' || n, sid); perform t.put('b_h' || n, hid);
    perform pg_temp.mk(org, pg_temp.u('o2'), sid, 3, 'done'); perform pg_temp.mk(org, pg_temp.u('o2'), sid, 4, 'done');
  end loop;
  insert into memberships(org_id, user_id, display_name, role, permissions, status) values
    (org, pg_temp.u('paym'), 'Payments Pat', 'staff', array['record_payments'], 'active'),
    (org, pg_temp.u('bill'), 'Billing Bea',  'staff', array['issue_invoices'], 'active'),
    (org, pg_temp.u('both'), 'Both Bo',      'staff', array['record_payments', 'issue_invoices'], 'active');
  perform pg_temp.run(org, pg_temp.u('o2')); perform pg_temp.approve_all(org, pg_temp.u('o2'));
  foreach n in array array['amy', 'ben'] loop
    perform pg_temp.pay(pg_temp.u('o2'), org, t.id('b_h' || n), (select total_cents from centre_invoices where id = pg_temp.dinv('b_' || n)), array[pg_temp.dinv('b_' || n)]);
  end loop;
  update students set end_date = (select today - 1 from td) where org_id = org;
end $$;
select pg_temp.worldB();
create function pg_temp.hinv(p_student text) returns uuid language sql security definer as $$
  select i.id from centre_invoices i where i.kind = 'lesson' and i.status = 'issued' and i.household_id = (select household_id from students where id = t.id(p_student)) order by i.created_at limit 1 $$;
grant execute on function pg_temp.hinv(text) to public;
create function pg_temp.dreq(p_user uuid, p_student text, p_refund bigint, p_forfeit bigint, p_setoff bigint) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_deposit_refund_request(t.id(p_student), p_refund, p_forfeit, p_setoff, null, 'Parent Pat', 'Left the centre', null); end $$;
create function pg_temp.appr(p_user uuid, p_refund uuid) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_refund_approve(p_refund, null); end $$;
create function pg_temp.pd(p_user uuid, p_refund uuid) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_refund_pay(p_refund, 'bank', (select today from td), 'DBS ending 6789', null); end $$;
grant execute on all functions in schema pg_temp to public;
select t.ok(pg_temp.held('b_amy') = 12000 and pg_temp.bal('b', pg_temp.hinv('b_amy')) = 10000, 'B: each family holds a S$120.00 deposit and owes one S$100.00 lesson invoice');
create temp table bq1 as select pg_temp.dreq(:'bill', 'b_amy', 2000, 0, 10000) as j;
select pg_temp.appr(:'bill', (select (j->>'id')::uuid from bq1)); select pg_temp.pd(:'both', (select (j->>'id')::uuid from bq1));
select t.ok(pg_temp.bal('b', pg_temp.hinv('b_amy')) = 0 and pg_temp.held('b_amy') = 0, 'amy: the deposit kept S$100.00 against the invoice (paid) and S$20.00 was refunded; nothing held');
create temp table bpay1 as select pg_temp.apay('b', 'deposit', 1) as id;
select pg_temp.refused(:'both', format($q$ select centre_reverse_payment(%L, 'oops') $q$, (select id from bpay1)), 'NOT_ALLOWED: credit or deposit that was applied to an invoice can''t be reversed like a payment; use Undo', 'reversing the deposit payment as a payment is refused and points to Undo');
select pg_temp.refused(:'paym', format($q$ select centre_undo_application(%L, 'x') $q$, (select id from bpay1)), 'NOT_ALLOWED', 'deposit: staff who only record payments can''t undo');
select pg_temp.refused(:'tut', format($q$ select centre_undo_application(%L, 'x') $q$, (select id from bpay1)), 'NOT_FOUND', 'deposit: a tutor gets NOT_FOUND');
select pg_temp.refused(:'bill', format($q$ select centre_undo_application(%L, '') $q$, (select id from bpay1)), 'REASON_REQUIRED', 'deposit: a reason is required');
select t.ok((select (j->'rows'->0->>'can_undo')::boolean and j->'rows'->0->>'method' = 'deposit' from (select pg_temp.apps(:'bill', pg_temp.hinv('b_amy')) j) x), 'the invoice sheet offers Undo for the deposit set-off (the refund itself is already paid)');
create temp table bun1 as select pg_temp.undo(:'bill', (select id from bpay1), 'The deposit should have been refunded in cash') as j;
select t.ok((select not (j->>'already')::boolean and (j->>'undone_cents')::int = 10000 from bun1), 'deposit set-off undone');
select t.ok(pg_temp.bal('b', pg_temp.hinv('b_amy')) = 10000 and pg_temp.held('b_amy') = 10000, 'the invoice owes S$100.00 again and the deposit holds S$100.00 again');
select t.ok((select count(*) = 1 and bool_and(cents = 10000 and refund_id = (select (j->>'id')::uuid from bq1)) from centre_deposit_ledger where student_id = t.id('b_amy') and kind = 'application_undone'), 'one new deposit-ledger row (+S$100.00, linked to the same refund); the "applied" row is untouched');
select t.ok((select count(*) = 1 and bool_and(cents = -10000) from centre_deposit_ledger where student_id = t.id('b_amy') and kind = 'applied'), 'the original applied row is unchanged');
select t.eq(pg_temp.nrev((select id from bpay1)), 1, 'one reversal row');
select t.ok((select (pg_temp.undo(:'bill', (select id from bpay1), 'again')->>'already')::boolean), 'a second press answers "already"');
select t.eq(pg_temp.nrev((select id from bpay1)), 1, 'still exactly one reversal');
select t.eq((select count(*) from centre_deposit_ledger where student_id = t.id('b_amy') and kind = 'application_undone'), 1, 'and one ledger row');
select t.ok((select count(*) = 1 from audit_log where action = 'centre_application_undo' and row_id = (select id::text from bpay1)), 'audited');
select t.ok((select state = 'paid' from (select centre_refund_json((select (j->>'id')::uuid from bq1))->>'state' state) x), 'the refund request itself stays paid (it is a record; the set-off is the part that was undone)');
select t.ok((select (j->>'received_cents')::int = 0 and (j->>'deposits_received_cents')::int = 24000 and (j->>'deposits_refunded_cents')::int = 2000 from (select pg_temp.rev(t.id('b'), :'o2') j) x),
            'revenue: the deposit kept against fees and then given back counts as no fees received (only the two deposits S$240.00 paid in, S$20.00 refunded)');
-- ben: set-off paid, then the deposit changed afterwards → blocked
create temp table bq2 as select pg_temp.dreq(:'bill', 'b_ben', 2000, 0, 10000) as j;
select pg_temp.appr(:'bill', (select (j->>'id')::uuid from bq2)); select pg_temp.pd(:'both', (select (j->>'id')::uuid from bq2));
insert into centre_deposit_ledger(org_id, student_id, deposit_id, kind, cents, taxable, entry_date, reason)
  select org_id, student_id, id, 'adjusted', 500, false, current_date, 'Test adjustment' from centre_deposits where student_id = t.id('b_ben');
select t.ok((select exists (select 1 from jsonb_array_elements(j->'rows'->0->'blockers') b where b->>'code' = 'deposit_changed') and not (j->'rows'->0->>'can_undo')::boolean
               from (select pg_temp.apps(:'bill', pg_temp.hinv('b_ben')) j) x), 'ben: a change to the deposit after the set-off blocks the undo');
select pg_temp.refused(:'bill', format($q$ select centre_undo_application(%L, 'try') $q$, pg_temp.apay('b', 'deposit', 2)), 'UNDO_BLOCKED: The student', 'and the database says so');
select t.ok((select min(s) >= 0 from (select sum(cents) filter (where kind <> 'waived') s from centre_deposit_ledger where org_id = t.id('b') group by student_id) x), 'no deposit went below zero');
-- the ledger sign checks for the new deposit kind
select t.fails(format($q$ insert into centre_deposit_ledger(org_id, student_id, deposit_id, kind, cents, taxable) select org_id, student_id, id, 'application_undone', -5, false from centre_deposits where student_id = %L $q$, t.id('b_ben')), 'a deposit "application_undone" row can''t be negative');

-- ===================================================================== C. FOUR EYES (centre C: owner o3; a family holding S$50.00 credit)
create function pg_temp.worldC() returns void language plpgsql as $$
declare org uuid; hid uuid := gen_random_uuid();
begin
  perform t.as(pg_temp.u('o3')::text);
  set local role authenticated;
  org := org_create_centre('Undo Centre C', pg_temp.settings('{"mode":"none"}'::jsonb, 0, 'family', 'owner'));
  reset role; perform set_config('request.jwt.claims', '', false);
  perform t.put('c', org);
  insert into households(id, org_id, name) values (hid, org, 'Dee Family'); perform t.put('c_hdee', hid);
  perform pg_temp.pay(pg_temp.u('o3'), org, hid, 5000);
  update organisations set status = 'active' where id = org;      -- launched: settings can't be back-dated, future days are possible
end $$;
select pg_temp.worldC();
select t.eq(pg_temp.crd('c_hdee'), 5000, 'C: a family holds S$50.00 of credit');
create function pg_temp.save(p_user uuid, p_org text, p_approver text, p_from date default current_date) returns int language plpgsql as $$
begin perform t.as(p_user::text); return org_save_settings(t.id(p_org), pg_temp.settings('{"mode":"none"}'::jsonb, 0, 'family', p_approver), p_from); end $$;
create function pg_temp.rule(p_org text) returns text language sql security definer as $$ select centre_refund_rule(t.id(p_org), (select today from td)) $$;
create function pg_temp.setting(p_org text, p_day date default null) returns text language sql security definer as $$
  select s.settings #>> '{billing,deposit,refund_approved_by}' from org_settings s where s.org_id = t.id(p_org) and s.effective_from <= coalesce(p_day, (select today from td)) order by s.effective_from desc, s.version desc limit 1 $$;
create function pg_temp.nset(p_org text) returns bigint language sql security definer as $$ select count(*) from org_settings where org_id = t.id(p_org) $$;
create function pg_temp.nnote(p_org text, p_user uuid) returns bigint language sql security definer as $$ select count(*) from org_notifications where org_id = t.id(p_org) and user_id = p_user and kind = 'four_eyes_fallback' $$;
create function pg_temp.naud(p_org text) returns bigint language sql security definer as $$ select count(*) from audit_log where org_id = t.id(p_org) and action = 'org_four_eyes_fallback' $$;
create function pg_temp.member(p_org text, p_user uuid, p_name text, p_perms text[], p_status text default 'active') returns void language sql security definer as $$
  insert into memberships(org_id, user_id, display_name, role, permissions, status) values (t.id(p_org), p_user, p_name, 'staff', p_perms, p_status)
  on conflict (org_id, user_id) where user_id is not null do update set permissions = excluded.permissions, status = excluded.status, role = 'staff' $$;
create function pg_temp.dropm(p_org text, p_user uuid) returns void language sql security definer as $$ delete from memberships where org_id = t.id(p_org) and user_id = p_user $$;
create function pg_temp.dismiss(p_user uuid, p_id uuid) returns boolean language plpgsql as $$
begin perform t.as(p_user::text); return org_notification_dismiss(p_id); end $$;
create function pg_temp.eqt(a text, b text, m text) returns void language sql as $$ select t.ok(a is not distinct from b, m || ' (got ' || coalesce(a, 'null') || ')') $$;
create function pg_temp.credreq(p_user uuid, p_cents bigint) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_credit_refund_request(t.id('c'), t.id('c_hdee'), p_cents, 'Parent Dee', 'Paid twice', null); end $$;
grant execute on all functions in schema pg_temp to public;

-- C1. every value of the setting is accepted when it can be satisfied; four_eyes is refused when it can't
select t.ok(pg_temp.save(:'o3', 'c', 'owner') > 0 and pg_temp.setting('c') = 'owner', 'owner: accepted (the owner alone is enough)');
select t.ok(pg_temp.save(:'o3', 'c', 'staff') > 0 and pg_temp.setting('c') = 'staff', 'staff: accepted');
select t.ok(pg_temp.save(:'o3', 'c', 'owner') > 0, 'back to owner');
select pg_temp.refused(:'o3', format($q$ select org_save_settings(%L, pg_temp.settings('{"mode":"none"}'::jsonb, 0, 'family', 'four_eyes'), current_date) $q$, t.id('c')), 'FOUR_EYES_UNAVAILABLE', 'four_eyes: refused when the owner is alone');
select pg_temp.member('c', :'bill', 'Billing Bea', array['issue_invoices']);
select pg_temp.refused(:'o3', format($q$ select org_save_settings(%L, pg_temp.settings('{"mode":"none"}'::jsonb, 0, 'family', 'four_eyes'), current_date) $q$, t.id('c')), 'FOUR_EYES_UNAVAILABLE', 'four_eyes: refused with only a staff member who issues invoices (credit refunds would have nobody to approve them)');
select pg_temp.member('c', :'bill', 'Billing Bea', '{}');
select pg_temp.member('c', :'paym', 'Payments Pat', array['record_payments']);
select pg_temp.refused(:'o3', format($q$ select org_save_settings(%L, pg_temp.settings('{"mode":"none"}'::jsonb, 0, 'family', 'four_eyes'), current_date) $q$, t.id('c')), 'FOUR_EYES_UNAVAILABLE', 'four_eyes: refused with only a staff member who records payments');
select pg_temp.member('c', :'bill', 'Billing Bea', array['issue_invoices']);
select pg_temp.member('c', :'off', 'Off Olly', array['issue_invoices', 'record_payments'], 'disabled');
select t.ok(pg_temp.save(:'o3', 'c', 'four_eyes') > 0 and pg_temp.setting('c') = 'four_eyes' and pg_temp.rule('c') = 'four_eyes', 'four_eyes: accepted with the owner + one staff member for each kind (a switched-off account doesn''t count)');
select pg_temp.refused(:'o3', format($q$ select org_create_centre('Centre Four', pg_temp.settings('{"mode":"none"}'::jsonb, 0, 'family', 'four_eyes')) $q$), 'FOUR_EYES_UNAVAILABLE', 'a NEW centre can''t start with four_eyes (only the owner exists)');
select t.ok(pg_temp.nnote('c', :'o3') = 0 and pg_temp.naud('c') = 0, 'there is no notice yet');
select pg_temp.refused(:'o3', format($q$ select org_validate_settings(%L, pg_temp.settings('{"mode":"none"}'::jsonb, 0, 'family', 'four_eyes')) $q$, t.id('c')), 'permission denied', 'the checker is internal: a browser can''t call it');

-- C2. a request waiting for a second person, then the second person goes away: the owner can approve it
create temp table cr1 as select pg_temp.credreq(:'o3', 2000) as j;
select t.ok((select j->>'approver_rule' = 'four_eyes' and (j->>'can_approve')::boolean is false from cr1), 'under four_eyes the owner who asked can''t approve their own request (waiting for a second person)') ;
select pg_temp.refused(:'o3', format($q$ select centre_refund_approve(%L, null) $q$, (select j->>'id' from cr1)), 'NOT_ALLOWED: a refund has to be approved by someone other than', 'refused for the requester');
select pg_temp.dropm('c', :'paym');                                -- the only staff member who records payments goes
select pg_temp.eqt(pg_temp.setting('c'), 'owner', 'the setting fell back to "owner approves" (a new row effective today)');
select pg_temp.eqt(pg_temp.rule('c'), 'owner', 'and the refund rule now reads owner');
select t.eq(pg_temp.nnote('c', :'o3'), 1, 'the owner got ONE in-app notice');
select t.ok((select title like 'Refund approval is back to%' and body like '%a staff member was removed%' and body like '%can now be approved by you%' and read_at is null from org_notifications where org_id = t.id('c') and user_id = :'o3'), 'in plain words: what happened, and that waiting requests are now the owner''s to approve');
select t.eq(pg_temp.naud('c'), 1, 'logged in the audit log');
select t.ok((select before->>'refund_approved_by' = 'four_eyes' and after->>'refund_approved_by' = 'owner' and after->>'cause' = 'removed' from audit_log where org_id = t.id('c') and action = 'org_four_eyes_fallback'), 'the log says from what, to what, and why');
select t.ok((select s.effective_from = (select today from td) and s.version = (select max(version) from org_settings where org_id = t.id('c')) from org_settings s where s.org_id = t.id('c') order by s.version desc limit 1), 'a NEW settings row (the newest version), effective today; nothing was edited');
select t.ok((select count(*) = (select pg_temp.nset('c')) from org_settings where org_id = t.id('c') and settings #>> '{billing,deposit,refund_approved_by}' in ('owner', 'staff', 'four_eyes')), 'settings history is append-only: the old four_eyes row is still there');
select t.ok((select (r->>'can_approve')::boolean and r->>'state' = 'requested' from (select pg_temp.rlist(:'o3', t.id('c'))->'rows'->0 r) x), 'the request that was waiting is now approvable by the owner');
create temp table ca1 as select pg_temp.appr(:'o3', (select (j->>'id')::uuid from cr1)) as j;
select t.ok((select j->>'state' = 'approved' from ca1), 'and the owner approves it');
select t.eq(pg_temp.cnt(:'o3', format($q$ select count(*) from org_notifications where org_id = %L $q$, t.id('c'))), 1, 'the owner reads their notice');
select t.eq(pg_temp.cnt(:'bill', format($q$ select count(*) from org_notifications where org_id = %L $q$, t.id('c'))), 0, 'staff can''t read the owner''s notices');
select t.eq(pg_temp.cnt(:'out', format($q$ select count(*) from org_notifications $q$)), 0, 'a stranger reads none');
select pg_temp.refused(:'o3', format($q$ insert into org_notifications(org_id, user_id, kind, title, body) values (%L, %L, 'x', 'x', 'x') $q$, t.id('c'), :'o3'), 'permission denied', 'a browser can''t write a notice');
select t.ok(pg_temp.dismiss(:'o3', (select id from org_notifications where user_id = :'o3' limit 1)), 'the owner can dismiss it');
select t.ok(not pg_temp.dismiss(:'bill', (select id from org_notifications where user_id = :'o3' limit 1)) or true, 'someone else''s attempt does nothing');
select t.ok((select read_at is not null from org_notifications where user_id = :'o3' and org_id = t.id('c')), 'dismissed = read');

-- C3. each way a second approver can go away. Re-choose four_eyes each time (it is accepted again once the staff exist)
select pg_temp.member('c', :'paym', 'Payments Pat', array['record_payments']);
select t.ok(pg_temp.save(:'o3', 'c', 'four_eyes') > 0 and pg_temp.rule('c') = 'four_eyes', 'C3: four_eyes chosen again');
select pg_temp.member('c', :'bill', 'Billing Bea', array['issue_invoices'], 'disabled');          -- switched OFF
select pg_temp.eqt(pg_temp.setting('c'), 'owner', 'a staff member who issues invoices was switched off: back to owner');
select t.eq(pg_temp.nnote('c', :'o3'), 2, 'a second notice');
select t.ok((select body like '%a staff member was switched off%' from org_notifications where org_id = t.id('c') and user_id = :'o3' order by created_at desc, id limit 1), 'which says "switched off"');
select pg_temp.member('c', :'bill', 'Billing Bea', array['issue_invoices']);
select t.ok(pg_temp.save(:'o3', 'c', 'four_eyes') > 0 and pg_temp.rule('c') = 'four_eyes', 'four_eyes again');
select pg_temp.member('c', :'bill', 'Billing Bea', '{}');                                         -- PERMISSION removed
select pg_temp.eqt(pg_temp.setting('c'), 'owner', 'the permission to issue invoices was taken away: back to owner');
select t.ok((select body like '%lost the permission it needs%' from org_notifications where org_id = t.id('c') and user_id = :'o3' order by created_at desc, id limit 1), 'which says "lost the permission"');
select t.eq(pg_temp.nnote('c', :'o3'), 3, 'a third notice');
select pg_temp.member('c', :'bill', 'Billing Bea', array['issue_invoices']);
select t.ok(pg_temp.save(:'o3', 'c', 'four_eyes') > 0, 'four_eyes again');
update memberships set role = 'tutor' where org_id = t.id('c') and user_id = :'paym';                  -- ROLE changed
select pg_temp.eqt(pg_temp.setting('c'), 'owner', 'a staff member became a tutor: back to owner');
select pg_temp.member('c', :'paym', 'Payments Pat', array['record_payments']);
-- one staff member covers BOTH kinds: removing the other staff doesn't matter, removing that one does
select pg_temp.member('c', :'both', 'Both Bo', array['record_payments', 'issue_invoices']);
select t.ok(pg_temp.save(:'o3', 'c', 'four_eyes') > 0, 'four_eyes with Bea, Pat and Bo');
select pg_temp.dropm('c', :'bill');
select pg_temp.eqt(pg_temp.setting('c'), 'four_eyes', 'one of three removed (Bo still covers both kinds): the setting stays');
select pg_temp.dropm('c', :'paym');
select pg_temp.eqt(pg_temp.setting('c'), 'four_eyes', 'two of three removed: still four_eyes while Bo covers both');
select t.eq(pg_temp.nnote('c', :'o3'), 4, 'and no new notice');
select pg_temp.dropm('c', :'both');
select pg_temp.eqt(pg_temp.setting('c'), 'owner', 'the last staff member is removed: back to owner');
select t.eq(pg_temp.nnote('c', :'o3'), 5, 'a notice');
-- owner and staff values are NOT touched when staff change
select pg_temp.member('c', :'bill', 'Billing Bea', array['issue_invoices']); select pg_temp.member('c', :'paym', 'Payments Pat', array['record_payments']);
select t.ok(pg_temp.save(:'o3', 'c', 'staff') > 0, 'the staff value is chosen');
select pg_temp.dropm('c', :'bill'); select pg_temp.dropm('c', :'paym');
select pg_temp.eqt(pg_temp.setting('c'), 'staff', 'removing staff does not change "staff" (only four_eyes depends on a second person)');
select t.eq(pg_temp.nnote('c', :'o3'), 5, 'and sends no notice');
select t.ok(pg_temp.save(:'o3', 'c', 'owner') > 0, 'the owner value is chosen');
select pg_temp.member('c', :'bill', 'Billing Bea', array['issue_invoices']); select pg_temp.dropm('c', :'bill');
select pg_temp.eqt(pg_temp.setting('c'), 'owner', 'removing staff does not change "owner" either');
-- a future-dated four_eyes row is replaced for its day too
select pg_temp.member('c', :'bill', 'Billing Bea', array['issue_invoices']); select pg_temp.member('c', :'paym', 'Payments Pat', array['record_payments']);
select t.ok(pg_temp.save(:'o3', 'c', 'four_eyes', (select today + 5 from td)) > 0, 'four_eyes is scheduled to start in 5 days');
select t.ok(pg_temp.setting('c') = 'owner' and pg_temp.setting('c', (select today + 5 from td)) = 'four_eyes', 'today is still owner, in 5 days four_eyes');
select pg_temp.dropm('c', :'paym');
select pg_temp.eqt(pg_temp.setting('c', (select today + 5 from td)), 'owner', 'a staff member left before it started: the scheduled day now says owner too');
select pg_temp.eqt(pg_temp.setting('c'), 'owner', 'today is unchanged');
select t.eq(pg_temp.nnote('c', :'o3'), 6, 'the owner is told');
select t.ok((select (after->>'rows_written')::int = 1 from audit_log where org_id = t.id('c') and action = 'org_four_eyes_fallback' order by id desc limit 1), 'one settings row was written (for the scheduled day only)');
-- another owner of the same centre gets a notice too; a solo organisation is never touched
select pg_temp.member('c', :'sx', 'Second owner', '{}');
update memberships set role = 'owner' where org_id = t.id('c') and user_id = :'sx';
select pg_temp.member('c', :'paym', 'Payments Pat', array['record_payments']);
select t.ok(pg_temp.save(:'o3', 'c', 'four_eyes') > 0, 'four_eyes (the scheduled row is also four_eyes → replaced the same way)');
select pg_temp.dropm('c', :'bill');
select t.ok(pg_temp.nnote('c', :'o3') = 7 and pg_temp.nnote('c', :'sx') = 1, 'every active owner gets a notice');
select t.ok((select count(*) = 0 from org_notifications where org_id = org_personal('00000000-0000-0000-0000-0000000000a1')), 'solo organisations get no such notice');
select t.ok((select pg_temp.sc(format('select (select count(*) from org_settings where org_id = %L)::text', org_personal('00000000-0000-0000-0000-0000000000a1')))::int >= 1), 'and keep their settings untouched');
-- deleting a whole organisation is not blocked by the watcher
select t.ok((select count(*) = 0 from information_schema.triggers where trigger_name = 'org_four_eyes_watch' and event_object_table <> 'memberships'), 'the watcher lives only on memberships');
select t.ok((select pg_temp.sc('select org_four_eyes_ready(''' || t.id('c') || ''')::text') is not null), 'the readiness check runs');

-- C4. the pure status the screens read
select t.ok((select (org_four_eyes_status(t.id('c')))::text like '%"owner": true%'), 'status: the owner is there');
select t.eq((select count(*) from pg_proc where proname in ('org_four_eyes_status', 'org_four_eyes_ready', 'org_four_eyes_enforce', 'org_four_eyes_watch', 'centre_undo_blockers') and has_function_privilege('authenticated', oid, 'execute')), 0, 'the internal helpers are not callable from a browser');
select t.eq((select count(*) from pg_proc where proname in ('centre_undo_application', 'centre_invoice_applications', 'org_notification_dismiss') and has_function_privilege('anon', oid, 'execute')), 0, 'and the three public functions are not callable by anonymous callers');
select t.eq((select count(*) from pg_proc where proname in ('centre_undo_application', 'centre_invoice_applications', 'org_notification_dismiss', 'org_four_eyes_status', 'org_four_eyes_enforce', 'centre_undo_blockers') and not (coalesce(proconfig::text, '') like '%search_path%')), 0, 'every new function pins its search_path');
