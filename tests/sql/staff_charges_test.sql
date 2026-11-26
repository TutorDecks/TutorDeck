-- T3 step 4 tests: staff_pending_charges / staff_set_charge / staff_set_charges / pending_charge_count.
-- Runs after staff_attendance_test.sql in the same throwaway database (reuses the t.* helpers). Builds its own centre and made-up people.
-- Prices below: every lesson is 1 hour, rate 55, amount 123.45 (so the cap is 12345 cents), except where a test says otherwise.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000b801', 'sc.owner@centre.test'),  ('00000000-0000-0000-0000-00000000b802', 'sc.billing@centre.test'),
  ('00000000-0000-0000-0000-00000000b803', 'sc.timetable@centre.test'), ('00000000-0000-0000-0000-00000000b804', 'sc.tutor@centre.test'),
  ('00000000-0000-0000-0000-00000000b805', 'sc.outsider@centre.test'), ('00000000-0000-0000-0000-00000000b806', 'sc.off@centre.test'),
  ('00000000-0000-0000-0000-00000000b807', 'sc.owner2@centre.test'), ('00000000-0000-0000-0000-00000000b808', 'sc.both@centre.test');
set role authenticated; select t.as('00000000-0000-0000-0000-00000000b801');
select t.put('sc', org_create_centre('Charges Centre', t.centre_settings()));
select t.as('00000000-0000-0000-0000-00000000b807');
select t.put('sc2', org_create_centre('Other Charges Centre', t.centre_settings()));
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('sc'), '00000000-0000-0000-0000-00000000b802', 'Billing Bea',  'staff', array['issue_invoices'], 'active'),
  (t.id('sc'), '00000000-0000-0000-0000-00000000b803', 'Desk Dan',     'staff', array['manage_timetable', 'manage_students'], 'active'),
  (t.id('sc'), '00000000-0000-0000-0000-00000000b804', 'Tutor Tia',    'tutor', '{}', 'active'),
  (t.id('sc'), '00000000-0000-0000-0000-00000000b806', 'Switched off', 'staff', array['issue_invoices'], 'disabled'),
  (t.id('sc'), '00000000-0000-0000-0000-00000000b808', 'Both Bo',      'staff', array['issue_invoices', 'manage_timetable'], 'active');
select t.put('mt', (select id from memberships where org_id = t.id('sc') and user_id = '00000000-0000-0000-0000-00000000b804'));

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today;
grant select on td to authenticated, anon;
create temp table stu (k text primary key, id uuid);
insert into stu select 's' || g, gen_random_uuid() from generate_series(1, 12) g;
grant select on stu to authenticated;
insert into students(id, tutor_id, org_id, name, level, contact)
  select id, '00000000-0000-0000-0000-00000000b801', t.id('sc'), 'Kid ' || k, 'P' || (g % 6 + 1), '9200000' || g
    from (select *, row_number() over (order by k) g from stu) x;
-- a lesson that is ALREADY marked (as a person would have marked it), so tests can start from a pending charge. Marked in the past, as the owner.
create function pg_temp.mk(p_k text, p_off int, p_att text, p_by uuid default null, p_amount numeric default 123.45, p_rate numeric default 55) returns uuid language plpgsql as $$
declare lid uuid;
begin
  insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, taught_by, subject)
  select '00000000-0000-0000-0000-00000000b801', t.id('sc'), stu.id, (select today from td) + p_off, '16:00', '17:00', p_rate, p_amount, 'scheduled', p_by, 'Math'
  from stu where stu.k = p_k returning id into lid;
  if p_att is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-00000000b801', 'role', 'authenticated')::text, false);
    update lessons set attendance = p_att where id = lid;
    perform set_config('request.jwt.claims', '', false);
  end if;
  return lid;
end $$;
create function pg_temp.refused(p_user text, p_sql text, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  begin execute p_sql; exception when others then m := sqlerrm; end;
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;

-- the queue: three kinds of absent / cancelled lesson, one attended, one not marked, one cancelled by staff with no mark
select t.put('P1', pg_temp.mk('s1', -1, 'absent', t.id('mt')));           -- yesterday
select t.put('P2', pg_temp.mk('s2', -2, 'late_cancelled', t.id('mt')));   -- two days ago
select t.put('P3', pg_temp.mk('s3', -3, 'cancelled_early', t.id('mt')));  -- three days ago
select t.put('PA', pg_temp.mk('s4', -1, 'attended', t.id('mt')));
select t.put('PU', pg_temp.mk('s5', -1, null, t.id('mt')));
select t.put('PX', pg_temp.mk('s6', 0, null, t.id('mt')));
update lessons set status = 'cancelled' where id = t.id('PX');                -- cancelled by staff, no attendance mark: not a charge
select t.eq((select count(*) from lessons where org_id = t.id('sc') and compensation is null and attendance in ('absent', 'late_cancelled', 'cancelled_early')), 3, 'setup: three lessons wait for a charge');

-- ===================================================================== who may call
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', format('set role authenticated; select staff_pending_charges(%L)', t.id('sc2')), 'NOT_FOUND', 'staff of another centre can''t read this centre''s queue'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b805', format('set role authenticated; select staff_pending_charges(%L)', t.id('sc')), 'NOT_FOUND', 'a stranger'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b804', format('set role authenticated; select staff_pending_charges(%L)', t.id('sc')), 'NOT_FOUND', 'a tutor of the centre has no access'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b804', format('set role authenticated; select staff_set_charge(%L, 0)', t.id('P1')), 'NOT_FOUND', 'a tutor can''t set a charge through the staff function'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b806', format('set role authenticated; select staff_pending_charges(%L)', t.id('sc')), 'NOT_FOUND', 'switched-off staff'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b803', format('set role authenticated; select staff_pending_charges(%L)', t.id('sc')), 'NOT_ALLOWED', 'staff with the timetable permission but NOT issue_invoices can''t see charges'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b803', format('set role authenticated; select staff_set_charge(%L, 0)', t.id('P1')), 'NOT_ALLOWED', 'nor set one'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b803', format('set role authenticated; select staff_set_charges(array[%L]::uuid[], ''amount'', 0)', t.id('P1')), 'NOT_ALLOWED', 'nor set many'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b803', format('set role authenticated; select pending_charge_count(%L)', t.id('sc')), 'NOT_ALLOWED', 'nor count them'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b801', 'select staff_set_charge(''00000000-0000-0000-0000-000000000bad'', 0)', 'NOT_FOUND', 'a made-up lesson id (same words as "not yours")');
select pg_temp.refused('00000000-0000-0000-0000-00000000b801', 'set role anon; select staff_pending_charges(''00000000-0000-0000-0000-000000000bad'')', 'permission denied', 'anonymous callers can''t even reach the function'); reset role;
select org_personal('00000000-0000-0000-0000-00000000b805') as solo \gset
select pg_temp.refused('00000000-0000-0000-0000-00000000b805', format('set role authenticated; select staff_pending_charges(%L)', :'solo'), 'NOT_FOUND', 'a solo organisation has no charge queue'); reset role;
select t.ok(not has_function_privilege('authenticated', 'staff_charges_gate(uuid)', 'execute') and not has_function_privilege('authenticated', 'lesson_price_cents(numeric,numeric,time,time)', 'execute')
        and not has_function_privilege('authenticated', 'charge_suggestion_cents(text,text,bigint)', 'execute'), 'the three helpers can''t be called from a browser');

-- ===================================================================== the queue
select t.as('00000000-0000-0000-0000-00000000b802'); set role authenticated;
select staff_pending_charges(t.id('sc')) as q \gset
select pending_charge_count(t.id('sc')) as cnt \gset
reset role;
select t.eq((:'q'::jsonb->>'total')::int, 3, 'the queue holds the three absent / cancelled lessons with no charge');
select t.eq(:'cnt'::int, 3, 'pending_charge_count agrees');
select t.ok(not exists (select 1 from jsonb_array_elements(:'q'::jsonb->'rows') e where e->>'lesson_id' in (t.id('PA')::text, t.id('PU')::text, t.id('PX')::text)),
            'attended, not marked and closed-by-staff lessons are NOT in the queue');
select t.ok((select array_agg(e->>'lesson_id' order by ord) = array[t.id('P1')::text, t.id('P2')::text, t.id('P3')::text]
               from jsonb_array_elements(:'q'::jsonb->'rows') with ordinality x(e, ord)), 'newest lesson first');
select t.ok((select (e->>'price_cents')::bigint = 12345 and e->>'student_name' = 'Kid s1' and e->>'tutor_name' = 'Tutor Tia' and e->>'attendance' = 'absent'
                    and e->>'marked_by_name' is not null
               from jsonb_array_elements(:'q'::jsonb->'rows') e where e->>'lesson_id' = t.id('P1')::text), 'a row names the student, the tutor, the mark, the marker and the price in cents');
-- the staff_home number is the same number
select t.as('00000000-0000-0000-0000-00000000b802'); set role authenticated;
select (staff_home(t.id('sc'))->>'pending_charges')::int as hp \gset
reset role;
select t.eq(:'hp'::int, 3, 'the Home "charges to confirm" count equals the queue');
select t.as('00000000-0000-0000-0000-00000000b802'); set role authenticated;
select t.fails(format($q$ select staff_pending_charges(%L, 0) $q$, t.id('sc')), 'page 0');
select t.fails(format($q$ select staff_pending_charges(%L, 1, 101) $q$, t.id('sc')), 'page size 101');
select staff_pending_charges(t.id('sc'), 2, 2) as q2 \gset
reset role;
select t.ok(jsonb_array_length(:'q2'::jsonb->'rows') = 1 and (:'q2'::jsonb->>'total')::int = 3, 'paging: page 2 of size 2 has the third row');

-- ===================================================================== the suggestion follows billing.absences.mode (money rule: read as of the lesson's day)
create function pg_temp.mode(p_mode text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-00000000b801', 'role', 'authenticated')::text, false);
  perform org_save_settings(t.id('sc'), jsonb_set(t.centre_settings(), '{billing,absences}', jsonb_build_object('mode', p_mode, 'notice_hours', 24)), current_date);
  perform set_config('request.jwt.claims', '', false);
end $$;
create function pg_temp.sugg(p_lesson text) returns text language plpgsql as $$
declare q jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-00000000b802', 'role', 'authenticated')::text, false);
  set local role authenticated;
  q := staff_pending_charges(t.id('sc'));
  reset role; perform set_config('request.jwt.claims', '', false);
  return (select coalesce(e->>'suggested_cents', 'null') from jsonb_array_elements(q->'rows') e where e->>'lesson_id' = t.id(p_lesson)::text);
end $$;
grant execute on function pg_temp.mode(text), pg_temp.sugg(text) to authenticated;
select pg_temp.mode('charged');
select t.ok(pg_temp.sugg('P1') = '12345' and pg_temp.sugg('P2') = '12345' and pg_temp.sugg('P3') = '12345', 'absences = charged: the full price is suggested for all three');
select pg_temp.mode('not_charged');
select t.ok(pg_temp.sugg('P1') = '0' and pg_temp.sugg('P2') = '0' and pg_temp.sugg('P3') = '0', 'absences = not_charged: 0 is suggested for all three');
select pg_temp.mode('charged_unless_notice');
select t.ok(pg_temp.sugg('P1') = '12345' and pg_temp.sugg('P2') = '12345' and pg_temp.sugg('P3') = '0', 'absences = charged_unless_notice: full price for absent and late cancelled, 0 for cancelled in time');
-- as of the lesson's own day: an older settings version (inserted directly, as a past change would have been) decides an older lesson
select t.put('PO', pg_temp.mk('s8', -30, 'absent', t.id('mt')));
select t.put('PO2', pg_temp.mk('s9', -45, 'absent', t.id('mt')));            -- before any version existed: today's rule applies
insert into org_settings(org_id, version, schema_version, effective_from, settings, created_by)
  values (t.id('sc'), 90, 1, (select today - 40 from td), jsonb_set(t.centre_settings(), '{billing,absences}', '{"mode":"not_charged","notice_hours":24}'), '00000000-0000-0000-0000-00000000b801');
-- a later version (5 days ago, same as the mode now in force) so that yesterday's lesson is governed by it, not by the 40-day-old one
insert into org_settings(org_id, version, schema_version, effective_from, settings, created_by)
  values (t.id('sc'), 91, 1, (select today - 5 from td), jsonb_set(t.centre_settings(), '{billing,absences}', '{"mode":"charged_unless_notice","notice_hours":24}'), '00000000-0000-0000-0000-00000000b801');
select t.ok(pg_temp.sugg('PO') = '0' and pg_temp.sugg('P1') = '12345', 'the rule in force on the lesson''s own day decides: a 30-day-old lesson follows the older "not charged" version, yesterday''s follows today''s rule');
select t.ok(pg_temp.sugg('PO2') = '12345', 'a lesson older than every settings version falls back to today''s rule');
select t.ok((select compensation is null from lessons where id in (t.id('P1'), t.id('P2'), t.id('P3')) group by 1), 'a suggestion is only a suggestion: nothing was saved by showing it');
select t.eq((select count(*) from lessons where id in (t.id('P1'), t.id('P2'), t.id('P3')) and compensation is not null), 0, 'still three pending');

-- ===================================================================== one charge: the Sophie case (type 0, it leaves the queue)
select t.as('00000000-0000-0000-0000-00000000b802'); set role authenticated;
select staff_set_charge(t.id('P1'), 0) as r1 \gset
select pending_charge_count(t.id('sc')) as cnt2 \gset
reset role;
select t.ok((select compensation = 0 and compensation_cents = 0 and status = 'cancelled' from lessons where id = t.id('P1')), 'typing 0 saves "not charged" (a number, not null) and keeps the lesson cancelled');
select t.eq(:'cnt2'::int, 4, 'and it leaves the queue (five waiting before, four after)');
select t.ok((select (:'r1'::jsonb->>'compensation_cents')::int = 0 and (:'r1'::jsonb->>'price_cents')::int = 12345), 'the answer repeats the amount and the price in cents');
select t.ok((select a.actor = '00000000-0000-0000-0000-00000000b802' and a.at is not null and a.before->>'compensation_cents' is null and (a.after->>'compensation_cents')::int = 0 and a.org_id = t.id('sc')
               from audit_log a where a.action = 'staff_set_charge' and a.row_id = t.id('P1')::text), 'a named audit entry: who, when, before (nothing) and after (0)');
select t.as('00000000-0000-0000-0000-00000000b802'); set role authenticated;
select staff_set_charge(t.id('P2'), 6050);
reset role;
select t.ok((select compensation = 60.50 and compensation_cents = 6050 from lessons where id = t.id('P2')), 'S$60.50 is stored as 60.50 dollars and 6050 cents, exactly');
-- validation 0 .. price
select t.as('00000000-0000-0000-0000-00000000b802'); set role authenticated;
select t.fails(format($q$ select staff_set_charge(%L, -1) $q$, t.id('P3')), 'a negative charge');
select t.fails(format($q$ select staff_set_charge(%L, 12346) $q$, t.id('P3')), 'one cent more than the lesson''s price');
select t.fails(format($q$ select staff_set_charge(%L, null) $q$, t.id('P3')), 'no amount at all');
reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', format('set role authenticated; select staff_set_charge(%L, 12346)', t.id('P3')), 'BAD_CHARGE', 'the refusal says what to do'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', format('set role authenticated; select staff_set_charge(%L, 5)', t.id('PA')), 'NOT_CANCELLED', 'an attended lesson has no charge'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', format('set role authenticated; select staff_set_charge(%L, 5)', t.id('PU')), 'NOT_CANCELLED', 'an unmarked lesson has no charge'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', format('set role authenticated; select staff_set_charge(%L, 5)', t.id('PX')), 'NOT_CANCELLED', 'a lesson cancelled by staff with no mark has no charge'); reset role;
select t.as('00000000-0000-0000-0000-00000000b802'); set role authenticated;
select staff_set_charge(t.id('P3'), 12345);                                                 -- exactly the price is fine
reset role;
select t.ok((select compensation = 123.45 from lessons where id = t.id('P3')), 'a charge of exactly the lesson''s price is accepted');

-- changing a charge that already has a number: needs a reason, writes before AND after
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', format('set role authenticated; select staff_set_charge(%L, 1000)', t.id('P2')), 'REASON_REQUIRED', 'changing an existing charge needs a reason'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', format('set role authenticated; select staff_set_charge(%L, 6050, ''same'')', t.id('P2')), 'NO_CHANGE', 'typing the same number again is a no-op, not an audit entry'); reset role;
select t.as('00000000-0000-0000-0000-00000000b802'); set role authenticated;
select staff_set_charge(t.id('P2'), 1000, 'Parent sent a doctor''s note');
reset role;
select t.ok((select compensation_cents = 1000 from lessons where id = t.id('P2')), 'the charge changed');
select t.ok((select (a.before->>'compensation_cents')::int = 6050 and (a.after->>'compensation_cents')::int = 1000 and a.after->>'reason' = 'Parent sent a doctor''s note'
               from audit_log a where a.action = 'staff_set_charge' and a.row_id = t.id('P2')::text order by a.id desc limit 1), 'the audit entry has the old amount, the new amount and the reason');
select t.eq((select count(*) from audit_log where action = 'staff_set_charge' and row_id = t.id('P2')::text), 2, 'exactly two staff_set_charge entries for that lesson');
-- a paid lesson is locked
update lessons set paid = true where id = t.id('P2');
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', format('set role authenticated; select staff_set_charge(%L, 500, ''x'')', t.id('P2')), 'ALREADY_PAID', 'a paid lesson''s charge is locked'); reset role;
update lessons set paid = false where id = t.id('P2');

-- a lesson with no stored price falls back to rate x hours (55 x 1 = 5500)
select t.put('PR', pg_temp.mk('s7', -4, 'absent', t.id('mt'), 0, 55));
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', format('set role authenticated; select staff_set_charge(%L, 5501)', t.id('PR')), 'BAD_CHARGE', 'no stored price: the cap is rate x hours (S$55.00)'); reset role;
select t.as('00000000-0000-0000-0000-00000000b802'); set role authenticated;
select staff_set_charge(t.id('PR'), 5500);
reset role;
select t.ok((select compensation_cents = 5500 from lessons where id = t.id('PR')), 'and the cap itself is accepted');

-- ===================================================================== both values of compensation_entered_by
create function pg_temp.comp_by(p_v text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-00000000b801', 'role', 'authenticated')::text, false);
  perform org_save_settings(t.id('sc'), jsonb_set(t.centre_settings(), '{lessons}', jsonb_build_object('compensation_entered_by', p_v)), current_date);
  perform set_config('request.jwt.claims', '', false);
end $$;
-- the tutor's own mark function, as the tutor
create function pg_temp.tutor_marks(p_lesson uuid, p_att text, p_comp numeric) returns text language plpgsql as $$
declare m text := 'ok';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-00000000b804', 'role', 'authenticated')::text, false);
  set local role authenticated;
  begin perform tutor_mark_attendance(p_lesson, p_att, null, null, null, null, p_comp); exception when others then m := sqlerrm; end;
  reset role; perform set_config('request.jwt.claims', '', false);
  return m;
end $$;
grant execute on function pg_temp.comp_by(text), pg_temp.tutor_marks(uuid, text, numeric) to authenticated;

-- (a) admin: the tutor can't type it, so the lesson waits in the queue
select pg_temp.comp_by('admin');
select t.put('TA', pg_temp.mk('s8', 0, null, t.id('mt')));
select t.ok(pg_temp.tutor_marks(t.id('TA'), 'absent', 10) like 'CHARGE_ADMIN_ONLY%', 'admin: a tutor who tries to type a charge is refused');
select t.ok(pg_temp.tutor_marks(t.id('TA'), 'absent', null) = 'ok', 'admin: the tutor marks absent with no number');
select t.ok((select compensation is null from lessons where id = t.id('TA')), 'admin: the lesson is saved with the charge pending');
select t.as('00000000-0000-0000-0000-00000000b802'); set role authenticated;
select staff_pending_charges(t.id('sc')) as qa \gset
reset role;
select t.ok(exists (select 1 from jsonb_array_elements(:'qa'::jsonb->'rows') e where e->>'lesson_id' = t.id('TA')::text), 'admin: the tutor-marked lesson is in the queue');
select t.as('00000000-0000-0000-0000-00000000b802'); set role authenticated;
select staff_set_charge(t.id('TA'), 0);
reset role;
select t.ok((select compensation = 0 from lessons where id = t.id('TA')), 'admin: staff then type 0 and it is settled');

-- (b) tutor: the tutor types it when marking, so it never enters the queue
select pg_temp.comp_by('tutor');
select t.put('TB1', pg_temp.mk('s9', 0, null, t.id('mt'))); select t.put('TB2', pg_temp.mk('s10', 0, null, t.id('mt')));
select t.ok(pg_temp.tutor_marks(t.id('TB1'), 'absent', null) like 'CHARGE_REQUIRED%', 'tutor: marking absent without a charge is refused');
select t.ok((select attendance is null from lessons where id = t.id('TB1')), 'tutor: the refused lesson stays unmarked (so it is not in the queue either)');
select t.ok(pg_temp.tutor_marks(t.id('TB1'), 'absent', 0) = 'ok', 'tutor: marking absent with 0 works');
select t.ok(pg_temp.tutor_marks(t.id('TB2'), 'absent', 40) = 'ok', 'tutor: marking absent with S$40 works');
select t.ok((select compensation = 0 from lessons where id = t.id('TB1')) and (select compensation_cents = 4000 from lessons where id = t.id('TB2')), 'tutor: both charges were saved at marking');
select t.as('00000000-0000-0000-0000-00000000b802'); set role authenticated;
select staff_pending_charges(t.id('sc')) as qb \gset
reset role;
select t.ok(not exists (select 1 from jsonb_array_elements(:'qb'::jsonb->'rows') e where e->>'lesson_id' in (t.id('TB1')::text, t.id('TB2')::text)), 'tutor: neither lesson ever enters the queue');
-- staff can still override what the tutor typed (a reason is needed), whatever the setting
select t.as('00000000-0000-0000-0000-00000000b802'); set role authenticated;
select t.fails(format($q$ select staff_set_charge(%L, 100) $q$, t.id('TB2')), 'tutor-typed charge: a change without a reason');
select staff_set_charge(t.id('TB2'), 2500, 'Centre waived part of it');
reset role;
select t.ok((select compensation_cents = 2500 from lessons where id = t.id('TB2')), 'tutor: staff can override a tutor-typed charge with a reason');
-- (c) with the tutor setting, a lesson STAFF mark absent still waits in the queue (staff are never forced to type it while marking)
select t.put('TC', pg_temp.mk('s11', 0, null, t.id('mt')));
select t.as('00000000-0000-0000-0000-00000000b803'); set role authenticated;
select staff_mark_attendance(t.id('TC'), 'absent');
reset role;
select t.as('00000000-0000-0000-0000-00000000b802'); set role authenticated;
select staff_pending_charges(t.id('sc')) as qc \gset
reset role;
select t.ok(exists (select 1 from jsonb_array_elements(:'qc'::jsonb->'rows') e where e->>'lesson_id' = t.id('TC')::text), 'tutor setting: a lesson marked by STAFF waits in the queue (the tutor never typed it)');
select pg_temp.comp_by('admin');

-- ===================================================================== bulk
select t.put('B1', pg_temp.mk('s1', -5, 'absent', t.id('mt'))); select t.put('B2', pg_temp.mk('s2', -6, 'late_cancelled', t.id('mt')));
select t.put('B3', pg_temp.mk('s3', -7, 'cancelled_early', t.id('mt'), 80.00)); select t.put('B4', pg_temp.mk('s4', -8, 'absent', t.id('mt')));
select t.put('B5', pg_temp.mk('s5', -9, 'absent', t.id('mt')));
select t.as('00000000-0000-0000-0000-00000000b802'); set role authenticated;
select staff_set_charges(array[t.id('B1'), t.id('B2')], 'amount', 0) as rb1 \gset
reset role;
select t.ok((select (:'rb1'::jsonb->>'updated')::int = 2 and (:'rb1'::jsonb->>'total_cents')::int = 0), 'bulk "Not charged": two lessons set to 0');
select t.ok((select count(*) = 2 and bool_and(compensation = 0 and compensation_cents = 0 and status = 'cancelled') from lessons where id in (t.id('B1'), t.id('B2'))), 'both are 0, not null');
select t.eq((select count(*) from audit_log where action = 'staff_set_charge' and row_id in (t.id('B1')::text, t.id('B2')::text) and (after->>'bulk')::int = 2), 2, 'one audit entry per lesson, noting it was a bulk change of 2');
select t.as('00000000-0000-0000-0000-00000000b802'); set role authenticated;
select staff_set_charges(array[t.id('B3'), t.id('B4')], 'full') as rb2 \gset
reset role;
select t.ok((select compensation_cents = 8000 from lessons where id = t.id('B3')) and (select compensation_cents = 12345 from lessons where id = t.id('B4')), 'bulk "Charge full price": each lesson gets ITS OWN price (S$80.00 and S$123.45)');
select t.eq((:'rb2'::jsonb->>'total_cents')::numeric, 20345, 'and the total is returned in cents');
-- all or nothing
select t.put('B6', pg_temp.mk('s6', -10, 'absent', t.id('mt'))); select t.put('B7', pg_temp.mk('s7', -11, 'absent', t.id('mt'), 50.00));
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', format('set role authenticated; select staff_set_charges(array[%L, %L]::uuid[], ''amount'', 6000)', t.id('B6'), t.id('B7')), 'BAD_CHARGE', 'one amount above ONE lesson''s price refuses the whole batch'); reset role;
select t.ok((select count(*) = 0 from lessons where id in (t.id('B6'), t.id('B7')) and compensation is not null), 'and nothing was saved');
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', format('set role authenticated; select staff_set_charges(array[%L, %L]::uuid[], ''full'')', t.id('B6'), t.id('B1')), 'ALREADY_SET', 'a lesson that already has a charge refuses the batch'); reset role;
select t.ok((select compensation is null from lessons where id = t.id('B6')), 'and the other lesson in it was not touched either');
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', format('set role authenticated; select staff_set_charges(array[%L, %L]::uuid[], ''full'')', t.id('B6'), t.id('PA')), 'NOT_CANCELLED', 'an attended lesson in the batch refuses it'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', 'set role authenticated; select staff_set_charges(''{}''::uuid[], ''full'')', 'BAD_VALUE', 'an empty batch'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', format('set role authenticated; select staff_set_charges(array[%L]::uuid[], ''half'')', t.id('B6')), 'BAD_VALUE', 'an unknown mode'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', format('set role authenticated; select staff_set_charges(array[%L]::uuid[], ''amount'', -5)', t.id('B6')), 'BAD_CHARGE', 'a negative bulk amount'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', format('set role authenticated; select staff_set_charges(array[%L]::uuid[], ''amount'')', t.id('B6')), 'BAD_CHARGE', 'amount mode without an amount'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', format('set role authenticated; select staff_set_charges(array[%L, ''00000000-0000-0000-0000-000000000bad'']::uuid[], ''full'')', t.id('B6')), 'NOT_FOUND', 'one unknown id refuses the batch with the same NOT_FOUND'); reset role;
-- a batch mixing two centres' lessons is NOT_FOUND (a person can't reach into the other centre by smuggling an id)
select set_config('request.jwt.claims', '', false);
insert into students(id, tutor_id, org_id, name) values ('00000000-0000-0000-0000-00000000b8f1', '00000000-0000-0000-0000-00000000b807', t.id('sc2'), 'Other Kid');
insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, attendance, status)
  values ('00000000-0000-0000-0000-00000000b8f2', '00000000-0000-0000-0000-00000000b807', t.id('sc2'), '00000000-0000-0000-0000-00000000b8f1', current_date - 5, '10:00', '11:00', 50, 50, null, 'scheduled');
update lessons set attendance = 'absent', status = 'cancelled' where id = '00000000-0000-0000-0000-00000000b8f2';   -- server-side set-up, no signed-in user
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', format('set role authenticated; select staff_set_charges(array[%L, ''00000000-0000-0000-0000-00000000b8f2'']::uuid[], ''full'')', t.id('B6')), 'NOT_FOUND', 'a batch that includes another centre''s lesson'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', 'set role authenticated; select staff_set_charge(''00000000-0000-0000-0000-00000000b8f2'', 0)', 'NOT_FOUND', 'one charge on another centre''s lesson'); reset role;
select t.ok((select compensation is null from lessons where id = '00000000-0000-0000-0000-00000000b8f2'), 'the other centre''s lesson is untouched');
select pg_temp.refused('00000000-0000-0000-0000-00000000b802', 'set role authenticated; select staff_set_charges((select array_agg(gen_random_uuid()) from generate_series(1, 101)), ''full'')', 'TOO_MANY', 'more than 100 lessons in one go'); reset role;
-- the two owners / "both" staff
select t.as('00000000-0000-0000-0000-00000000b801'); set role authenticated;
select staff_set_charge(t.id('B6'), 100);
reset role;
select t.ok((select compensation_cents = 100 from lessons where id = t.id('B6')), 'the owner can set charges (owners always hold every permission)');
select t.as('00000000-0000-0000-0000-00000000b808'); set role authenticated;
select staff_set_charge(t.id('B7'), 0);
select staff_pending_charges(t.id('sc')) as qd \gset
reset role;
select t.ok((select compensation = 0 from lessons where id = t.id('B7')), 'staff with both permissions can set a charge');
select t.ok(jsonb_typeof(:'qd'::jsonb->'rows') = 'array', 'and read the queue');

-- ===================================================================== what the queue and the functions never do
select t.as('00000000-0000-0000-0000-00000000b802'); set role authenticated;
select staff_pending_charges(t.id('sc')) as qe \gset
reset role;
select t.ok(not exists (select 1 from jsonb_array_elements(:'qe'::jsonb->'rows') e, jsonb_object_keys(e) k where k in ('rate', 'amount', 'paid', 'compensation', 'charge_note', 'total', 'invoice_id')),
            'the queue returns explicit columns only (price_cents / suggested_cents, never the raw money columns)');
select t.eq((select count(*) from invoices where org_id = t.id('sc')), 0, 'nothing in this step creates an invoice');
-- tutors still have no table access and the tutor view still shows no money
select t.as('00000000-0000-0000-0000-00000000b804'); set role authenticated;
select t.eq((select count(*) from lessons), 0, 'a tutor still can''t read the lessons table');
select t.eq(t.rows($q$ update lessons set compensation = 0 $q$), 0, 'a tutor still can''t write a charge directly');
reset role;
-- a direct write by staff still works exactly as before (the app's solo pages and old flows are unchanged; this step only ADDED functions)
select t.as('00000000-0000-0000-0000-00000000b801'); set role authenticated;
select t.eq(t.rows(format($q$ update lessons set compensation = 1 where id = %L $q$, t.id('B5')) ), 1, 'the owner can still type a charge the old way (direct write)');
reset role;

-- ===================================================================== solo tutors untouched
select set_config('request.jwt.claims', '', false);
select t.ok((select count(*) from pg_proc where proname in ('staff_pending_charges', 'staff_set_charge', 'staff_set_charges', 'pending_charge_count')) = 4, 'the four callable functions exist');
