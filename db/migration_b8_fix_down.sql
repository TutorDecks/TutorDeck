-- Undo of migration_b8_fix.sql: every function goes back to the version it replaced.

create or replace function public.credit_consider(l lessons) returns void
language plpgsql security definer set search_path = public as $$
declare tz text; today date; cfg jsonb; src text; why text; days int; cid uuid; c makeup_credits; absences text[];
begin
  select o.timezone into tz from organisations o where o.id = l.org_id and o.kind = 'centre';
  if tz is null or l.makeup_credit_id is not null then return; end if;
  today := (now() at time zone tz)::date;
  cfg := credit_cfg(l.org_id, today);
  select * into c from makeup_credits where source_lesson_id = l.id;

  absences := case cfg ->> 'earn_absences' when 'notice_only' then array['cancelled_early']
                                           when 'notice_and_late' then array['cancelled_early', 'late_cancelled']
                                           when 'all_missed' then array['cancelled_early', 'late_cancelled', 'absent']
                                           else '{}'::text[] end;
  if cfg ->> 'rule' = 'one_per_missed' then
    if l.attendance = any(absences) then src := 'absence'; why := 'Missed lesson: ' || replace(l.attendance, '_', ' ');
    elsif l.status = 'cancelled' and l.attendance is null and l.changed_by_tutor_what = 'cancelled' and cfg ->> 'earn_tutor_cancel' = 'automatic' then
      src := 'tutor_cancel'; why := 'Cancelled by the tutor';
    elsif l.status = 'cancelled' and l.attendance is null and (cfg ->> 'earn_holiday')::boolean and coalesce(l.charge_note, '') like 'Holiday%'
          and exists (select 1 from holidays h where h.org_id = l.org_id and h.branch_id is null and l.lesson_date between h.starts_on and h.ends_on) then
      src := 'holiday'; why := 'Cancelled for a holiday';
    end if;
  end if;

  if src is not null and c.id is null then
    days := (cfg ->> 'expiry_days')::int;
    insert into makeup_credits(org_id, student_id, source, source_lesson_id, reason, earned_on, expires_on, created_by)
    values (l.org_id, l.student_id, src, l.id, why, today, case when days > 0 then today + days end, auth.uid())
    on conflict (source_lesson_id) where source_lesson_id is not null do nothing
    returning id into cid;
    if cid is not null then perform credit_event(cid, 'earned', l.id, why); end if;
  elsif src is null and c.id is not null and c.status = 'open' and c.source = 'absence' and cfg ->> 'rule' = 'one_per_missed'
        and (l.attendance is null or l.attendance = 'attended') then
    -- the mark was corrected to "attended" (or cleared): the lesson was not missed after all, so its UNUSED credit goes (a booked or used one stays)
    perform credit_move(c.id, 'open', 'revoked', 'revoked', null, 'The lesson''s mark was corrected, so it no longer earns a credit');
  end if;
end $$;

create or replace function public.centre_deposit_run_candidates(p_org uuid, p_ms date, p_today date)
returns table(d_student_id uuid, d_student_name text, d_household_id uuid, d_unit_key text, d_deposit_id uuid, d_mode text, d_percent_bp int,
              d_first_month_cents bigint, d_amount_cents bigint, d_taxable boolean, d_frozen boolean)
language plpgsql security definer set search_path = public, pg_temp as $$
declare s jsonb := coalesce(org_settings_on(p_org, p_today), org_settings_on(p_org, p_ms)); me date := (p_ms + interval '1 month - 1 day')::date;
  v_mode text; v_due text; v_bp int; v_fix bigint; v_tax boolean;
begin
  if s is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  v_mode := coalesce(s#>>'{billing,deposit,mode}', 'none');
  v_due  := coalesce(s#>>'{billing,deposit,due}', 'with_first_invoice');
  v_bp   := coalesce((s#>>'{billing,deposit,percent_bp}')::int, 0);
  v_fix  := coalesce((s#>>'{billing,one_off_fees,deposit_cents}')::bigint, 0);
  v_tax  := coalesce((s#>>'{billing,deposit,taxable}')::boolean, false);
  return query
  with fm as (                                       -- each student's non-trial lesson fee in an invoice that is READY (before discounts, fees and GST)
    select r.unit_key as ukey, r.student_id as sid, max(r.student_name) as sname, sum(r.qty * r.unit_cents)::bigint as cents
      from _td_run r
      join _td_units u on u.unit_key = r.unit_key and u.status = 'ready'
      join lessons l on l.id = r.lesson_id and l.org_id = p_org
     where r.state = 'line' and r.line_kind = 'lesson' and not coalesce(l.trial, false)
     group by r.unit_key, r.student_id
  )
  select st.id, st.name, st.household_id, fm.ukey, null::uuid,
         case v_mode when 'fixed' then 'fixed' else 'percent_first_month' end,
         case when v_mode = 'percent_first_month' then v_bp end,
         fm.cents,
         case v_mode when 'fixed' then v_fix when 'percent_first_month' then centre_div_round(fm.cents * v_bp, 10000) else 0 end,
         v_tax, false
    from fm join students st on st.id = fm.sid and st.org_id = p_org
   where v_mode in ('fixed', 'percent_first_month') and v_due = 'with_first_invoice'
     and not exists (select 1 from centre_deposits d where d.org_id = p_org and d.student_id = st.id)
     and not exists (select 1 from centre_invoice_lines cl join centre_invoices ci on ci.id = cl.invoice_id and ci.org_id = cl.org_id
                      where cl.org_id = p_org and cl.student_id = st.id and ci.kind in ('lesson', 'opening') and ci.status <> 'void' and ci.period_start <= p_ms)
     and case v_mode when 'fixed' then v_fix when 'percent_first_month' then centre_div_round(fm.cents * v_bp, 10000) else 0 end > 0
  union all
  select st.id, st.name, st.household_id, fm.ukey, d.id, d.mode, d.percent_bp, d.first_month_cents, d.required_cents, d.taxable, true
    from fm join students st on st.id = fm.sid and st.org_id = p_org
    join centre_deposits d on d.org_id = p_org and d.student_id = st.id and d.source = 'invoice_run'
   where d.invoice_id is null or exists (select 1 from centre_invoices i where i.id = d.invoice_id and i.org_id = p_org and i.status = 'void');
end $$;

create or replace function public.centre_deposit_status(p_org uuid, p_student uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := centre_deposit_gate(p_org, 'view'); res jsonb;
begin
  with led as (
    select l.student_id, coalesce(sum(l.cents) filter (where l.kind <> 'waived'), 0)::bigint as held,
           coalesce(sum(l.cents) filter (where l.kind = 'waived'), 0)::bigint as waived,
           coalesce(sum(l.cents) filter (where l.kind <> 'waived' and l.taxable), 0)::bigint as taxable_held
      from centre_deposit_ledger l where l.org_id = p_org group by l.student_id
  ), q as (
    select d.id as deposit_id, d.student_id, st.name, h.name as household_name, d.household_id, d.source, d.mode, d.percent_bp, d.first_month_cents,
           d.required_cents, coalesce(i.total_cents, d.required_cents) as due, d.taxable, d.period_start, i.id as invoice_id, i.number_text, i.status as istatus, i.issue_date, i.due_date,
           coalesce((select sum(c.total_cents) from centre_invoices c where c.credits_invoice_id = i.id and c.status = 'issued'), 0)::bigint as credited,
           coalesce(led.held, 0) as held, coalesce(led.waived, 0) as waived, coalesce(led.taxable_held, 0) as taxable_held
      from centre_deposits d
      join students st on st.id = d.student_id and st.org_id = d.org_id
      left join households h on h.id = d.household_id and h.org_id = d.org_id
      left join centre_invoices i on i.id = d.invoice_id and i.org_id = d.org_id
      left join led on led.student_id = d.student_id
     where d.org_id = p_org and (p_student is null or d.student_id = p_student)
  ), r as (
    select q.*, case when q.waived > 0 then 'waived' when q.istatus = 'draft' then 'draft' when q.held >= q.due - q.credited then 'held'
                     when q.held > 0 then 'part_paid' when q.istatus = 'void' then 'draft' else 'unpaid' end as state,
           case when q.waived > 0 or q.istatus in ('draft', 'void') then 0 else greatest(q.due - q.credited - q.held, 0) end as short
      from q
  )
  select jsonb_build_object('today', today,
    'rows', coalesce((select jsonb_agg(jsonb_build_object('deposit_id', r.deposit_id, 'student_id', r.student_id, 'name', r.name, 'household_id', r.household_id,
              'household_name', r.household_name, 'source', r.source, 'mode', r.mode, 'percent_bp', r.percent_bp, 'first_month_cents', r.first_month_cents,
              'required_cents', r.required_cents, 'due_cents', r.due, 'held_cents', r.held, 'waived_cents', r.waived, 'short_cents', r.short, 'state', r.state, 'taxable', r.taxable,
              'period_start', r.period_start, 'invoice_id', r.invoice_id, 'invoice_number', r.number_text, 'invoice_status', r.istatus, 'due_date', r.due_date)
              order by r.name, r.student_id) from r), '[]'::jsonb),
    'totals', jsonb_build_object('held_cents', coalesce((select sum(held) from r), 0), 'taxable_held_cents', coalesce((select sum(taxable_held) from r), 0),
              'students_holding', (select count(*) from r where held > 0), 'required_cents', coalesce((select sum(required_cents) from r where state <> 'waived'), 0),
              'short_cents', coalesce((select sum(short) from r), 0), 'deposits', (select count(*) from r)))
    into res;
  return res;
end $$;
