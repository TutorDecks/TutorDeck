-- =====================================================================================================
-- T3 step 4 — centre Pending charges for owners and staff                          undo: migration_staff_charges_down.sql
-- =====================================================================================================
-- Needs migration_org_foundation.sql, migration_attendance.sql, migration_tutor_access.sql and migration_staff_attendance.sql.
-- ADD-ONLY: five new functions; no table, column, policy or trigger is touched. Nothing here creates an invoice (that is T4).
--
-- THE MODEL (unchanged, owner's rule): an absent / cancelled lesson becomes status 'cancelled' and its billable amount is its COMPENSATION,
-- a number someone types: 0 = the family isn't charged, null = "charge pending" (invoicing must wait for it). `lessons.compensation` is
-- numeric DOLLARS (it always was); `compensation_cents` is the generated whole-cents twin. These functions speak INTEGER CENTS at the edge
-- (as assets/js/money.js does) and store cents / 100 exactly, so the two columns can never disagree.
--
-- WHO MAY CALL (owner's decision, 2026-11-25): an active OWNER, or STAFF holding `issue_invoices`. NOT manage_timetable: a receptionist who marks
-- attendance can't set what a family pays. A tutor, a parent, switched-off staff, a stranger, a solo organisation and an unknown id all get
-- the same NOT_FOUND; staff without issue_invoices get NOT_ALLOWED in plain words.
--
-- THE QUEUE = lessons whose attendance is absent / cancelled_early / late_cancelled and whose compensation is null. (The same rule as the
-- "charges to confirm" number on the centre Home.) Which of the two settings puts a lesson in the queue:
--   lessons.compensation_entered_by = admin   (default) every absent / cancelled lesson waits here, whoever marked it
--   lessons.compensation_entered_by = tutor   the tutor must type the charge when marking (CHARGE_REQUIRED, existing tutor function), so the
--                                             queue holds only lessons STAFF marked and old ones. Staff may always type or change a charge
--                                             here, whatever the setting (they are the safety net); changing a charge that already has a
--                                             number needs a written reason.
-- billing.absences.mode only PRE-FILLS a suggestion; a person always confirms (owner's decision). It is a MONEY rule, so it is read as of the
-- lesson's own day (org_settings_on(org, lesson_date)), not as of today (if no version existed yet that day, today's is used):
--   charged                 suggest the full price for absent, late cancelled and cancelled in time
--   not_charged             suggest 0
--   charged_unless_notice   suggest 0 for "cancelled in time" (that mark already means enough notice was given), the full price otherwise
--   (billing.absences.notice_hours is not re-computed: staff choose "cancelled in time" or "late cancelled" when they mark.)
--
-- RULES THAT NEVER BEND: the amount is a whole number of cents from 0 up to the lesson's own price (amount, else rate × hours); only an
-- absent / cancelled lesson has a charge; a paid lesson's charge is locked; every change writes a named audit entry (who, when, before, after).
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

-- ---------------------------------------------------------------- the gate every charge function starts with (internal)
create or replace function public.staff_charges_gate(p_org uuid) returns date
language plpgsql stable security definer set search_path = public as $$
declare tz text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select o.timezone into tz from organisations o where o.id = p_org and o.kind = 'centre';
  if tz is null or not exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active'
                               and m.role in ('owner', 'staff')) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if not org_can(p_org, 'issue_invoices') then
    raise exception 'NOT_ALLOWED: your account can''t set charges at this centre' using errcode = '42501';
  end if;
  return (now() at time zone tz)::date;
end $$;

-- ---------------------------------------------------------------- the lesson's own price in cents (internal, pure)
-- amount when set, else rate × hours; the same rule as tutor_mark_attendance; never null.
create or replace function public.lesson_price_cents(p_amount numeric, p_rate numeric, p_start time, p_end time) returns bigint
language sql immutable set search_path = public as $$
  select coalesce(round(nullif(p_amount, 0) * 100)::bigint,
                  round(p_rate * extract(epoch from (p_end - p_start)) / 3600 * 100)::bigint, 0)
$$;

-- ---------------------------------------------------------------- the suggestion from billing.absences.mode (internal, pure)
create or replace function public.charge_suggestion_cents(p_mode text, p_attendance text, p_price bigint) returns bigint
language sql immutable set search_path = public as $$
  select case p_mode
           when 'charged'               then p_price
           when 'not_charged'           then 0
           when 'charged_unless_notice' then case when p_attendance = 'cancelled_early' then 0 else p_price end
         end
$$;

-- ---------------------------------------------------------------- how many charges are waiting (for Home, and for T4: "not ready to invoice")
create or replace function public.pending_charge_count(p_org uuid) returns int
language plpgsql stable security definer set search_path = public as $$
declare n int;
begin
  perform staff_charges_gate(p_org);
  select count(*)::int into n from lessons l
   where l.org_id = p_org and l.attendance in ('absent', 'cancelled_early', 'late_cancelled') and l.compensation is null;
  return n;
end $$;

-- ---------------------------------------------------------------- the queue
-- Newest first, 1..100 per page. Staff with issue_invoices see the lesson's price (that is the point); tutors never reach this.
create or replace function public.staff_pending_charges(p_org uuid, p_page int default 1, p_size int default 50) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_charges_gate(p_org); pg int := coalesce(p_page, 1); sz int := coalesce(p_size, 50); total int; rows jsonb;
begin
  if pg < 1 or pg > 100000 then raise exception 'BAD_PAGE: no such page' using errcode = 'P0001'; end if;
  if sz < 1 or sz > 100 then raise exception 'BAD_PAGE: ask for 1 to 100 lessons at a time' using errcode = 'P0001'; end if;

  select count(*)::int into total from lessons l
   where l.org_id = p_org and l.attendance in ('absent', 'cancelled_early', 'late_cancelled') and l.compensation is null;

  select coalesce(jsonb_agg(jsonb_build_object(
           'lesson_id', q.id, 'lesson_date', q.lesson_date, 'start_time', q.start_time, 'end_time', q.end_time,
           'student_id', q.sid, 'student_name', q.sname, 'student_level', q.slevel, 'subject', q.subject,
           'tutor_name', q.tname, 'attendance', q.attendance, 'remarks', q.remarks,
           'marked_by_name', q.mname, 'marked_at', q.attendance_marked_at, 'session_id', q.session_id,
           'price_cents', q.price, 'suggestion_mode', q.mode,
           'suggested_cents', charge_suggestion_cents(q.mode, q.attendance, q.price))
           order by q.lesson_date desc, q.start_time desc, q.sname, q.id), '[]'::jsonb)
    into rows
    from (select l.id, l.lesson_date, l.start_time, l.end_time, l.subject, l.attendance, l.remarks, l.session_id, l.attendance_marked_at,
                 s.id as sid, s.name as sname, s.level as slevel, t.display_name as tname, mb.display_name as mname,
                 lesson_price_cents(l.amount, l.rate, l.start_time, l.end_time) as price,
                 coalesce(org_settings_on(p_org, l.lesson_date) #>> '{billing,absences,mode}',      -- the rule in force that day,
                          org_settings_on(p_org, today) #>> '{billing,absences,mode}') as mode          -- else today's (no version existed yet)
            from lessons l
            join students s on s.id = l.student_id and s.org_id = l.org_id
            left join memberships t  on t.id = l.taught_by and t.org_id = l.org_id
            left join memberships mb on mb.user_id = l.attendance_marked_by and mb.org_id = l.org_id
           where l.org_id = p_org and l.attendance in ('absent', 'cancelled_early', 'late_cancelled') and l.compensation is null
           order by l.lesson_date desc, l.start_time desc, s.name, l.id
           limit sz offset (pg - 1) * sz) q;

  return jsonb_build_object('today', today, 'page', pg, 'size', sz, 'total', total, 'rows', rows);
end $$;

-- ---------------------------------------------------------------- one charge
-- p_amount_cents: whole cents, 0 = the family isn't charged. p_reason: required only when the lesson ALREADY has a charge (a change).
create or replace function public.staff_set_charge(p_lesson uuid, p_amount_cents bigint, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l lessons; price bigint; old_c bigint; why text := nullif(trim(coalesce(p_reason, '')), '');
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into l from lessons where id = p_lesson for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  perform staff_charges_gate(l.org_id);

  if l.attendance is null or l.attendance not in ('absent', 'cancelled_early', 'late_cancelled') then
    raise exception 'NOT_CANCELLED: only a lesson marked absent or cancelled has a charge' using errcode = 'P0001'; end if;
  price := lesson_price_cents(l.amount, l.rate, l.start_time, l.end_time);
  if p_amount_cents is null or p_amount_cents < 0 or p_amount_cents > price then
    raise exception 'BAD_CHARGE: enter an amount from 0 up to the lesson''s own price (S$%)', to_char(price / 100.0, 'FM999999990.00') using errcode = 'P0001'; end if;
  if l.paid then raise exception 'ALREADY_PAID: this lesson is already paid, so its charge can''t be changed' using errcode = 'P0001'; end if;

  old_c := l.compensation_cents;
  if old_c is not null then
    if old_c = p_amount_cents then raise exception 'NO_CHANGE: the charge is already that amount' using errcode = 'P0001'; end if;
    if why is null then raise exception 'REASON_REQUIRED: this lesson already has a charge; say why you are changing it' using errcode = 'P0001'; end if;
  end if;
  if length(coalesce(why, '')) > 500 then raise exception 'TOO_LONG: keep the reason under 500 characters' using errcode = 'P0001'; end if;

  update lessons set compensation = p_amount_cents / 100.0 where id = l.id;

  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (l.org_id, auth.uid(), 'staff_set_charge', 'lessons', l.id::text,
          jsonb_build_object('compensation_cents', old_c, 'attendance', l.attendance),
          jsonb_build_object('compensation_cents', p_amount_cents, 'price_cents', price, 'reason', why));
  return jsonb_build_object('lesson_id', l.id, 'compensation_cents', p_amount_cents, 'price_cents', price);
end $$;

-- ---------------------------------------------------------------- many charges at once (only lessons still waiting for one)
-- p_mode 'amount': the SAME amount for each (p_amount_cents, 0 = not charged; it may not exceed ANY of the lessons' own prices)
-- p_mode 'full'  : each lesson's own price. All or nothing: one problem and nothing is saved.
create or replace function public.staff_set_charges(p_lessons uuid[], p_mode text, p_amount_cents bigint default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ids uuid[]; org uuid; n int; r record; price bigint; amt bigint; done int := 0; total bigint := 0;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_mode is null or p_mode not in ('amount', 'full') then raise exception 'BAD_VALUE: choose a charge' using errcode = 'P0001'; end if;
  select coalesce(array_agg(distinct x), '{}') into ids from unnest(coalesce(p_lessons, '{}')) x where x is not null;
  n := coalesce(array_length(ids, 1), 0);
  if n = 0 then raise exception 'BAD_VALUE: choose at least one lesson' using errcode = 'P0001'; end if;
  if n > 100 then raise exception 'TOO_MANY: choose up to 100 lessons at a time' using errcode = 'P0001'; end if;

  -- every id must exist and all must belong to ONE centre (anything else: the same NOT_FOUND, so ids can't be probed)
  select (array_agg(l.org_id))[1] into org from lessons l where l.id = any(ids);
  if (select count(*) from lessons l where l.id = any(ids)) <> n or (select count(distinct l.org_id) from lessons l where l.id = any(ids)) <> 1 then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  perform staff_charges_gate(org);

  if p_mode = 'amount' and (p_amount_cents is null or p_amount_cents < 0) then
    raise exception 'BAD_CHARGE: enter an amount of 0 or more' using errcode = 'P0001'; end if;

  -- lock them in a fixed order, then check every one before writing any
  for r in select l.* from lessons l where l.id = any(ids) order by l.id for update loop
    if r.attendance is null or r.attendance not in ('absent', 'cancelled_early', 'late_cancelled') then
      raise exception 'NOT_CANCELLED: only a lesson marked absent or cancelled has a charge' using errcode = 'P0001'; end if;
    if r.compensation is not null then
      raise exception 'ALREADY_SET: someone has already set the charge for one of these lessons. Refresh the list and try again' using errcode = 'P0001'; end if;
    if r.paid then raise exception 'ALREADY_PAID: one of these lessons is already paid' using errcode = 'P0001'; end if;
    price := lesson_price_cents(r.amount, r.rate, r.start_time, r.end_time);
    if p_mode = 'amount' and p_amount_cents > price then
      raise exception 'BAD_CHARGE: that amount is more than one of these lessons costs (S$%). Choose "Charge full price" or a smaller amount', to_char(price / 100.0, 'FM999999990.00') using errcode = 'P0001'; end if;
  end loop;

  for r in select l.* from lessons l where l.id = any(ids) order by l.id loop
    price := lesson_price_cents(r.amount, r.rate, r.start_time, r.end_time);
    amt := case p_mode when 'full' then price else p_amount_cents end;
    update lessons set compensation = amt / 100.0 where id = r.id;
    insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
    values (r.org_id, auth.uid(), 'staff_set_charge', 'lessons', r.id::text,
            jsonb_build_object('compensation_cents', null, 'attendance', r.attendance),
            jsonb_build_object('compensation_cents', amt, 'price_cents', price, 'bulk', n, 'mode', p_mode));
    done := done + 1; total := total + amt;
  end loop;
  return jsonb_build_object('updated', done, 'total_cents', total);
end $$;

-- ---------------------------------------------------------------- who may call what
revoke all on function public.staff_pending_charges(uuid, int, int) from public, anon;
revoke all on function public.staff_set_charge(uuid, bigint, text) from public, anon;
revoke all on function public.staff_set_charges(uuid[], text, bigint) from public, anon;
revoke all on function public.pending_charge_count(uuid) from public, anon;
grant execute on function public.staff_pending_charges(uuid, int, int) to authenticated;
grant execute on function public.staff_set_charge(uuid, bigint, text) to authenticated;
grant execute on function public.staff_set_charges(uuid[], text, bigint) to authenticated;
grant execute on function public.pending_charge_count(uuid) to authenticated;
revoke all on function public.staff_charges_gate(uuid) from public, anon, authenticated;
revoke all on function public.lesson_price_cents(numeric, numeric, time, time) from public, anon, authenticated;
revoke all on function public.charge_suggestion_cents(text, text, bigint) from public, anon, authenticated;
