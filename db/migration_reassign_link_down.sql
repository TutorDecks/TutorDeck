-- Undo for migration_reassign_link.sql: puts back the earlier staff_reassign_lesson (the old tutor's link always ends when the choice is ticked).
create or replace function public.staff_reassign_lesson(p_lesson uuid, p_new_tutor uuid, p_mode text, p_reason text default null,
                                                        p_update_links boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l lessons; cl lessons; today date; md text := lower(trim(coalesce(p_mode, ''))); why text := nullif(trim(coalesce(p_reason, '')), '');
        nt memberships; cfg jsonb; allowed boolean; ids uuid[]; locked text; orig uuid; new_cf uuid; old_tutor uuid;
        sid uuid; ended int := 0; added int := 0; n_ended int; before_j jsonb := '[]'::jsonb; link_ids uuid[];
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into l from lessons where id = p_lesson;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := staff_slots_gate(l.org_id, true);                                            -- NOT_FOUND for strangers, NOT_ALLOWED without manage_timetable

  if md not in ('reassign', 'cover') then raise exception 'BAD_MODE: choose cover or reassign' using errcode = 'P0001'; end if;
  if p_new_tutor is null then raise exception 'PICK_TUTOR: choose who will teach this lesson' using errcode = 'P0001'; end if;
  if why is not null and length(why) > 500 then raise exception 'TOO_LONG: keep the reason under 500 characters' using errcode = 'P0001'; end if;
  if coalesce(p_update_links, false) and md = 'cover' then
    raise exception 'LINK_NOT_FOR_COVER: a cover is one lesson only, so it never changes who a student is assigned to' using errcode = 'P0001'; end if;

  select * into nt from memberships m where m.id = p_new_tutor and m.org_id = l.org_id and m.role in ('tutor', 'staff', 'owner') and m.status = 'active';
  if not found then raise exception 'NOT_AVAILABLE: that person can''t be given lessons at this centre (they must be an active member here)' using errcode = 'P0001'; end if;
  if l.taught_by is not distinct from p_new_tutor then
    raise exception 'NO_CHANGE: that tutor already teaches this lesson' using errcode = 'P0001'; end if;

  if l.taught_by is null then
    if md = 'cover' then raise exception 'NO_TUTOR_TO_COVER: this lesson has no tutor yet, so there is nobody to cover for. Use Assign instead' using errcode = 'P0001'; end if;
  else
    -- a lesson that already has a tutor changing hands is a replacement: the centre's own rule decides (read as of today)
    cfg := org_settings_on(l.org_id, today) #> '{lessons,replacement_tutors}';
    allowed := case when jsonb_typeof(cfg) = 'boolean' then (cfg #>> '{}')::boolean else true end;      -- missing = on (the default)
    if not allowed then
      raise exception 'REPLACEMENT_OFF: this centre doesn''t allow replacement tutors. An owner can switch this on in the centre settings' using errcode = 'P0001'; end if;
    if why is null then raise exception 'REASON_REQUIRED: say why this lesson is changing tutor. It is kept on record' using errcode = 'P0001'; end if;
  end if;

  -- the lesson, or the whole class of that day (lessons sharing a session_id): all or nothing
  select coalesce(array_agg(x.id order by x.id), array[l.id]) into ids from lessons x
   where x.org_id = l.org_id and (x.id = l.id or (l.session_id is not null and x.session_id = l.session_id));
  perform 1 from lessons x where x.id = any(ids) order by x.id for update;
  foreach sid in array ids loop
    locked := lesson_locked_reason(sid);
    if locked is not null then
      raise exception '%', case locked
        when 'MARKED'    then 'ALREADY_MARKED: this lesson is already marked, so it stays with the tutor who taught it'
        when 'CANCELLED' then 'CANCELLED: this lesson was cancelled'
        when 'PAID'      then 'PAID: this lesson is already paid, so it can''t change hands'
        else                  'INVOICED: this lesson is on an invoice, so it can''t change hands' end
        || case when array_length(ids, 1) > 1 then ' (it is part of a class that moves together)' else '' end using errcode = 'P0001';
    end if;
  end loop;

  -- move them
  for cl in select * from lessons x where x.id = any(ids) order by x.id loop
    before_j := before_j || jsonb_build_object('lesson_id', cl.id, 'taught_by', cl.taught_by, 'covered_for', cl.covered_for);
    if md = 'cover' then
      orig := coalesce(cl.covered_for, cl.taught_by);                                    -- who it was meant for stays the same however often it is covered
      new_cf := case when orig is distinct from p_new_tutor then orig end;              -- handed back to the original tutor = nobody is covering
    else new_cf := null; end if;
    update lessons set taught_by = p_new_tutor, covered_for = new_cf where id = cl.id;
  end loop;

  -- reassign only, and only when asked: the student's assigned-tutor link follows (the old tutor's ends, the new tutor's starts)
  if coalesce(p_update_links, false) then
    for sid in select distinct x.student_id from lessons x where x.id = any(ids) loop
      old_tutor := (select (e ->> 'taught_by')::uuid from jsonb_array_elements(before_j) e
                     join lessons y on y.id = (e ->> 'lesson_id')::uuid where y.student_id = sid limit 1);
      if old_tutor is not null then
        update student_tutors set active = false, until = today where org_id = l.org_id and student_id = sid and membership_id = old_tutor and active;
        get diagnostics n_ended = row_count; ended := ended + n_ended;
      end if;
      if not exists (select 1 from student_tutors x where x.org_id = l.org_id and x.student_id = sid and x.membership_id = p_new_tutor and x.active) then
        insert into student_tutors(org_id, student_id, membership_id, since, created_by) values (l.org_id, sid, p_new_tutor, today, auth.uid());
        added := added + 1;
      end if;
    end loop;
  end if;

  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (l.org_id, auth.uid(), 'staff_reassign_lesson', 'lessons', l.id::text,
          jsonb_build_object('lessons', before_j),
          jsonb_build_object('mode', md, 'new_tutor', p_new_tutor, 'new_tutor_name', nt.display_name, 'lessons', to_jsonb(ids), 'reason', why,
                             'covered_for', (select covered_for from lessons where id = l.id),
                             'links_updated', coalesce(p_update_links, false), 'links_ended', ended, 'links_added', added));
  return jsonb_build_object('lesson_id', l.id, 'lessons', array_length(ids, 1), 'mode', md, 'tutor_id', p_new_tutor,
                            'tutor_name', coalesce(nt.display_name, 'Tutor'), 'covered_for', (select covered_for from lessons where id = l.id),
                            'links_ended', ended, 'links_added', added);
end $$;

revoke all on function public.staff_reassign_lesson(uuid, uuid, text, text, boolean) from public, anon;
grant execute on function public.staff_reassign_lesson(uuid, uuid, text, text, boolean) to authenticated;
