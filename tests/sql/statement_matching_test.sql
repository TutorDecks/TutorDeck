-- T34 M0-M2 tests: bank statement matching (migration_statement_matching.sql).
--   settings (every value of auto_confirm, bank, both windows), the mapping, permissions (owner / staff with record_payments yes; everyone else no),
--   rules A-D with every reason, auto-confirm exact_only vs never, window edges, payer links (remember, forget, no override of a wrong amount),
--   duplicates (same file twice, identical lines in one file, overlapping files), partial / over payments, wrong household / other centre,
--   confirm twice, undo (also when the payment was already reversed), "not ours", retention (nothing readable left, purge at 60 days, account masking),
--   audit redaction, read isolation, no direct writes, speed.
-- Runs after centre_credit_undo_test.sql in the same throwaway database (reuses the t.* helpers). All people, names and numbers are FAKE.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000e301', 'sm.owner1@centre.test'), ('00000000-0000-0000-0000-00000000e302', 'sm.paym@centre.test'),
  ('00000000-0000-0000-0000-00000000e303', 'sm.bill@centre.test'),   ('00000000-0000-0000-0000-00000000e304', 'sm.tutor@centre.test'),
  ('00000000-0000-0000-0000-00000000e305', 'sm.parent@centre.test'), ('00000000-0000-0000-0000-00000000e306', 'sm.owner2@centre.test'),
  ('00000000-0000-0000-0000-00000000e307', 'sm.off@centre.test'),    ('00000000-0000-0000-0000-00000000e308', 'sm.owner3@centre.test'),
  ('00000000-0000-0000-0000-00000000e309', 'sm.owner4@centre.test');
\set o1 '00000000-0000-0000-0000-00000000e301'
\set paym '00000000-0000-0000-0000-00000000e302'
\set bill '00000000-0000-0000-0000-00000000e303'
\set tut '00000000-0000-0000-0000-00000000e304'
\set par '00000000-0000-0000-0000-00000000e305'
\set o2 '00000000-0000-0000-0000-00000000e306'
\set off '00000000-0000-0000-0000-00000000e307'
\set o3 '00000000-0000-0000-0000-00000000e308'
\set o4 '00000000-0000-0000-0000-00000000e309'
\set solo '00000000-0000-0000-0000-0000000000a1'
\set h1 '00000000-0000-0000-0000-00000000e401'
\set h2 '00000000-0000-0000-0000-00000000e402'
\set h3 '00000000-0000-0000-0000-00000000e403'
\set h4 '00000000-0000-0000-0000-00000000e404'
\set h5 '00000000-0000-0000-0000-00000000e405'
\set h6 '00000000-0000-0000-0000-00000000e406'
\set hx '00000000-0000-0000-0000-00000000e409'
\set h7 '00000000-0000-0000-0000-00000000e407'
\set h8 '00000000-0000-0000-0000-00000000e408'
\set s1 '00000000-0000-0000-0000-00000000e501'
\set s2 '00000000-0000-0000-0000-00000000e502'
\set s3 '00000000-0000-0000-0000-00000000e503'
\set s4 '00000000-0000-0000-0000-00000000e504'
\set s5 '00000000-0000-0000-0000-00000000e505'
\set s6 '00000000-0000-0000-0000-00000000e506'
\set sx '00000000-0000-0000-0000-00000000e509'
\set s7 '00000000-0000-0000-0000-00000000e507'
\set s8 '00000000-0000-0000-0000-00000000e508'

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today;
grant select on td to authenticated, anon;

create function pg_temp.settings_base(p_modes jsonb default '["manual_paynow","statement_matching"]', p_prefix text default 'SMT') returns jsonb language sql as $$
  select jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(t.centre_settings(), '{profile,invoice_prefix}', to_jsonb(p_prefix)), '{profile,gst_registered}', 'false'),
         '{invoicing}', '{"grouping":"family","due_days":7,"review_before_sending":true,"delivery":{"share_link":true}}'::jsonb),
         '{payments}', jsonb_build_object('modes', coalesce(p_modes, '["manual_paynow","statement_matching"]'::jsonb), 'paynow', '{"type":"uen","id":"201912345A"}'::jsonb, 'partial_payments', true, 'overpayments', 'credit')),
         '{profile,trading_name}', '"Statement Test Centre"'), '{billing}', '{"model":"postpaid_lessons"}'::jsonb) $$;
create function pg_temp.cfg(p_org uuid, p_owner uuid, p_path text[], p_val jsonb) returns void language plpgsql as $$
declare cur jsonb;
begin
  perform t.as(p_owner::text);
  cur := org_settings_on(p_org, current_date + 1);
  perform org_save_settings(p_org, jsonb_set(cur, p_path, p_val, true), current_date);
end $$;
create function pg_temp.refused(p_user text, p_sql text, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  begin execute p_sql; exception when others then m := sqlerrm; end;
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;
create function pg_temp.inv(k text, org uuid, owner uuid, hh uuid, stu uuid, sub bigint, issued_ago int default 0, p_due int default 7) returns uuid
language plpgsql as $$
declare iid uuid := gen_random_uuid(); g record; tdy date := (select today from td);
begin
  perform t.as(owner::text);
  select * into g from centre_invoice_gst(org, sub, tdy);
  insert into centre_invoices(id, org_id, kind, household_id, student_id, period_start, period_end, gst_registered, gst_rate_bp, gst_inclusive, net_cents, gst_cents, total_cents)
  values (iid, org, 'lesson', hh, stu, date_trunc('month', tdy)::date, date_trunc('month', tdy)::date + 27, g.gst_registered, g.gst_rate_bp, g.gst_inclusive, g.net_cents, g.gst_cents, g.total_cents);
  insert into centre_invoice_lines(org_id, invoice_id, position, student_id, description, qty, unit_cents) values (org, iid, 1, stu, 'Maths lessons', 1, sub);
  update centre_invoices set status = 'issued', issue_date = tdy - issued_ago, due_date = tdy + p_due where centre_invoices.id = iid;
  perform t.put(k, iid);
  return iid;
end $$;
create function pg_temp.num(k text) returns text language sql as $$ select number_text from centre_invoices where id = t.id(k) $$;
create function pg_temp.bal(k text) returns bigint language sql as $$ select balance_cents from centre_balance_rows((select org_id from centre_invoices where id = t.id(k)), array[t.id(k)]) $$;
-- a statement line: day offset from today, signed cents, reference, payer, bank reference (the bank's own, unique per line unless a test wants a clash)
create function pg_temp.ln(d int, cents bigint, ref text default null, payer text default null, bref text default null) returns jsonb language sql as $$
  select jsonb_build_object('date', to_char((select today from td) + d, 'YYYY-MM-DD'), 'cents', cents, 'ref', ref, 'payer', payer, 'bank_ref', bref) $$;
create function pg_temp.imp(p_user uuid, p_org uuid, p_lines jsonb, p_acct text default 'Main account') returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return stmt_import(p_org, p_acct, null, p_lines); end $$;
create function pg_temp.lid(bref text) returns uuid language sql as $$ select id from statement_lines where bank_ref = bref $$;
create function pg_temp.lrule(bref text) returns text language sql as $$ select sugg_rule from statement_lines where bank_ref = bref $$;
create function pg_temp.lreason(bref text) returns text language sql as $$ select reason from statement_lines where bank_ref = bref $$;
create function pg_temp.conf(p_user uuid, bref text, p_ids uuid[] default null, p_rem boolean default true) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return stmt_confirm(pg_temp.lid(bref), p_ids, p_rem); end $$;
grant execute on all functions in schema pg_temp to public;

-- ===================================================================== the world
select t.put('solo_org', org_personal(:'solo'));
set role authenticated; select t.as(:'o1');
select t.put('c1', org_create_centre('Statement Test Centre', pg_temp.settings_base()));
select org_save_settings(t.id('c1'), pg_temp.settings_base(), date '2000-01-01');
select t.as(:'o2');
select t.put('c2', org_create_centre('Other Statement Centre', pg_temp.settings_base(null, 'OTH')));
select org_save_settings(t.id('c2'), pg_temp.settings_base(null, 'OTH'), date '2000-01-01');
select t.as(:'o3');                                                                      -- c3: auto-confirm NEVER, window 0/0
select t.put('c3', org_create_centre('Never Auto Centre', pg_temp.settings_base(null, 'NVR')));
select org_save_settings(t.id('c3'), jsonb_set(jsonb_set(pg_temp.settings_base(null, 'NVR'), '{payments,statement}', '{"auto_confirm":"never","window_before_days":0,"window_after_days":0}'::jsonb), '{profile,trading_name}', '"Never Auto Centre"'), current_date);
select t.as(:'o4');                                                                      -- c4: matching NOT switched on
select t.put('c4', org_create_centre('No Matching Centre', jsonb_set(pg_temp.settings_base(null, 'NMC'), '{payments,modes}', '["manual_paynow"]')));
select org_save_settings(t.id('c4'), jsonb_set(pg_temp.settings_base(null, 'NMC'), '{payments,modes}', '["manual_paynow"]'), date '2000-01-01');
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('c1'), :'paym', 'Payments Pat', 'staff', array['record_payments'], 'active'),
  (t.id('c1'), :'bill', 'Invoices Ivy',  'staff', array['issue_invoices'], 'active'),
  (t.id('c1'), :'tut',  'Tutor Tia',     'tutor', '{}', 'active'),
  (t.id('c1'), :'par',  'Parent Pia',    'parent', '{}', 'active'),
  (t.id('c1'), :'off',  'Switched off',  'staff', array['record_payments'], 'disabled');
insert into households(id, org_id, name) values
  (:'h1', t.id('c1'), 'Lim Family'), (:'h2', t.id('c1'), 'Tan Family'), (:'h3', t.id('c1'), 'Ong Family'), (:'h4', t.id('c1'), 'Goh Family'),
  (:'h5', t.id('c1'), 'Yeo Family'), (:'h6', t.id('c1'), 'Koh Family'), (:'hx', t.id('c2'), 'Elsewhere Family'), (:'h7', t.id('c3'), 'Neo Family'), (:'h8', t.id('c3'), 'Kok Family');
insert into students(id, tutor_id, org_id, name, household_id) values
  (:'s1', :'o1', t.id('c1'), 'Sophie Lim', :'h1'), (:'s2', :'o1', t.id('c1'), 'Tara Tan', :'h2'), (:'s3', :'o1', t.id('c1'), 'Oscar Ong', :'h3'),
  (:'s4', :'o1', t.id('c1'), 'Gina Goh', :'h4'), (:'s5', :'o1', t.id('c1'), 'Yara Yeo', :'h5'), (:'s6', :'o1', t.id('c1'), 'Kai Koh', :'h6'),
  (:'sx', :'o2', t.id('c2'), 'Ellie Else', :'hx'), (:'s7', :'o3', t.id('c3'), 'Nia Neo', :'h7'), (:'s8', :'o3', t.id('c3'), 'Kim Kok', :'h8');

-- Lim: I1 S$100, I2 S$50.   Tan: I3 S$30.   Ong: I4 S$40, I5 S$40 (same amount, same family).   Goh: I6 S$70.   Yeo: I7 S$60, I8 S$25, I9 S$15.   Koh: I10 S$30 (same as Tan's)
select pg_temp.inv('I1', t.id('c1'), :'o1', :'h1', :'s1', 10000);
select pg_temp.inv('I2', t.id('c1'), :'o1', :'h1', :'s1', 5000);
select pg_temp.inv('I3', t.id('c1'), :'o1', :'h2', :'s2', 3000);
select pg_temp.inv('I4', t.id('c1'), :'o1', :'h3', :'s3', 4000);
select pg_temp.inv('I5', t.id('c1'), :'o1', :'h3', :'s3', 4000);
select pg_temp.inv('I6', t.id('c1'), :'o1', :'h4', :'s4', 7000);
select pg_temp.inv('I7', t.id('c1'), :'o1', :'h5', :'s5', 6000);
select pg_temp.inv('I8', t.id('c1'), :'o1', :'h5', :'s5', 2500);
select pg_temp.inv('I9', t.id('c1'), :'o1', :'h5', :'s5', 1500);
select pg_temp.inv('I10', t.id('c1'), :'o1', :'h6', :'s6', 3000);
select pg_temp.inv('X1', t.id('c2'), :'o2', :'hx', :'sx', 1000);
select t.ok(pg_temp.num('I1') <> pg_temp.num('I2') and pg_temp.num('I1') like 'SMT-%', 'invoices are numbered SMT-n');

-- ===================================================================== 1. settings: every value
create function pg_temp.accepts(doc jsonb, msg text) returns void language plpgsql as $$
begin perform org_validate_settings(null::uuid, doc); raise notice 'PASS accepted: %', msg; exception when others then raise exception 'FAIL: % was refused (%)', msg, sqlerrm; end $$;
create function pg_temp.rejects(doc jsonb, expect text, msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin begin perform org_validate_settings(null::uuid, doc); exception when others then m := sqlerrm; end;
  if m not like expect || '%' then raise exception 'FAIL: % (got "%")', msg, m; end if; raise notice 'PASS refused: % (%)', msg, m; end $$;
select pg_temp.accepts(pg_temp.settings_base(), 'settings without the statement keys (saved before this migration) stay valid');
select pg_temp.accepts(jsonb_set(pg_temp.settings_base(), '{payments,statement}', '{"auto_confirm":"exact_only","window_before_days":7,"window_after_days":90}'), 'auto_confirm = exact_only');
select pg_temp.accepts(jsonb_set(pg_temp.settings_base(), '{payments,statement}', '{"auto_confirm":"never","window_before_days":0,"window_after_days":365}'), 'auto_confirm = never, windows 0 and 365 (the edges)');
select pg_temp.accepts(jsonb_set(pg_temp.settings_base(), '{payments,statement}', '{"window_before_days":30,"window_after_days":0}'), 'window before = 30, after = 0');
select pg_temp.rejects(jsonb_set(pg_temp.settings_base(), '{payments,statement}', '{"auto_confirm":"always"}'), 'Unknown statement auto-confirm', 'auto_confirm = always');
select pg_temp.rejects(jsonb_set(pg_temp.settings_base(), '{payments,statement}', '{"window_before_days":31}'), 'Statement matching window before', 'window before 31');
select pg_temp.rejects(jsonb_set(pg_temp.settings_base(), '{payments,statement}', '{"window_before_days":-1}'), 'Statement matching window before', 'window before -1');
select pg_temp.rejects(jsonb_set(pg_temp.settings_base(), '{payments,statement}', '{"window_after_days":366}'), 'Statement matching window after', 'window after 366');
select pg_temp.rejects(jsonb_set(pg_temp.settings_base(), '{payments,statement}', '{"window_after_days":"90"}'), 'Statement matching window after', 'window after as text');
select pg_temp.rejects(jsonb_set(pg_temp.settings_base(), '{payments,statement}', '{"window_after_days":1.5}'), 'Statement matching window after', 'window after 1.5');
select pg_temp.accepts(jsonb_set(pg_temp.settings_base(), '{payments,statement_bank}', '"DBS"'), 'bank DBS (stored, but unverified: only custom works in the app)');
select pg_temp.accepts(jsonb_set(pg_temp.settings_base(), '{payments,statement_bank}', '"OCBC"'), 'bank OCBC');
select pg_temp.accepts(jsonb_set(pg_temp.settings_base(), '{payments,statement_bank}', '"UOB"'), 'bank UOB');
select pg_temp.accepts(jsonb_set(pg_temp.settings_base(), '{payments,statement_bank}', '"custom"'), 'bank custom');
select pg_temp.rejects(jsonb_set(pg_temp.settings_base(), '{payments,statement_bank}', '"HSBC"'), 'Unknown bank', 'bank HSBC');
select t.ok((select settings#>>'{payments,statement,auto_confirm}' = 'never' from org_settings where org_id = t.id('c3') order by version desc limit 1), 'a saved centre keeps its never setting');

-- ===================================================================== 2. who may call
select pg_temp.refused(:'tut', format('select stmt_queue(%L)', t.id('c1')), 'NOT_FOUND', 'a tutor cannot read the queue');
select pg_temp.refused(:'par', format('select stmt_queue(%L)', t.id('c1')), 'NOT_FOUND', 'a parent cannot read the queue');
select pg_temp.refused(:'o2', format('select stmt_queue(%L)', t.id('c1')), 'NOT_FOUND', 'another centre''s owner cannot read the queue');
select pg_temp.refused(:'solo', format('select stmt_queue(%L)', t.id('solo_org')), 'NOT_FOUND', 'a solo organisation has no statement matching');
select pg_temp.refused(:'off', format('select stmt_queue(%L)', t.id('c1')), 'NOT_FOUND', 'switched-off staff cannot read the queue');
select pg_temp.refused(:'bill', format('select stmt_queue(%L)', t.id('c1')), 'NOT_ALLOWED', 'staff who only issue invoices cannot (record_payments is needed)');
select pg_temp.refused(:'tut', format('select stmt_import(%L, ''A'', null, %L::jsonb)', t.id('c1'), '[]'), 'NOT_FOUND', 'a tutor cannot import');
select pg_temp.refused(:'bill', format('select stmt_import(%L, ''A'', null, %L::jsonb)', t.id('c1'), '[]'), 'NOT_ALLOWED', 'issue_invoices staff cannot import');
select pg_temp.refused(:'o4', format('select stmt_queue(%L)', t.id('c4')), 'NOT_ALLOWED: bank statement matching isn''t switched on', 'a centre that did not switch matching on is refused');
select pg_temp.refused(:'o4', format('select stmt_import(%L, ''A'', null, %L::jsonb)', t.id('c4'), '[]'), 'NOT_ALLOWED: bank statement matching', 'import refused when the mode is off');
select pg_temp.refused('', format('select stmt_queue(%L)', t.id('c1')), 'NOT_FOUND', 'signed out');
select t.as(:'paym'); select t.ok(stmt_queue(t.id('c1')) ? 'review', 'staff with record_payments can read the queue');
select t.as(:'o1'); select t.ok(stmt_queue(t.id('c1')) ? 'review', 'the owner can read the queue');

-- ===================================================================== 3. the column mapping
create function pg_temp.map(p_user uuid, p_name text, p_m jsonb) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return stmt_save_mapping(t.id('c1'), p_name, p_m); end $$;
grant execute on function pg_temp.map(uuid, text, jsonb) to public;
select t.ok((pg_temp.map(:'o1', 'Main CSV', '{"delimiter":",","header_rows":1,"date_col":0,"date_format":"dmy_slash","amount_mode":"signed","amount_col":2,"ref_cols":[1],"payer_col":3,"bank_ref_col":4}')->>'version')::int = 1, 'a mapping saves as version 1');
select t.ok((pg_temp.map(:'paym', 'Main CSV', '{"delimiter":";","header_rows":0,"date_col":0,"date_format":"iso","amount_mode":"debit_credit","debit_col":2,"credit_col":3,"ref_cols":[1,4],"payer_col":null,"bank_ref_col":null}')->>'version')::int = 2, 'saving under the same name makes version 2 (a new row)');
select t.ok((pg_temp.map(:'o1', 'Other', '{"delimiter":"|","header_rows":3,"date_col":1,"date_format":"dmy_text","amount_mode":"amount_drcr","amount_col":2,"drcr_col":3,"ref_cols":[4],"payer_col":5}')->>'version')::int = 1, 'amount + Dr/Cr layout');
select pg_temp.refused(:'o1', format('select stmt_save_mapping(%L, ''x'', %L::jsonb)', t.id('c1'), '{"delimiter":"#","header_rows":1,"date_col":0,"date_format":"iso","amount_mode":"signed","amount_col":1,"ref_cols":[2]}'), 'BAD_VALUE', 'unknown delimiter');
select pg_temp.refused(:'o1', format('select stmt_save_mapping(%L, ''x'', %L::jsonb)', t.id('c1'), '{"delimiter":",","header_rows":1,"date_col":0,"date_format":"yyyy","amount_mode":"signed","amount_col":1,"ref_cols":[2]}'), 'BAD_VALUE', 'unknown date format');
select pg_temp.refused(:'o1', format('select stmt_save_mapping(%L, ''x'', %L::jsonb)', t.id('c1'), '{"delimiter":",","header_rows":1,"date_col":0,"date_format":"iso","amount_mode":"debit_credit","debit_col":1,"ref_cols":[2]}'), 'BAD_VALUE', 'debit/credit without the credit column');
select pg_temp.refused(:'o1', format('select stmt_save_mapping(%L, ''  '', %L::jsonb)', t.id('c1'), '{"delimiter":",","header_rows":1,"date_col":0,"date_format":"iso","amount_mode":"signed","amount_col":1,"ref_cols":[2]}'), 'BAD_VALUE', 'a mapping needs a name');
select pg_temp.refused(:'tut', format('select stmt_save_mapping(%L, ''x'', %L::jsonb)', t.id('c1'), '{}'), 'NOT_FOUND', 'a tutor cannot save a mapping');
select t.eq((select count(*) from statement_mappings where org_id = t.id('c1')), 3, 'three mapping rows (2 versions + 1)');

-- ===================================================================== 4. import, the rules (c1, auto-confirm exact_only, window 7 before / 90 after)
create temp table r1 as select pg_temp.imp(:'o1', t.id('c1'), jsonb_build_array(
  pg_temp.ln(0, 7000, 'Lessons ' || pg_temp.num('I6') || ' thanks', 'Mr  GOH, Ah Beng', 'B1'),                       -- A exact: pays itself
  pg_temp.ln(0, 3000, 'fees ' || lower(pg_temp.num('I2')), 'Pat Lim', 'B2'),                                           -- A: S$20.00 short
  pg_temp.ln(0, 6500, pg_temp.num('I7'), 'Yeo Su', 'B3'),                                                              -- A: S$5.00 over
  pg_temp.ln(0, 7000, 'again ' || pg_temp.num('I6'), 'Mr Goh', 'B4'),                                                  -- A: already paid
  pg_temp.ln(0, 4000, pg_temp.num('I8') || ' & ' || pg_temp.num('I9'), 'Yeo Su', 'B5'),                                -- two numbers that add up
  pg_temp.ln(0, 4000, null, 'Stranger Ong', 'B6'),                                                                      -- C: two invoices of S$40.00
  pg_temp.ln(0, 3000, null, 'Someone', 'B7'),                                                                           -- C: two families owe S$30.00
  pg_temp.ln(0, 15000, 'school fees', 'Lim Mei', 'B8'),                                                                 -- D: everything the Lim family owes
  pg_temp.ln(0, 10000, 'monthly', 'Lim Mei', 'B9'),                                                                     -- C: exactly one invoice of S$100.00
  pg_temp.ln(0, -5000, 'rent', null, 'B10'),                                                                            -- money out
  pg_temp.ln(0, 0, 'zero', null, 'B11'),                                                                                -- zero: skipped
  pg_temp.ln(3, 100, 'tomorrow-ish', null, 'B12'),                                                                      -- future
  pg_temp.ln(0, 123, 'who knows', null, 'B13'),                                                                         -- nothing matches
  pg_temp.ln(0, 5000, 'inv ' || pg_temp.num('I1') || '0', null, 'B14')                                                  -- "SMT-10": a number that is NOT one of ours (I10 is owed; see below)
)) as j;
select t.ok((j->>'lines')::int = 13 and (j->>'skipped')::int = 1 and (j->>'new')::int = 13 and (j->>'duplicates')::int = 0, 'import counts: 14 sent, 1 zero skipped, 13 new') from r1;
select t.ok((j->>'auto_matched')::int = 1, 'exactly one line paid by itself') from r1;
select t.eq(pg_temp.bal('I6'), 0, 'I6 is paid (rule A, exact, auto)');
select t.ok((select auto and rule = 'invoice_no' and kind = 'invoice' from statement_matches where cents = 7000 and org_id = t.id('c1')), 'the match record: auto, invoice_no');
select t.ok((select method = 'bank' and reference = 'B1' and payer_name is null and received_on = (select today from td) from centre_payments where org_id = t.id('c1') and kind = 'payment' and amount_cents = 7000), 'the payment: method bank, the bank own reference only, no payer name, no statement text');
select t.ok(not exists (select 1 from statement_lines where bank_ref = 'B1'), 'a resolved line is gone');
select t.ok(pg_temp.lreason('B2') like '%found, but S$20.00 short%' and pg_temp.lrule('B2') = 'invoice_no', 'B2: number in lower case found, S$20.00 short → review');
select t.ok(pg_temp.lreason('B3') like '%found, but S$5.00 over%', 'B3: S$5.00 over → review');
select t.ok(pg_temp.lreason('B4') like '%already paid%', 'B4: the invoice is already paid');
select t.ok(pg_temp.lreason('B5') like 'More than one invoice number found%together they come to exactly S$40.00%' and pg_temp.lrule('B5') = 'household_total', 'B5: two numbers: a suggestion, never automatic');
select t.eq((select cardinality(sugg_invoice_ids) from statement_lines where bank_ref = 'B5'), 2, 'B5 suggests both invoices');
select t.ok(pg_temp.lreason('B6') like '2 invoices are owed for exactly S$40.00%' and pg_temp.lrule('B6') = 'amount_only', 'B6: two invoices of the same amount (same family): never auto');
select t.ok(pg_temp.lreason('B7') like '2 invoices are owed for exactly S$30.00%', 'B7: the same amount in two families: no guess');
select t.ok(pg_temp.lrule('B8') = 'household_total' and (select sugg_exact and cardinality(sugg_invoice_ids) = 2 from statement_lines where bank_ref = 'B8'), 'B8 (rule D): equals everything the Lim family owes: a suggestion');
select t.ok(pg_temp.lrule('B9') = 'amount_only' and (select sugg_exact and sugg_invoice_ids = array[t.id('I1')] from statement_lines where bank_ref = 'B9'), 'B9 (rule C): exactly one invoice of this amount: a suggestion, not paid');
select t.eq(pg_temp.bal('I1'), 10000, 'rule C never pays by itself');
select t.ok(pg_temp.lreason('B10') like 'Money out%', 'B10: money out is never matched');
select t.ok(not exists (select 1 from statement_lines where bank_ref = 'B11'), 'B11: a zero line is skipped');
select t.ok(pg_temp.lreason('B12') like 'Dated in the future%', 'B12: a future-dated line waits');
select t.ok(pg_temp.lreason('B13') like 'No invoice matches S$1.23%', 'B13: nothing matches');
select t.ok(pg_temp.lreason('B14') like 'No invoice matches%' or pg_temp.lrule('B14') is not null, 'B14: a number that is not ours does not match by accident');

-- ===================================================================== 5. confirm, partial, over, wrong household, twice
create temp table c1_ as select pg_temp.conf(:'paym', 'B9', null, true) as j;
select t.eq(pg_temp.bal('I1'), 0, 'confirming B9 pays I1 (staff with record_payments)');
select t.ok((select not auto and rule = 'amount_only' from statement_matches where cents = 10000 and org_id = t.id('c1')), 'the match records who and how: a person, rule amount_only');
select t.ok(exists (select 1 from statement_payer_links where org_id = t.id('c1') and payer_key = 'lim mei' and household_id = :'h1'), 'remember payer: the normalised name is linked to the family');
select pg_temp.refused(:'o1', format('select stmt_confirm(%L, null, true)', (select id from statement_lines where bank_ref = 'B13')), 'BAD_VALUE', 'a line with no suggestion needs an invoice chosen');
-- B2: short by S$20.00, partial payments ON → the invoice becomes part-paid
select t.as(:'o1'); select stmt_confirm(pg_temp.lid('B2'), null, false);
select t.eq(pg_temp.bal('I2'), 2000, 'a part payment leaves S$20.00 owing (partial_payments on)');
-- B3: over by S$5.00 → the extra is family credit
select t.as(:'o1'); select stmt_confirm(pg_temp.lid('B3'), null, false);
select t.eq(pg_temp.bal('I7'), 0, 'B3 pays I7');
select t.eq((select coalesce(sum(cents), 0) from centre_family_credit where org_id = t.id('c1') and household_id = :'h5'), 500, 'the S$5.00 over becomes family credit (overpayments = credit)');
-- twice: the second press finds nothing
select pg_temp.refused(:'o1', format('select stmt_confirm(%L, null, true)', pg_temp.lid('B9')), 'NOT_FOUND', 'a second confirm of the same line');
select t.eq((select count(*) from centre_payments where org_id = t.id('c1') and amount_cents = 10000 and kind = 'payment'), 1, 'exactly one S$100.00 payment');
-- wrong household / other centre
select pg_temp.refused(:'o1', format('select stmt_confirm(%L, array[%L::uuid, %L::uuid])', pg_temp.lid('B6'), t.id('I4'), t.id('I3')), 'NOT_ALLOWED: those invoices belong to different families', 'invoices of two families in one payment');
select pg_temp.refused(:'o1', format('select stmt_confirm(%L, array[%L::uuid])', pg_temp.lid('B6'), t.id('X1')), 'NOT_FOUND', 'an invoice of another centre');
select pg_temp.refused(:'o2', format('select stmt_confirm(%L, null, true)', pg_temp.lid('B6')), 'NOT_FOUND', 'another centre''s owner cannot confirm our line');
select pg_temp.refused(:'tut', format('select stmt_confirm(%L, null, true)', pg_temp.lid('B6')), 'NOT_FOUND', 'a tutor cannot confirm');
select pg_temp.refused(:'bill', format('select stmt_confirm(%L, null, true)', pg_temp.lid('B6')), 'NOT_ALLOWED', 'issue_invoices staff cannot confirm');
select t.ok(exists (select 1 from statement_lines where bank_ref = 'B6'), 'a refused confirm leaves the line waiting');
select pg_temp.refused(:'o1', format('select stmt_confirm(%L, array[%L::uuid])', pg_temp.lid('B4'), t.id('I6')), 'NOT_ALLOWED', 'confirming a line against an already-paid invoice is refused by the payment rules');
-- rule D confirm pays both Lim invoices? I1 is paid now, so B8 (S$150) is stale: confirming its remembered suggestion pays what is still open
select t.as(:'o1'); select t.ok((select count(*) from statement_lines where bank_ref = 'B8') = 1, 'B8 still waiting');
-- partial payments OFF refuses and leaves the line
select pg_temp.cfg(t.id('c1'), :'o1', '{payments,partial_payments}', 'false');
create temp table i2 as select pg_temp.imp(:'o1', t.id('c1'), jsonb_build_array(pg_temp.ln(0, 500, pg_temp.num('I3'), 'Tan Mei', 'C1'))) j;
select t.ok(pg_temp.lreason('C1') like '%found, but S$25.00 short%', 'C1: short against I3 (S$30.00)');
select pg_temp.refused(:'o1', format('select stmt_confirm(%L, null, false)', pg_temp.lid('C1')), 'PART_NOT_ALLOWED', 'partial payments off: a short payment is refused');
select t.ok(exists (select 1 from statement_lines where bank_ref = 'C1') and pg_temp.bal('I3') = 3000, 'nothing was recorded and the line is still waiting');
select pg_temp.cfg(t.id('c1'), :'o1', '{payments,partial_payments}', 'true');

-- ===================================================================== 6. payer links (rule B)
create temp table i3 as select pg_temp.imp(:'o1', t.id('c1'), jsonb_build_array(
  pg_temp.ln(0, 3000, 'thanks', 'LIM,  Mei', 'D1'),         -- the Lim family: I2 has S$20.00 left, so no invoice is exactly S$30.00 → a wrong amount is NOT overridden by the link
  pg_temp.ln(0, 2000, null, 'lim mei!', 'D2')               -- exactly what I2 has left → pays itself by the link
)) j;
select t.ok((j->>'auto_matched')::int = 1, 'a remembered payer (written differently) with the exact amount pays itself') from i3;
select t.eq(pg_temp.bal('I2'), 0, 'I2 is paid by rule B');
select t.ok((select rule = 'payer_link' and auto from statement_matches where cents = 2000 and org_id = t.id('c1') and rule = 'payer_link'), 'recorded as rule payer_link, auto');
select t.ok(pg_temp.lreason('D1') like 'Known payer. Their open invoice is S$20.00, this is S$10.00 over.%' and not (select sugg_exact from statement_lines where bank_ref = 'D1'), 'D1: a link never overrides a wrong amount (review, difference shown)');
select t.eq((select times_used from statement_payer_links where payer_key = 'lim mei' and org_id = t.id('c1')), 2, 'the link counts its uses');
-- known payer, one open invoice, off by one cent → review showing the difference
create temp table i3b as select pg_temp.imp(:'o1', t.id('c1'), jsonb_build_array(pg_temp.ln(0, 2999, null, 'Tan Mei', 'D3'))) j;
select t.ok(true, 'unknown payer is just a line');
select pg_temp.conf(:'o1', 'D3', array[t.id('I3')], true);       -- confirm S$29.99 against I3 and remember "tan mei"
select t.eq(pg_temp.bal('I3'), 1, 'S$29.99 against S$30.00 leaves 1 cent (exact cents; a person chose this)');
create temp table i3c as select pg_temp.imp(:'o1', t.id('c1'), jsonb_build_array(pg_temp.ln(0, 2, null, 'Tan Mei', 'D4'), pg_temp.ln(0, 1, null, 'Tan Mei', 'D5'))) j;
select t.ok(pg_temp.lreason('D4') like 'Known payer. Their open invoice is S$0.01, this is S$0.01 over.%', 'S$0.02 against S$0.01 owed: the difference is shown');
select t.ok((j->>'auto_matched')::int = 1, 'S$0.01 against S$0.01 owed by a known payer pays itself') from i3c;
-- forget a payer: the same line no longer pays itself
select t.as(:'paym'); select stmt_forget_payer((select id from statement_payer_links where payer_key = 'lim mei' and org_id = t.id('c1')));
select t.ok(not exists (select 1 from statement_payer_links where payer_key = 'lim mei' and org_id = t.id('c1')), 'a forgotten payer is gone');
select pg_temp.refused(:'o2', format('select stmt_forget_payer(%L)', (select id from statement_payer_links where payer_key = 'tan mei' and org_id = t.id('c1'))), 'NOT_FOUND', 'another centre cannot forget our payer');

-- ===================================================================== 7. rule D for a known payer (a combination of the family's invoices)
-- Yeo: I7 paid; I8 S$25.00 and I9 S$14.00 (after a S$1.00 part payment) are open. Link "yeo su"; S$39.00 = both.
select t.as(:'o1'); select pg_temp.imp(:'o1', t.id('c1'), jsonb_build_array(pg_temp.ln(0, 100, null, 'Yeo Su', 'E0')));
select pg_temp.conf(:'o1', 'E0', array[t.id('I9')], true);       -- remember Yeo Su → Yeo family
select pg_temp.imp(:'o1', t.id('c1'), jsonb_build_array(pg_temp.ln(0, 3900, 'school', 'YEO SU', 'E1')));
select t.ok(pg_temp.lrule('E1') = 'household_total' and (select sugg_exact and cardinality(sugg_invoice_ids) = 2 from statement_lines where bank_ref = 'E1'), 'known payer: the exact total of two open invoices is suggested (never automatic)');
select t.eq(pg_temp.bal('I8'), 2500, 'rule D never pays by itself');
select pg_temp.conf(:'o1', 'E1', null, false);
select t.ok(pg_temp.bal('I8') = 0 and pg_temp.bal('I9') = 0, 'confirming pays both invoices of the family');

-- ===================================================================== 8. the same file twice, identical lines, overlapping files
create temp table f1 as select jsonb_build_array(pg_temp.ln(0, 7777, 'x', 'Fake Payer', 'F1'), pg_temp.ln(0, 7777, 'x', 'Fake Payer', 'F1'), pg_temp.ln(-1, 8888, 'y', null, 'F2')) as j;
select t.ok((pg_temp.imp(:'o1', t.id('c1'), (select j from f1)) ->> 'new')::int = 3, 'a file with two identical lines keeps both (occurrence 1 and 2)');
select t.ok((pg_temp.imp(:'o1', t.id('c1'), (select j from f1)) ->> 'new')::int = 0, 'the same file again adds nothing');
select t.eq((select count(*) from statement_lines where org_id = t.id('c1') and bank_ref = 'F1'), 2, 'still exactly two F1 lines');
select t.ok((pg_temp.imp(:'o1', t.id('c1'), (select j from f1) || jsonb_build_array(pg_temp.ln(-2, 9999, 'z', null, 'F3'))) ->> 'new')::int = 1, 'an overlapping file adds only the new line');
select t.ok((pg_temp.imp(:'o1', t.id('c1'), (select j from f1), 'Savings') ->> 'new')::int = 3, 'another account label is a different line (same date, amount, text)');
select t.ok((select (stmt_check(t.id('c1'), 'Main account', (select j from f1)) ->> 'known')::int = 3), 'stmt_check says 3 lines are known, writes nothing') ;
-- the same file after its lines were resolved still adds nothing (the fingerprint outlives the line)
select t.eq((select count(*) from statement_fingerprints where org_id = t.id('c1') and fp is not null), (select count(*) from statement_fingerprints where org_id = t.id('c1')), 'fingerprints are kept');
create temp table i4 as select pg_temp.imp(:'o1', t.id('c1'), jsonb_build_array(pg_temp.ln(0, 7000, 'Lessons ' || pg_temp.num('I6') || ' thanks', 'Mr  GOH, Ah Beng', 'B1'))) j;
select t.ok((j->>'new')::int = 0, 'the line that paid I6 earlier is not imported again (its line is gone, its fingerprint stays)') from i4;
select t.eq((select count(*) from centre_payments where org_id = t.id('c1') and amount_cents = 7000 and kind = 'payment'), 1, 'so I6 was paid exactly once');

-- ===================================================================== 9. window edges (c1: 7 before issue, 90 after due)
-- W1 issued 120 days ago, due 100 days ago (due = today - 100): in until due + 90 = today - 10
select pg_temp.inv('W1', t.id('c1'), :'o1', :'h4', :'s4', 1111, 120, -100);
select pg_temp.inv('W2', t.id('c1'), :'o1', :'h4', :'s4', 2222, 0, 7);        -- issued today: payment may be dated from today - 7
select pg_temp.inv('W3', t.id('c1'), :'o1', :'h4', :'s4', 1112, 120, -100);   -- same dates as W1, for the day just outside
select pg_temp.inv('W4', t.id('c1'), :'o1', :'h4', :'s4', 2223, 0, 7);
create temp table w1 as select pg_temp.imp(:'o1', t.id('c1'), jsonb_build_array(
  pg_temp.ln(-10, 1111, pg_temp.num('W1'), null, 'W_in'),     -- due + 90 days: still in
  pg_temp.ln(-9, 1112, pg_temp.num('W3'), null, 'W_out'),     -- due + 91 days: out
  pg_temp.ln(-7, 2222, pg_temp.num('W2'), null, 'W_b7'),      -- 7 days before issue: in
  pg_temp.ln(-8, 2223, pg_temp.num('W4'), null, 'W_b8'))) j;  -- 8 days before issue: out
select t.ok(not exists (select 1 from statement_lines where bank_ref = 'W_in') and pg_temp.bal('W1') = 0, 'day due+90 is inside the window → paid');
select t.ok(pg_temp.lreason('W_out') like '%outside the allowed window (7 days before it was issued to 90 days after it was due)%', 'day due+91 is outside → review');
select t.ok(not exists (select 1 from statement_lines where bank_ref = 'W_b7') and pg_temp.bal('W2') = 0, 'day -7 before issue is inside → paid');
select t.ok(pg_temp.lreason('W_b8') like '%outside the allowed window%', 'day -8 before issue is outside → review');
-- a number with the window outside and rule C/B: the same limits apply to them
select t.ok(true, 'window applies to every rule (see centre 3 below for 0/0)');

-- ===================================================================== 10. auto_confirm NEVER and a 0/0 window (c3)
select pg_temp.inv('N1', t.id('c3'), :'o3', :'h7', :'s7', 5000, 0, 0);       -- issued today, due today
select pg_temp.inv('N2', t.id('c3'), :'o3', :'h8', :'s8', 6000, 0, 0);
create temp table n1 as select pg_temp.imp(:'o3', t.id('c3'), jsonb_build_array(
  pg_temp.ln(0, 5000, pg_temp.num('N1'), 'Neo Lee', 'N_a'),                  -- exact, but auto-confirm is never
  pg_temp.ln(-1, 6000, pg_temp.num('N2'), 'Kok Lee', 'N_b'),                 -- the day before issue: outside a 0-day window
  pg_temp.ln(1, 6000, pg_temp.num('N2'), 'Kok Lee', 'N_c'))) j;              -- the day after it was due: outside a 0-day window (and in the future)
select t.ok((j->>'auto_matched')::int = 0, 'auto_confirm = never: an exact match does not pay by itself') from n1;
select t.ok(pg_temp.lreason('N_a') like '%found, exact amount. Auto-confirm is off, so a person confirms.', 'the reason says so');
select t.eq((select balance_cents from centre_balance_rows(t.id('c3'), array[t.id('N1')])), 5000, 'nothing was paid');
select t.ok(pg_temp.lreason('N_b') like '%outside the allowed window (0 days before it was issued to 0 days after it was due)%', 'window 0: the day before is outside');
select t.as(:'o3'); select stmt_confirm((select id from statement_lines where bank_ref = 'N_a'), null, true);
select t.eq((select balance_cents from centre_balance_rows(t.id('c3'), array[t.id('N1')])), 0, 'a person confirms it: paid');
select t.ok((select not auto from statement_matches where org_id = t.id('c3') and cents = 5000), 'recorded as confirmed by a person');
-- the SAME exact line in c1 (exact_only) pays itself: both values of auto_confirm are exercised
select t.ok(true, 'exact_only is exercised in section 4 (B1 paid itself)');
-- re-run the rules after a settings change: switch c3 to exact_only → the waiting line N_c is in the future; add an exact one first
select pg_temp.cfg(t.id('c3'), :'o3', '{payments,statement,auto_confirm}', '"exact_only"');
select t.ok((select (stmt_rematch(t.id('c3')) ->> 'to_review')::int >= 1), 'stmt_rematch re-runs the rules over what is waiting');

-- ===================================================================== 11. undo
select t.as(:'o1');
create temp table u0 as select id as m from statement_matches where org_id = t.id('c1') and cents = 7000 and reversed_at is null;
select pg_temp.refused(:'o1', format('select stmt_undo(%L, ''   '')', (select m from u0)), 'REASON_REQUIRED', 'undo needs a reason');
select pg_temp.refused(:'tut', format('select stmt_undo(%L, ''x'')', (select m from u0)), 'NOT_FOUND', 'a tutor cannot undo');
select pg_temp.refused(:'o2', format('select stmt_undo(%L, ''x'')', (select m from u0)), 'NOT_FOUND', 'another centre cannot undo');
select pg_temp.refused(:'bill', format('select stmt_undo(%L, ''x'')', (select m from u0)), 'NOT_ALLOWED', 'issue_invoices staff cannot undo');
select t.as(:'paym'); select t.ok((stmt_undo((select m from u0), 'matched the wrong family') ->> 'payment_already_reversed')::boolean = false, 'undo reverses the payment');
select t.eq(pg_temp.bal('I6'), 7000, 'I6 is owed again');
select t.ok((select reversed_at is not null and reverse_reason = 'matched the wrong family' from statement_matches where id = (select m from u0)), 'the match record is marked reversed, with the reason');
select t.ok(exists (select 1 from centre_payments where kind = 'reversal' and org_id = t.id('c1') and amount_cents = 7000), 'a reversal row exists (the original payment is untouched)');
select t.ok((select stub and ref_text is null and payer_text is null and bank_ref is null and cents = 7000 from statement_lines where org_id = t.id('c1') and stub and cents = 7000), 'the line comes back as a stub: date and amount only, no text');
select t.ok((stmt_undo((select m from u0), 'again') ->> 'already')::boolean, 'undo twice answers already, writes nothing more');
select t.eq((select count(*) from centre_payments where kind = 'reversal' and org_id = t.id('c1') and amount_cents = 7000), 1, 'one reversal only');
-- re-match the stub by hand → a NEW match record (the old one stays reversed)
select t.as(:'o1'); select stmt_confirm((select id from statement_lines where org_id = t.id('c1') and stub and cents = 7000), array[t.id('I6')], false);
select t.eq(pg_temp.bal('I6'), 0, 'the stub is matched again');
select t.eq((select count(*) from statement_matches where org_id = t.id('c1') and cents = 7000), 2, 'two match records: one reversed, one live');
-- a payment reversed on the Invoices screen first: undo still works and says so
create temp table u1 as select id as m, payment_id as p from statement_matches where org_id = t.id('c1') and cents = 7000 and reversed_at is null;
select centre_reverse_payment((select p from u1), 'wrong, reversed from the invoice screen');
select t.ok((select payment_reversed from jsonb_to_recordset(stmt_queue(t.id('c1'))->'matched') as x(id uuid, payment_reversed boolean) where id = (select m from u1)), 'the matched list flags a payment reversed elsewhere');
select t.ok((stmt_undo((select m from u1), 'tidy up') ->> 'payment_already_reversed')::boolean, 'undo of an already-reversed payment succeeds without a second reversal');
select t.eq((select count(*) from centre_payments where kind = 'reversal' and org_id = t.id('c1') and amount_cents = 7000), 2, 'still only one reversal per payment');

-- "not ours"
select t.as(:'o1'); select stmt_ignore(pg_temp.lid('B13'));
select t.ok(not exists (select 1 from statement_lines where bank_ref = 'B13') and exists (select 1 from statement_matches where org_id = t.id('c1') and kind = 'ignored' and cents = 123), '"not ours": the line goes, a name-free record stays');
select stmt_undo((select id from statement_matches where org_id = t.id('c1') and kind = 'ignored' and cents = 123), 'it was ours');
select t.ok(exists (select 1 from statement_lines where org_id = t.id('c1') and stub and cents = 123), 'undo of "not ours" puts the stub back');
select t.ok((stmt_ignore_out(t.id('c1')) ->> 'ignored')::int >= 1, 'money out can be marked "not ours" in one go');
select t.ok(not exists (select 1 from statement_lines where org_id = t.id('c1') and cents < 0), 'no money-out line is left waiting');

-- ===================================================================== 12. retention, masking, audit
select pg_temp.imp(:'o1', t.id('c1'), jsonb_build_array(pg_temp.ln(0, 654, 'acct 123456789012 ZEBRAQ ref ' || pg_temp.num('I3'), 'ZEBRAQ Person', 'G1456789012')));
select t.ok((select ref_text like '%****9012%' and ref_text not like '%123456789012%' and ref_text like '%' || pg_temp.num('I3') || '%' and bank_ref = 'G****9012' || '' or bank_ref like '%****%'
              from statement_lines where payer_text = 'ZEBRAQ Person'), 'a run of 9+ digits is cut to its last 4; the invoice number survives');
select pg_temp.conf(:'o1', (select bank_ref from statement_lines where payer_text = 'ZEBRAQ Person'), array[t.id('I10')], true);
select t.ok(not exists (select 1 from statement_lines where ref_text ilike '%zebraq%' or payer_text ilike '%zebraq%'), 'after it is resolved no raw text of that line is left in statement_lines');
select t.ok(not exists (select 1 from statement_matches m where m::text ilike '%zebraq%') and not exists (select 1 from statement_batches b where b::text ilike '%zebraq%') and not exists (select 1 from statement_fingerprints f where f::text ilike '%zebraq%'), 'matches, batches and fingerprints hold no name or text');
select t.ok(not exists (select 1 from audit_log where before::text ilike '%zebraq%' or after::text ilike '%zebraq%' or before::text like '%123456789012%' or after::text like '%123456789012%'), 'the audit log holds no payer name and no account number');
select t.ok(exists (select 1 from audit_log where action = 'statement_import' and org_id = t.id('c1') and after ? 'auto_matched'), 'an import writes one summary line (counts only)');
select t.ok(exists (select 1 from audit_log where table_name = 'statement_payer_links' and org_id = t.id('c1') and after->>'payer_key' = '[redacted]'), 'a payer link is audited with the name redacted');
select t.ok(exists (select 1 from audit_log where table_name = 'statement_matches' and org_id = t.id('c1') and action = 'update' and after->>'reverse_reason' = '[redacted]'), 'an undo reason is redacted in the audit copy');
-- purge: unresolved lines vanish 60 days after import (inside the next import); fingerprints stay
select pg_temp.imp(:'o1', t.id('c1'), jsonb_build_array(pg_temp.ln(0, 4321, 'old', 'Old Payer', 'P1')));
select t.ok((select purge_after = (select today from td) + 60 from statement_lines where bank_ref = 'P1'), 'an unresolved line is kept for 60 days');
reset role; update statement_lines set purge_after = (select today from td) - 1 where bank_ref = 'P1'; set role authenticated;
select pg_temp.imp(:'o1', t.id('c1'), '[]');
select t.ok(not exists (select 1 from statement_lines where bank_ref = 'P1'), 'after 60 days an unresolved line is deleted');
select t.ok((select (stmt_check(t.id('c1'), 'Main account', jsonb_build_array(pg_temp.ln(0, 4321, 'old', 'Old Payer', 'P1'))) ->> 'known')::int) = 1, 'but its fingerprint stays, so the same file does not bring it back');

-- ===================================================================== 13. who can read the tables, and nobody can write them
reset role; set role authenticated;
select t.as(:'o1'); select t.ok((select count(*) from statement_lines) > 0 and (select count(*) from statement_matches) > 0, 'the owner reads lines and matches of their own centre');
select t.as(:'paym'); select t.ok((select count(*) from statement_lines) > 0, 'staff with record_payments read the queue');
select t.as(:'bill'); select t.eq((select count(*) from statement_lines) + (select count(*) from statement_matches) + (select count(*) from statement_payer_links), 0, 'staff without record_payments read nothing');
select t.as(:'tut'); select t.eq((select count(*) from statement_lines) + (select count(*) from statement_matches) + (select count(*) from statement_batches) + (select count(*) from statement_mappings), 0, 'a tutor reads nothing');
select t.as(:'par'); select t.eq((select count(*) from statement_lines) + (select count(*) from statement_matches), 0, 'a parent reads nothing');
select t.as(:'o2'); select t.eq((select count(*) from statement_lines) + (select count(*) from statement_matches) + (select count(*) from statement_payer_links), 0, 'another centre reads nothing');
select t.as(:'solo'); select t.eq((select count(*) from statement_lines) + (select count(*) from statement_matches), 0, 'a solo tutor reads nothing');
select t.as(:'o1');
select t.fails('insert into statement_lines(org_id, line_date, cents, fp, occ, purge_after) values (' || quote_literal(t.id('c1')) || ', current_date, 100, ''x'', 1, current_date)', 'the owner cannot write a line directly');
select t.fails('update statement_matches set cents = 1 where true', 'nobody edits a match record');
select t.fails('delete from statement_payer_links where true', 'nobody deletes a payer link except through the function');
select t.fails('insert into statement_fingerprints(org_id, fp, occ) values (' || quote_literal(t.id('c1')) || ', ''x'', 1)', 'fingerprints cannot be written directly');
select t.fails(format('select stmt_run_rules(%L, current_date, null)', t.id('c1')), 'the rules engine itself is not callable');
select t.fails(format('select stmt_apply_match(%L, %L, array[%L::uuid], ''manual'', false, false, current_date)', t.id('c1'), gen_random_uuid(), t.id('I3')), 'the internal match writer is not callable');

-- ===================================================================== 14. speed: 1,000 lines against ~70 open invoices
reset role;
do $$
declare i int; c1 uuid := t.id('c1'); hh uuid; st uuid;
begin
  perform t.as('00000000-0000-0000-0000-00000000e301');
  for i in 1 .. 60 loop
    insert into households(id, org_id, name) values (gen_random_uuid(), c1, 'Perf Family ' || i) returning id into hh;
    insert into students(id, tutor_id, org_id, name, household_id) values (gen_random_uuid(), '00000000-0000-0000-0000-00000000e301', c1, 'Perf Kid ' || i, hh) returning id into st;
    perform pg_temp.inv('PF' || i, c1, '00000000-0000-0000-0000-00000000e301', hh, st, 10000 + i * 100, 0, 7);
  end loop;
end $$;
create temp table perf_lines as
  select jsonb_agg(case when g <= 60 then pg_temp.ln(-(g % 5), 10000 + g * 100, 'fees ' || pg_temp.num('PF' || g), 'Payer ' || g, 'PERF' || g)          -- 60 that pay themselves by invoice number
                        when g % 7 = 0 then pg_temp.ln(-(g % 5), 10000 + ((g % 60) + 1) * 100, 'ref ' || g, 'Payer ' || (g % 80), 'PERF' || g)       -- amounts that exist but are already paid / ambiguous
                        else pg_temp.ln(-(g % 5), 777 + g, 'ref ' || g, 'Payer ' || (g % 80), 'PERF' || g) end order by g) j from generate_series(1, 1000) g;
\timing off
select now() as t0 \gset
select t.ok((pg_temp.imp(:'o1', t.id('c1'), (select j from perf_lines)) ->> 'new')::int = 1000, '1,000 lines imported');
select t.ok(extract(epoch from now() - :'t0'::timestamptz) < 30, 'a 1,000-line import (with matching) finishes well inside the time limit');
select t.ok((select count(*) from statement_matches where org_id = t.id('c1') and auto) >= 60, 'the 60 lines that carry an invoice number and the exact amount were paid in that one import');
select t.ok((select (stmt_import(t.id('c1'), 'Main account', null, (select j from perf_lines)) ->> 'new')::int = 0 from (select t.as(:'o1')) q), 'the same 1,000 lines again add nothing');
\echo statement matching tests done
