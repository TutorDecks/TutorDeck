-- T35-E: centre data export (owner only).  Undo: migration_org_export_down.sql.   Apply AFTER migration_tutor_moves.sql (it reads td_payout_mask from tutor_payout).
--
-- WHAT THIS IS. The centre OWNER can download every record the centre holds (CSV per table + a ZIP of all, built in the browser). The browser never gets
-- table access for this: it can only call the four functions below, and every one of them re-checks "is this person an ACTIVE OWNER of this CENTRE" itself.
-- Tutors, staff (even with every permission), parents, the owner of another centre, a solo tutor, a platform admin (even with a support grant) and anonymous
-- callers all get NOT_FOUND, exactly as if the centre didn't exist. No service key is used anywhere.
--
--   org_export_catalog()                       the ONE list of what is exported: per table, an explicit column list (never select *), mode include/exclude, and a
--                                              written reason for every exclusion. A new table with an org id that is not listed here fails tests/sql/org_export_test.sql.
--   org_export_start(org, full_payout)         audits "export started" (who, when, tables, expected row counts, whether full payout numbers were asked for: never any data),
--                                              returns the job number and the row count of each table. At most 12 starts per centre per rolling hour.
--   org_export_page(org, job, table, after, n) one keyset page of one table (n <= 5000, ordered by the table's unique key, "after" = the last key seen). Only works inside
--                                              a started, unfinished job of the same person (3 hours). Whether payout numbers are masked comes from the START row, never
--                                              from this call, so unmasking cannot be asked for without leaving an audit row first.
--   org_export_finish(org, job, counts)        audits "export finished" with the row counts the browser says it wrote, and whether they match what the database counted at the start.
--
-- WHAT IS NEVER EXPORTED: other centres' rows (every query is "where org = p_org"); passwords, login tokens and auth.* (not even touched); user ids (a "who" column is
-- turned into the person's NAME; people who have left read "Former member"); Stripe / billing-provider ids (org_subscriptions is excluded); invoice share links
-- (centre_invoice_share excluded, share_token never selected); Google calendar ids; the mail provider's message ids; in-app notices. Tutor payout numbers (bank account /
-- PayNow) and the account holder's name are MASKED (•••••1234, first letter + •••) unless the owner ticked "include full payout numbers" (audited before any data moves).
-- The centre's audit trail is exported with secret keys and login ids removed from its before/after copies (org_export_scrub()).
--
-- The Supabase API refuses a DELETE or UPDATE without a WHERE clause: this file has none (it only reads and appends audit rows).
-- Free-text and money columns follow the table: money is integer cents (the browser adds a dollars column next to every *_cents column).

-- ---------------------------------------------------------------- keys that must never leave inside an audit before/after copy
create or replace function public.org_export_secret_keys() returns text[]
language sql immutable set search_path = public as $$
  select array['share_token','token','stripe_customer_id','stripe_subscription_id','refresh_enc','brevo_message_id','paynow_id','account_no','account_holder','user_id','gcal_event_id','proof_path','file_path']
$$;

-- the audit log keeps whole-row copies: take out the secret keys above AND every key that names a login (tutor_id, *_by, actor, user_id, owner_id), so no user id leaves
create or replace function public.org_export_scrub(p_j jsonb) returns jsonb
language sql immutable set search_path = public as $$
  select case when p_j is null or jsonb_typeof(p_j) <> 'object' then p_j
    else (select coalesce(jsonb_object_agg(e.k, e.v), '{}'::jsonb) from jsonb_each(p_j) e(k, v)
           where e.k <> all (org_export_secret_keys()) and e.k !~ '(_by$|^actor$|user_id$|^tutor_id$|^owner_id$)') end
$$;

-- ---------------------------------------------------------------- the catalogue
-- cols entries:  'col'            plain column
--                'col=@who'       a user id, exported as that person's NAME in this centre ('Former member' if they have left)
--                'col=@mask'      payout number: •••••1234 unless the job was started with full_payout
--                'col=@maskname'  payout holder name: first letter + ••• unless full_payout
--                'col=@scrub'     audit before/after: the secret keys above removed
--                'alias=<sql>'    a computed column written in terms of the table alias t (constants only, written here, never from the browser)
create or replace function public.org_export_catalog()
returns table(tbl text, mode text, org_col text, key_col text, key_type text, filter text, cols text[], reason text)
language sql immutable set search_path = public as $$
  select * from (values
  ('organisations', 'include', 'id', 'id', 'uuid', null,
     array['id','trading_name','legal_name','uen','address','kind','preset','status','timezone','currency','reply_to_email','brand_color','created_at'], null),
  ('branches', 'include', 'org_id', 'id', 'uuid', null, array['id','name','address','created_at'], null),
  ('rooms', 'include', 'org_id', 'id', 'uuid', null, array['id','branch_id','name','capacity'], null),
  ('terms', 'include', 'org_id', 'id', 'uuid', null, array['id','name','starts_on','ends_on'], null),
  ('holidays', 'include', 'org_id', 'id', 'uuid', null, array['id','branch_id','name','starts_on','ends_on'], null),
  ('memberships', 'include', 'org_id', 'id', 'uuid', null,
     array['id','display_name','role','permissions','employment_type','status','invited_email','phone','created_at'], null),
  ('tutor_payout_details', 'include', 'org_id', 'id', 'uuid', 't.superseded_at is null and t.cleared_at is null',
     array['id','membership_id','method','bank_name','paynow_id=@mask','account_no=@mask','account_holder=@maskname','created_at'], null),
  ('households', 'include', 'org_id', 'id', 'uuid', null, array['id','name','phone_key','created_at'], null),
  ('guardians', 'include', 'org_id', 'id', 'uuid', null, array['id','household_id','name','relation','phone','email','created_at'], null),
  ('students', 'include', 'org_id', 'id', 'uuid', null,
     array['id','household_id','name','kind','level','contact','recipient_name','household','location','online_link','pay_by_bank','notes','active','start_date','end_date','created_at'], null),
  ('student_tutors', 'include', 'org_id', 'id', 'uuid', null,
     array['id','student_id','membership_id','since','until','active','created_by=@who','created_at'], null),
  ('recurring_slots', 'include', 'org_id', 'id', 'uuid', null,
     array['id','student_id','student_name=(select s.name from students s where s.id = t.student_id and s.org_id = t.org_id)','taught_by',
           'tutor_name=(select m.display_name from memberships m where m.id = t.taught_by and m.org_id = t.org_id)',
           'session_key','weekday','start_time','end_time','subject','level','split','rate_cents','active','starts_on','stopped_from','created_at'], null),
  ('lessons', 'include', 'org_id', 'id', 'uuid', null,
     array['id','student_id','student_name=(select s.name from students s where s.id = t.student_id and s.org_id = t.org_id)','taught_by',
           'tutor_name=(select m.display_name from memberships m where m.id = t.taught_by and m.org_id = t.org_id)',
           'covered_for','slot_id','session_id','lesson_date','start_time','end_time','subject','level','split','status','attendance','attendance_marked_at',
           'attendance_marked_by=@who','trial','one_off','postponed','slot_date','rate_cents','amount_cents','compensation_cents','charge_note','paid','paid_date',
           'topics','homework','remarks','remarks_at','subject_notes','changed_by_tutor=@who','changed_by_tutor_at','changed_by_tutor_what','changed_by_tutor_reason',
           'changed_from_date','changed_from_start','created_at'], null),
  ('exams', 'include', 'org_id', 'id', 'uuid', null,
     array['id','student_id','student_name=(select s.name from students s where s.id = t.student_id and s.org_id = t.org_id)','subject','exam_date','assessment_type','score','max_score','topics','remarks','created_at'], null),
  ('invoices', 'include', 'org_id', 'id', 'uuid', null,
     array['id','student_id','invoice_no','issued_date','total_cents','status','paid_date','sent_at','data=(t.data - ''html'')','created_at'], null),
  ('centre_invoices', 'include', 'org_id', 'id', 'uuid', null,
     array['id','kind','series','status','number_text','number_seq','imported_number','household_id',
           'household_name=(select h.name from households h where h.id = t.household_id and h.org_id = t.org_id)','student_id',
           'student_name=(select s.name from students s where s.id = t.student_id and s.org_id = t.org_id)','credits_invoice_id','period_start','period_end','issue_date','due_date',
           'gst_registered','gst_rate_bp','gst_inclusive','net_cents','gst_cents','total_cents','reason','void_reason','created_by=@who','created_at','issued_by=@who','issued_at','voided_at'], null),
  ('centre_invoice_lines', 'include', 'org_id', 'id', 'uuid', null,
     array['id','invoice_id','position','lesson_id','student_id','fee_kind','description','qty','unit_cents','line_cents','created_at'], null),
  ('centre_payments', 'include', 'org_id', 'id', 'uuid', null,
     array['id','kind','reverses_payment_id','household_id','household_name=(select h.name from households h where h.id = t.household_id and h.org_id = t.org_id)',
           'method','amount_cents','received_on','reference','payer_name','note','recorded_by=@who','created_at'], null),
  ('centre_payment_allocations', 'include', 'org_id', 'id', 'uuid', null, array['id','payment_id','invoice_id','cents','created_by=@who','created_at'], null),
  ('centre_family_credit', 'include', 'org_id', 'id', 'uuid', null,
     array['id','household_id','kind','handling','cents','payment_id','invoice_id','method','reference','reason','refund_id','created_by=@who','created_at'], null),
  ('centre_deposits', 'include', 'org_id', 'id', 'uuid', null,
     array['id','student_id','household_id','source','mode','percent_bp','first_month_cents','required_cents','taxable','period_start','invoice_id','created_by=@who','created_at'], null),
  ('centre_deposit_ledger', 'include', 'org_id', 'id', 'uuid', null,
     array['id','student_id','deposit_id','kind','cents','taxable','invoice_id','payment_id','allocation_id','refund_id','entry_date','reason','created_by=@who','created_at'], null),
  ('centre_refunds', 'include', 'org_id', 'id', 'uuid', null,
     array['id','kind','student_id','household_id','deposit_id','refund_cents','forfeit_cents','set_off_cents','held_cents','taxable','gst_cents','release_rule','notice_days',
           'notice_given_on','lesson_end','payer_name','reason','requested_by=@who','requested_on','created_at'], null),
  ('centre_refund_events', 'include', 'org_id', 'id', 'uuid', null,
     array['id','refund_id','kind','event_on','method','reference','reason','note','set_off_cents','actor=@who','created_at'], null),
  ('centre_late_fees', 'include', 'org_id', 'id', 'uuid', null,
     array['id','invoice_id','month_no','fee_date','status','fee_cents','base_cents','rule','household_id','student_id','document_id','decided_by=@who','decided_at','reason','created_at'], null),
  ('tutor_pay_rates', 'include', 'org_id', 'id', 'uuid', null,
     array['id','membership_id','student_id','level','method','amount_cents','percent_bp','effective_from','reason','created_by=@who','created_at'], null),
  ('tutor_pay_payments', 'include', 'org_id', 'id', 'uuid', null,
     array['id','kind','reverses_payment_id','membership_id','tutor_name','period_from','period_to','amount_cents','paid_on','method','reference','note','recorded_by=@who','created_at'], null),
  ('tutor_pay_adjustments', 'include', 'org_id', 'id', 'uuid', null,
     array['id','membership_id','kind','amount_cents','effective_on','reason','created_by=@who','created_at'], null),
  ('makeup_credits', 'include', 'org_id', 'id', 'uuid', null,
     array['id','student_id','source','source_lesson_id','reason','earned_on','expires_on','status','created_by=@who','created_at'], null),
  ('makeup_credit_events', 'include', 'org_id', 'id', 'int8', null,
     array['id','credit_id','kind','lesson_id','actor=@who','reason','at'], null),
  ('import_batches', 'include', 'org_id', 'id', 'uuid', null,
     array['id','created_by=@who','created_at','stage','status','counts','undo_until','undone_at','undo_report'], null),
  ('statement_mappings', 'include', 'org_id', 'id', 'uuid', null,
     array['id','name','version','mapping','created_by=@who','created_at'], null),
  ('statement_batches', 'include', 'org_id', 'id', 'uuid', null,
     array['id','account_label','mapping_id','date_from','date_to','n_lines','n_new','n_duplicate','n_skipped','n_auto','n_review','imported_by=@who','imported_at'], null),
  ('statement_lines', 'include', 'org_id', 'id', 'uuid', null,
     array['id','batch_id','row_no','line_date','cents','ref_text','payer_text','bank_ref','reason','created_at'], null),
  ('statement_matches', 'include', 'org_id', 'id', 'uuid', null,
     array['id','batch_id','line_date','cents','kind','rule','household_id','payment_id','auto','confirmed_by=@who','confirmed_at','reversed_at','reversed_by=@who','reverse_reason'], null),
  ('statement_payer_links', 'include', 'org_id', 'id', 'uuid', null,
     array['id','payer_key','household_id','times_used','last_used','created_at'], null),
  ('schedule_requests', 'include', 'org_id', 'id', 'uuid', null,
     array['id','membership_id','kind','student_id','lesson_id','slot_id','reason','status','decision_code','decision_reason','decided_by=@who','decided_at','created_at','expires_at'], null),
  ('email_queue', 'include', 'org_id', 'id', 'uuid', null,
     array['id','kind','invoice_id','payment_id','household_id','guardian_id','reminder_no','status','reason','attempts','not_before','requested_by=@who','requested_at','updated_at'], null),
  ('email_send_log', 'include', 'org_id', 'id', 'int8', null,
     array['id','queue_id','kind','invoice_id','guardian_id','to_masked','template','result','attempt','by_user=@who','at'], null),
  ('org_counters', 'include', 'org_id', 'series', 'text', null, array['series','next_number','locked','created_at'], null),
  ('org_invite_mail_log', 'include', 'org_id', 'id', 'uuid', null, array['id','membership_id','sent_by=@who','sent_at','status'], null),
  ('materials', 'include', 'org_id', 'id', 'uuid', null, array['id','subject','level','stream','topic','title','kind','file_name','size_bytes','created_at'], null),
  ('org_settings', 'include', 'org_id', 'id', 'uuid', null, array['id','version','schema_version','effective_from','settings','created_by=@who','created_at'], null),
  ('org_plans', 'include', 'org_id', 'id', 'uuid', null,
     array['id','plan_code','base_cents','per_student_cents','effective_from','billing_method','billing_starts_on','first_month_billable_override','billing_start_reason','created_at'], null),
  ('platform_fee_snapshots', 'include', 'org_id', 'month', 'date', null,
     array['month','active_students','billable_students','base_cents','per_student_cents','fee_cents','billable','waived_reason','override_students','computed_at'], null),
  ('support_access_grants', 'include', 'org_id', 'id', 'uuid', null, array['id','granted_by=@who','reason','expires_at','revoked_at','created_at'], null),
  ('audit_log', 'include', 'org_id', 'id', 'int8', null,
     array['id','at','actor=@who','action','table_name','row_id','before=@scrub','after=@scrub'], null),
  -- ---- excluded, each with the reason that is printed in the export's README
  ('centre_invoice_share', 'exclude', 'org_id', 'id', 'uuid', null, array[]::text[],
     'Invoice share links. Anyone holding one link can read that invoice, so the links are never put in a file.'),
  ('org_notifications', 'exclude', 'org_id', 'id', 'uuid', null, array[]::text[],
     'In-app notices addressed to individual users. They are not business records and name login accounts.'),
  ('import_items', 'exclude', 'org_id', 'batch_id', 'uuid', null, array[]::text[],
     'The import''s own bookkeeping (which row each imported line created, and a fingerprint of it) so that an import can be undone. Every row it points to is in its own file; the batch summaries are in import_batches.csv.'),
  ('statement_fingerprints', 'exclude', 'org_id', 'fp', 'text', null, array[]::text[],
     'Scrambled fingerprints of bank-statement lines, kept only so the same statement line is never matched twice. They hold no readable data; the matches themselves are in statement_matches.csv.'),
  ('org_subscriptions', 'exclude', 'org_id', 'org_id', 'uuid', null, array[]::text[],
     'TutorDeck''s billing-provider record for the centre (Stripe customer and subscription ids). You can see these in your own Stripe account; the fee history is in the plan and monthly fee files.')
  ) v(tbl, mode, org_col, key_col, key_type, filter, cols, reason)
$$;

-- ---------------------------------------------------------------- internal helpers (not callable by browsers)
-- the person's name for a user id in this centre; null stays null, someone who has since left reads "Former member"
create or replace function public.org_export_who(p_org uuid, p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when p_user is null then null
              else coalesce((select m.display_name from memberships m where m.org_id = p_org and m.user_id = p_user limit 1), 'Former member') end
$$;

-- the one door: an ACTIVE OWNER of a CENTRE. Everyone else (tutor, staff, parent, other centre, solo, platform admin, anonymous) gets NOT_FOUND.
create or replace function public.org_export_gate(p_org uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or p_org is null
     or not exists (select 1 from organisations o where o.id = p_org and o.kind = 'centre')
     or not exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.role = 'owner' and m.status = 'active') then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
end $$;

-- the started, unfinished job of THIS person in THIS centre, no older than 3 hours
create or replace function public.org_export_job(p_org uuid, p_job bigint) returns audit_log
language plpgsql stable security definer set search_path = public as $$
declare a audit_log;
begin
  select * into a from audit_log where id = p_job and org_id = p_org and actor = auth.uid() and action = 'org_export_started' and at > now() - interval '3 hours';
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if exists (select 1 from audit_log f where f.org_id = p_org and f.action = 'org_export_finished' and f.after->>'job' = p_job::text) then
    raise exception 'NOT_ALLOWED: this export has finished, start a new one' using errcode = '42501';
  end if;
  return a;
end $$;

-- ---------------------------------------------------------------- start
create or replace function public.org_export_start(p_org uuid, p_full_payout boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c record; n bigint; counts jsonb := '{}'::jsonb; tabs jsonb := '[]'::jsonb; names text[] := '{}'; job bigint; fullp boolean := coalesce(p_full_payout, false);
begin
  perform org_export_gate(p_org);
  if (select count(*) from audit_log where org_id = p_org and action = 'org_export_started' and at > now() - interval '1 hour') >= 12 then
    raise exception 'NOT_ALLOWED: too many exports in the last hour, please try again later' using errcode = '42501';
  end if;
  for c in select * from org_export_catalog() where mode = 'include' loop
    execute format('select count(*) from %I t where t.%I = $1%s', c.tbl, c.org_col, coalesce(' and (' || c.filter || ')', '')) into n using p_org;
    if c.tbl = 'audit_log' then n := n + 1 + case when fullp then 1 else 0 end; end if;     -- the rows this very start is about to write are part of the export
    counts := counts || jsonb_build_object(c.tbl, n);
    names := names || c.tbl;
    tabs := tabs || jsonb_build_array(jsonb_build_object('tbl', c.tbl, 'rows', n));
  end loop;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'org_export_started', 'organisations', p_org::text, null,
          jsonb_build_object('tables', to_jsonb(names), 'expected', counts, 'full_payout', fullp, 'payout_numbers', case when fullp then 'full' else 'masked' end))
  returning id into job;
  if fullp then
    insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
    values (p_org, auth.uid(), 'org_export_payout_full', 'tutor_payout_details', p_org::text, null, jsonb_build_object('job', job, 'payout_numbers', 'full'));
  end if;
  return jsonb_build_object('job', job, 'full_payout', fullp, 'tables', tabs);
end $$;

-- ---------------------------------------------------------------- one page of one table
create or replace function public.org_export_page(p_org uuid, p_job bigint, p_table text, p_after text default null, p_limit int default 2000) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a audit_log; c record; lim int := least(greatest(coalesce(p_limit, 2000), 1), 5000); fullp boolean; sel text := ''; names text[] := '{}'; spec text; alias text; expr text; res jsonb; q text;
begin
  perform org_export_gate(p_org);
  a := org_export_job(p_org, p_job);
  fullp := coalesce((a.after->>'full_payout')::boolean, false);
  select * into c from org_export_catalog() where tbl = p_table and mode = 'include';
  if not found then raise exception 'NOT_ALLOWED: unknown table' using errcode = '42501'; end if;
  foreach spec in array c.cols loop
    if position('=' in spec) > 0 then
      alias := split_part(spec, '=', 1); expr := substr(spec, position('=' in spec) + 1);
      expr := case expr
        when '@who'      then format('org_export_who(%L, t.%I)', p_org, alias)
        when '@mask'     then format('case when %L::boolean then t.%I else td_payout_mask(t.%I) end', fullp, alias, alias)
        when '@maskname' then format('case when %L::boolean then t.%I when t.%I is null or t.%I = '''' then null else left(t.%I, 1) || ''•••'' end', fullp, alias, alias, alias, alias)
        when '@scrub'    then format('org_export_scrub(t.%I)', alias)
        else expr end;
      sel := sel || case when sel = '' then '' else ', ' end || '(' || expr || ')';
    else
      alias := spec;
      sel := sel || case when sel = '' then '' else ', ' end || format('t.%I', alias);
    end if;
    names := names || alias;
  end loop;
  begin
    q := format('select jsonb_build_object(''cols'', %L::jsonb, ''rows'', coalesce(jsonb_agg(x.r order by x.k), ''[]''::jsonb), ''n'', count(*), ''last'', (array_agg(x.kt order by x.k desc))[1]) from ('
                'select t.%I as k, t.%I::text as kt, jsonb_build_array(%s) as r from %I t where t.%I = $1%s and ($2::text is null or t.%I > $2::%s) order by t.%I limit $3) x',
                to_jsonb(names)::text, c.key_col, c.key_col, sel, c.tbl, c.org_col, coalesce(' and (' || c.filter || ')', ''), c.key_col, c.key_type, c.key_col);
    execute q into res using p_org, p_after, lim;
  exception when invalid_text_representation or datetime_field_overflow or invalid_datetime_format or numeric_value_out_of_range then
    raise exception 'NOT_ALLOWED: bad cursor' using errcode = '42501';
  end;
  return jsonb_build_object('cols', res->'cols', 'rows', res->'rows', 'next', case when (res->>'n')::int >= lim then res->>'last' end);
end $$;

-- ---------------------------------------------------------------- finish
create or replace function public.org_export_finish(p_org uuid, p_job bigint, p_counts jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a audit_log; c record; bad jsonb := '[]'::jsonb; got bigint; want bigint; k text;
begin
  perform org_export_gate(p_org);
  a := org_export_job(p_org, p_job);
  if p_counts is null or jsonb_typeof(p_counts) <> 'object' then raise exception 'NOT_ALLOWED: counts must be an object' using errcode = '42501'; end if;
  for k in select jsonb_object_keys(p_counts) loop
    if not exists (select 1 from org_export_catalog() where tbl = k and mode = 'include') then raise exception 'NOT_ALLOWED: unknown table' using errcode = '42501'; end if;
    if jsonb_typeof(p_counts->k) <> 'number' or (p_counts->>k) !~ '^[0-9]{1,12}$' then raise exception 'NOT_ALLOWED: bad count' using errcode = '42501'; end if;
  end loop;
  for c in select tbl from org_export_catalog() where mode = 'include' loop
    want := (a.after->'expected'->>c.tbl)::bigint; got := coalesce((p_counts->>c.tbl)::bigint, -1);
    if got <> want then bad := bad || to_jsonb(c.tbl); end if;
  end loop;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'org_export_finished', 'organisations', p_org::text, null,
          jsonb_build_object('job', p_job, 'counts', p_counts, 'matched', jsonb_array_length(bad) = 0, 'differs', bad, 'full_payout', coalesce((a.after->>'full_payout')::boolean, false)));
  return jsonb_build_object('matched', jsonb_array_length(bad) = 0, 'differs', bad);
end $$;

-- ---------------------------------------------------------------- who may call what
do $$ declare f text; begin
  foreach f in array array['org_export_secret_keys()', 'org_export_scrub(jsonb)', 'org_export_who(uuid,uuid)', 'org_export_gate(uuid)', 'org_export_job(uuid,bigint)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated';
  end loop;
  foreach f in array array['org_export_catalog()', 'org_export_start(uuid,boolean)', 'org_export_page(uuid,bigint,text,text,int)', 'org_export_finish(uuid,bigint,jsonb)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated, service_role';
  end loop;
end $$;
