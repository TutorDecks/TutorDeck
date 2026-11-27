-- Undo of migration_b5_fix.sql: puts back the original deposit candidates, slot functions and tutor-changes list. Run the undo chain in reverse order.
drop function if exists public.centre_deposit_run_why(uuid, date);
drop function if exists public.staff_save_slot(uuid, uuid, uuid[], int, time, time, uuid, text, numeric);
drop function if exists public.staff_slot_student(uuid, uuid, uuid, text, date, boolean);
do $$ begin
  if to_regprocedure('public.staff_save_slot_core(uuid,uuid,uuid[],integer,time without time zone,time without time zone,uuid,text,numeric)') is not null then
    alter function public.staff_save_slot_core(uuid, uuid, uuid[], int, time, time, uuid, text, numeric) rename to staff_save_slot;
  end if;
  if to_regprocedure('public.staff_slot_student_core(uuid,uuid,uuid,text,date,boolean)') is not null then
    alter function public.staff_slot_student_core(uuid, uuid, uuid, text, date, boolean) rename to staff_slot_student;
  end if;
end $$;
grant execute on function public.staff_save_slot(uuid, uuid, uuid[], int, time, time, uuid, text, numeric) to authenticated;
grant execute on function public.staff_slot_student(uuid, uuid, uuid, text, date, boolean) to authenticated;
-- the originals of the two functions that were replaced in place
create or replace function public.centre_deposit_run_candidates(p_org uuid, p_ms date, p_today date)
returns table(d_student_id uuid, d_student_name text, d_household_id uuid, d_unit_key text, d_deposit_id uuid, d_mode text, d_percent_bp int,
              d_first_month_cents bigint, d_amount_cents bigint, d_taxable boolean, d_frozen boolean)
language plpgsql security definer set search_path = public, pg_temp as $$
declare s jsonb := coalesce(org_settings_on(p_org, p_ms), org_settings_on(p_org, p_today)); me date := (p_ms + interval '1 month - 1 day')::date;
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

create or replace function public.staff_tutor_changes(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_attendance_gate(p_org, false); rows jsonb; tell boolean;
begin
  if not org_can(p_org, 'manage_timetable') then
    raise exception 'NOT_ALLOWED: your account can''t see timetable changes at this centre' using errcode = '42501'; end if;
  tell := coalesce(org_settings_on(p_org, today) #>> '{lessons,notify_family}', 'list_for_admin') = 'list_for_admin';
  select coalesce(jsonb_agg(jsonb_build_object(
           'lesson_id', x.id, 'what', x.changed_by_tutor_what, 'changed_at', x.changed_by_tutor_at, 'reason', x.changed_by_tutor_reason,
           'tutor_id', x.changed_by_tutor,
           'tutor_name', case when t.id is null or t.status = 'disabled' then 'Former tutor' else coalesce(t.display_name, 'Tutor') end,
           'student_id', s.id, 'student_name', s.name, 'subject', x.subject,
           'lesson_date', x.lesson_date, 'start_time', x.start_time, 'end_time', x.end_time,
           'from_date', x.changed_from_date, 'from_start', x.changed_from_start, 'cancelled', (x.status = 'cancelled'), 'tell_family', tell)
           order by x.changed_by_tutor_at desc, x.id), '[]'::jsonb)
    into rows
    from (select * from lessons y where y.org_id = p_org and y.changed_by_tutor_at >= now() - interval '7 days'
           order by y.changed_by_tutor_at desc, y.id limit 100) x
    join students s on s.id = x.student_id and s.org_id = x.org_id
    left join memberships t on t.id = x.changed_by_tutor and t.org_id = x.org_id;
  return jsonb_build_object('today', today, 'days', 7, 'tell_family', tell, 'rows', rows);
end $$;