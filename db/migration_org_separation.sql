-- T12a: keep centre data and solo data apart in the DATABASE (invisible safety net; no page changes).
-- Run order everywhere: org_foundation → billing → attendance → tutor_access → org_delete → function_lockdown → org_separation.
-- Undo: db/migration_org_separation_down.sql.  Safe to run twice.
--
-- WHAT ALREADY EXISTED (org_foundation): composite foreign keys (student_id, org_id) → students(id, org_id) on lessons,
-- recurring_slots, exams and invoices, and (slot_id, org_id) on lessons, so Postgres already refuses a row whose student is in
-- another organisation, but with a cryptic "violates foreign key constraint" message, and with NO check on the lesson ids an
-- invoice lists inside invoices.data.lesson_ids.
-- WHAT THIS ADDS: one trigger function, org_same_org_guard(), on lessons / recurring_slots / exams / invoices that
--   1. refuses a row whose student_id points at a student of a DIFFERENT organisation, with a plain message (and covers the case
--      where the foreign keys were ever dropped or not yet validated);
--   2. refuses a lesson whose slot_id points at a recurring slot of a different organisation;
--   3. refuses an invoice whose data.lesson_ids lists a lesson that exists in a different organisation (unknown / deleted
--      ids are ignored, exactly as the pages already treat them).
-- It fires AFTER org_row_guard (trigger names fire alphabetically: org_row_guard < org_same_org_guard), so org_id is already filled in.
-- Nothing is loosened: no policy changes, the centre read policy stays, solo tutors' rows are already in one organisation.
--
-- ---------------------------------------------------------------------------------------------------------------------
-- PREVIEW FOR LIVE (read-only SELECTs; run in the Supabase SQL editor BEFORE running this file; every number must be 0):
--
--   select 'lessons'         as tbl, count(*) from lessons l         join students s on s.id = l.student_id and s.org_id is distinct from l.org_id
--   union all select 'recurring_slots', count(*) from recurring_slots r join students s on s.id = r.student_id and s.org_id is distinct from r.org_id
--   union all select 'exams',           count(*) from exams e           join students s on s.id = e.student_id and s.org_id is distinct from e.org_id
--   union all select 'invoices',        count(*) from invoices i        join students s on s.id = i.student_id and s.org_id is distinct from i.org_id
--   union all select 'lessons→slot',    count(*) from lessons l         join recurring_slots r on r.id = l.slot_id and r.org_id is distinct from l.org_id
--   union all select 'invoice lesson_ids', count(*) from invoices i
--             cross join lateral jsonb_array_elements_text(case when jsonb_typeof(i.data->'lesson_ids') = 'array' then i.data->'lesson_ids' else '[]'::jsonb end) x(id)
--             join lessons l on l.id::text = x.id and l.org_id is distinct from i.org_id;
--
-- (On live today the first five are 0 by construction: the foreign keys forbid them. The last one is the only one that could be > 0.
--  If it is, send me the invoice numbers; the migration still runs because it only checks rows as they are written from now on.)
-- ---------------------------------------------------------------------------------------------------------------------

create or replace function public.org_same_org_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare n jsonb := to_jsonb(new); o jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) end; bad int;
        stu uuid := nullif(n->>'student_id', '')::uuid; slot uuid := nullif(n->>'slot_id', '')::uuid;
begin
  -- (fields are read through jsonb because not every table has every column)
  -- 1. the student must be in this row's organisation
  if stu is not null and (o is null or n->>'student_id' is distinct from o->>'student_id' or n->>'org_id' is distinct from o->>'org_id') then
    if not exists (select 1 from students s where s.id = stu and s.org_id = new.org_id) then
      raise exception 'That student belongs to a different organisation' using errcode = '42501';
    end if;
  end if;
  -- 2. a lesson's weekly slot must be in the lesson's organisation
  if slot is not null and (o is null or n->>'slot_id' is distinct from o->>'slot_id' or n->>'org_id' is distinct from o->>'org_id') then
    if not exists (select 1 from recurring_slots r where r.id = slot and r.org_id = new.org_id) then
      raise exception 'That weekly slot belongs to a different organisation' using errcode = '42501';
    end if;
  end if;
  -- 3. an invoice may only list lessons of its own organisation (ids that don't exist are ignored)
  if tg_table_name = 'invoices' and jsonb_typeof(n->'data'->'lesson_ids') = 'array'
     and (o is null or n->'data'->'lesson_ids' is distinct from o->'data'->'lesson_ids' or n->>'org_id' is distinct from o->>'org_id') then
    select count(*) into bad
      from jsonb_array_elements_text(n->'data'->'lesson_ids') x(id)
      join lessons l on l.id::text = x.id
     where l.org_id is distinct from new.org_id;
    if bad > 0 then raise exception 'That invoice lists lessons of a different organisation' using errcode = '42501'; end if;
  end if;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['lessons','recurring_slots','exams','invoices'] loop
    execute format('drop trigger if exists org_same_org_guard on public.%I', t);
    execute format('create trigger org_same_org_guard before insert or update on public.%I for each row execute function public.org_same_org_guard()', t);
  end loop;
end $$;

-- a trigger function is not an API (same lockdown as the other trigger functions)
revoke all on function public.org_same_org_guard() from public, anon, authenticated;
