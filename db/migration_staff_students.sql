-- =====================================================================================================
-- T3 step 2 — centre Students and households (view + edit): five functions                 undo: migration_staff_students_down.sql
-- =====================================================================================================
-- Needs migration_org_foundation.sql (students.org_id / household_id, households, guardians, audit_row), migration_tutor_access.sql
-- (lessons.taught_by, trial) and migration_staff_home.sql only for the page. ADD-ONLY: five new functions, no table or column is touched.
--
-- WHAT IT IS: the centre's staff screen for students is just these functions. The page never writes a table; every rule is here, so it
-- holds for any caller (the page, a script, someone with their own copy of the app):
--   staff_students(org, q, filter, page, size)       the list: server-side search + paging (a centre can have 400+ students)
--   staff_student(org, student)                      one student's sheet: details, family + guardians (phone, email), subjects, next lessons
--   staff_save_student(org, student, name, level, notes, household, household_name, guardians)
--                                                    add (student = null, creates the household and its guardians in ONE step) or edit
--   staff_set_student_end(org, student, date)        "lessons run until" (same meaning as for solo tutors); date = null brings them back
--
-- WHO MAY CALL (decided for T3.1, 2026-11-25): an active OWNER or STAFF member of this CENTRE with the manage_students permission (owners
-- always). Nothing else:
--   not a member / a tutor / a parent / switched-off staff / a solo organisation / an unknown id  → NOT_FOUND (same words for all, so ids can't be probed)
--   staff of this centre WITHOUT manage_students (e.g. timetable-only)                           → NOT_ALLOWED
-- Centre tutors still have NO table access at all (CLAUDE.md): they never read students, households or guardians, and still see a parent's
-- contact only through tutor_my_lessons, and only when the centre switched on lessons.tutors_see_parent_contact (default off).
--
-- WHAT STAYS FIXED (integrity, not process): students belong to the CENTRE (org_id) and never to a solo organisation; a household, a guardian
-- or a student id from ANOTHER organisation is treated as "doesn't exist"; every write is validated here and leaves an audit_log row (the
-- generic row triggers on students / households / guardians record before + after, and each function adds one named summary entry).
-- NOTHING here needs a class, a room or a branch: a remote 1-to-1 centre adds a student with just a name and a parent's phone or email.
--
-- DATA-MODEL CHOICES (plain words):
--   * A HOUSEHOLD is the family (your "household id" sheet); GUARDIANS are the family's contacts (name, relation, phone, email). Siblings share one
--     household, so a phone number is edited once for all of them.
--   * students.tutor_id is NOT NULL and cascades on delete of that login. A centre's students must not disappear when a staff member's login is
--     removed, so a new student is filed under the centre OWNER's login (the organisation itself goes with the owner anyway).
--   * The MAIN contact of a family is its first guardian (the one added first; the list keeps the order they were typed in).
--   * students.contact and students.recipient_name are the older single-parent fields that tutor_my_lessons / messages / invoices read. They are
--     kept equal to the household's FIRST guardian, so those readers keep working (and a tutor sees the number only if the centre allows it).
--   * Discontinuing = students.end_date ("lessons run until", inclusive), exactly as for solo tutors: after it the student counts as
--     discontinued everywhere (staff_home, the list). Like the solo page it also switches the student's weekly slots off once the date has
--     passed, and back on when the student is brought back. Lessons already made are left alone.
--   * Trial is shown read-only here (a trial lesson in the last 30 days, in the centre's own timezone); flagging a trial is T3 step 5.
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

-- ---------------------------------------------------------------- the gate every function starts with (internal; not callable from the browser)
create or replace function public.staff_students_gate(p_org uuid) returns date
language plpgsql stable security definer set search_path = public as $$
declare tz text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select o.timezone into tz from organisations o where o.id = p_org and o.kind = 'centre';
  if tz is null or not exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active'
                               and m.role in ('owner', 'staff')) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if not org_can(p_org, 'manage_students') then
    raise exception 'NOT_ALLOWED: your account can''t manage students at this centre' using errcode = '42501';
  end if;
  return (now() at time zone tz)::date;                       -- the centre's own today
end $$;

-- ---------------------------------------------------------------- contacts: one place that validates and tidies a guardian
create or replace function public.staff_clean_guardian(g jsonb) returns jsonb
language plpgsql immutable set search_path = public as $$
declare nm text; rel text; ph text; em text; digits int;
begin
  if jsonb_typeof(g) is distinct from 'object' then raise exception 'BAD_GUARDIAN: a guardian must be an object' using errcode = 'P0001'; end if;
  nm  := nullif(trim(coalesce(g->>'name', '')), '');
  rel := nullif(trim(coalesce(g->>'relation', '')), '');
  ph  := nullif(trim(coalesce(g->>'phone', '')), '');
  em  := nullif(lower(trim(coalesce(g->>'email', ''))), '');
  if nm is null then raise exception 'BAD_GUARDIAN: give each parent or guardian a name' using errcode = 'P0001'; end if;
  if length(nm) > 120 then raise exception 'BAD_GUARDIAN: a guardian''s name is too long (120 characters at most)' using errcode = 'P0001'; end if;
  if rel is not null and length(rel) > 40 then raise exception 'BAD_GUARDIAN: the relation is too long (40 characters at most)' using errcode = 'P0001'; end if;
  if ph is null and em is null then
    raise exception 'BAD_GUARDIAN: give % a phone number or an email, so the centre can reach the family', nm using errcode = 'P0001'; end if;
  if ph is not null then
    digits := length(regexp_replace(ph, '\D', '', 'g'));
    if ph !~ '^[0-9+()\s-]{6,30}$' or digits < 6 or digits > 15 then
      raise exception 'BAD_GUARDIAN: that phone number doesn''t look right (%)', ph using errcode = 'P0001'; end if;
  end if;
  if em is not null and (length(em) > 254 or em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then
    raise exception 'BAD_GUARDIAN: that email address doesn''t look right (%)', em using errcode = 'P0001'; end if;
  return jsonb_build_object('id', nullif(g->>'id', ''), 'name', nm, 'relation', rel, 'phone', ph, 'email', em);
end $$;

-- ---------------------------------------------------------------- 1. the list
-- p_filter: 'active' (default) | 'ended' | 'trial' (a trial lesson in the last 30 days) | 'all'.  p_q searches the student's name and level, the
-- family's name, and every guardian's name, email and phone (digits only: "9123" finds "+65 9123 4567").  Counts come back for every filter
-- (for the current search) so the tabs can show them.  Names and phone numbers only: never money.
create or replace function public.staff_students(p_org uuid, p_q text default null, p_filter text default 'active', p_page int default 1, p_size int default 25)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare today date := staff_students_gate(p_org); q text := nullif(trim(coalesce(p_q, '')), ''); pat text; dig text; pg int; sz int;
        res jsonb; flt text := coalesce(p_filter, 'active');
begin
  if flt not in ('active', 'ended', 'trial', 'all') then raise exception 'BAD_FILTER: unknown filter' using errcode = 'P0001'; end if;
  if q is not null and length(q) > 100 then raise exception 'BAD_SEARCH: search for at most 100 characters' using errcode = 'P0001'; end if;
  sz := least(greatest(coalesce(p_size, 25), 1), 100);
  pg := greatest(coalesce(p_page, 1), 1);
  if q is not null then
    pat := '%' || replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
    dig := nullif(regexp_replace(q, '\D', '', 'g'), '');
    -- the digits-only match is for something that LOOKS like a phone number (digits, spaces, + - and brackets, at least 3 digits); "Sec 2" is not one
    if q !~ '^[0-9+()\s-]+$' or length(coalesce(dig, '')) < 3 then dig := null; end if;
  end if;
  with matched as (
    select s.id, s.name, s.level, s.end_date, s.household_id, h.name as hname,
           (s.end_date is not null and s.end_date < today) as ended,
           exists (select 1 from lessons l where l.org_id = p_org and l.student_id = s.id and l.trial and l.lesson_date >= today - 30) as trial,
           (select count(*) from guardians gc where gc.org_id = p_org and gc.household_id = s.household_id) as gcount,
           g.name as gname, g.phone as gphone
      from students s
      left join households h on h.id = s.household_id and h.org_id = p_org
      left join lateral (select x.name, x.phone from guardians x where x.org_id = p_org and x.household_id = s.household_id order by x.created_at, x.id limit 1) g on true
     where s.org_id = p_org
       and (q is null or s.name ilike pat or s.level ilike pat or h.name ilike pat
            or exists (select 1 from guardians gg where gg.org_id = p_org and gg.household_id = s.household_id
                         and (gg.name ilike pat or gg.email ilike pat or gg.phone ilike pat
                              or (dig is not null and regexp_replace(coalesce(gg.phone, ''), '\D', '', 'g') like '%' || dig || '%'))))),
  shown as (
    select * from matched m where case flt when 'active' then not m.ended when 'ended' then m.ended when 'trial' then m.trial else true end),
  page as (select * from shown order by lower(name), id limit sz offset (pg - 1) * sz)
  select jsonb_build_object(
    'org_id', p_org, 'today', today, 'filter', flt, 'page', pg, 'size', sz,
    'total', (select count(*) from shown),
    'counts', jsonb_build_object('active', (select count(*) from matched where not ended), 'ended', (select count(*) from matched where ended),
                                 'trial', (select count(*) from matched where trial), 'all', (select count(*) from matched)),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'level', p.level, 'end_date', p.end_date, 'ended', p.ended,
                       'trial', p.trial, 'household_id', p.household_id, 'household_name', p.hname,
                       'guardian_name', p.gname, 'guardian_phone', p.gphone, 'guardians', p.gcount) order by lower(p.name), p.id) from page p), '[]'::jsonb))
    into res;
  return res;
end $$;

-- ---------------------------------------------------------------- 2. one student's sheet
create or replace function public.staff_student(p_org uuid, p_student uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_students_gate(p_org); s students; hh households; res jsonb;
begin
  select * into s from students where id = p_student and org_id = p_org;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into hh from households where id = s.household_id and org_id = p_org;
  select jsonb_build_object(
    'id', s.id, 'org_id', p_org, 'name', s.name, 'level', s.level, 'notes', s.notes, 'end_date', s.end_date,
    'ended', (s.end_date is not null and s.end_date < today), 'created_at', s.created_at, 'today', today,
    'household', case when hh.id is null then null else jsonb_build_object('id', hh.id, 'name', hh.name) end,
    'guardians', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'relation', g.relation, 'phone', g.phone, 'email', g.email)
                                            order by g.created_at, g.id) from guardians g where g.org_id = p_org and g.household_id = s.household_id), '[]'::jsonb),
    'siblings', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'level', x.level,
                                            'ended', (x.end_date is not null and x.end_date < today)) order by lower(x.name), x.id)
                            from students x where x.org_id = p_org and x.household_id = s.household_id and x.id <> s.id), '[]'::jsonb),
    -- the subjects they are taught: what the data model has (a subject lives on the lesson and on the weekly slot, not on the student)
    'subjects', coalesce((select jsonb_agg(sj order by sj) from (
                            select distinct l.subject as sj from lessons l where l.org_id = p_org and l.student_id = s.id and nullif(trim(l.subject), '') is not null
                            union select distinct r.subject from recurring_slots r where r.org_id = p_org and r.student_id = s.id and nullif(trim(r.subject), '') is not null) u), '[]'::jsonb),
    'lessons_total', (select count(*) from lessons l where l.org_id = p_org and l.student_id = s.id),
    'lessons_trial', (select count(*) from lessons l where l.org_id = p_org and l.student_id = s.id and l.trial),
    'trial', exists (select 1 from lessons l where l.org_id = p_org and l.student_id = s.id and l.trial and l.lesson_date >= today - 30),
    -- when and who only; no price, no payment
    'next_lessons', coalesce((select jsonb_agg(jsonb_build_object('date', n.lesson_date, 'start', n.start_time, 'end', n.end_time, 'subject', n.subject,
                                            'tutor', n.tutor) order by n.lesson_date, n.start_time)
                                from (select l.lesson_date, l.start_time, l.end_time, l.subject, m.display_name as tutor
                                        from lessons l left join memberships m on m.id = l.taught_by and m.org_id = l.org_id
                                       where l.org_id = p_org and l.student_id = s.id and l.lesson_date >= today and l.status <> 'cancelled'
                                       order by l.lesson_date, l.start_time limit 5) n), '[]'::jsonb))
    into res;
  return res;
end $$;

-- ---------------------------------------------------------------- 3. add or edit (one atomic step)
-- p_student null = ADD, otherwise EDIT that student.
-- p_household: ADD only. null = a new household (the family) is created, and p_guardians (at least one) are its contacts. A household id = add a
--   sibling to that existing family (p_guardians then optional: null leaves the family's contacts as they are).  Editing never moves a student
--   to another household (merging families is out of scope).
-- p_guardians: a json array of {id?, name, relation, phone, email}. null = leave the family's contacts untouched. Otherwise it is the COMPLETE new
--   list for the household: entries with an id are updated, entries without one are added, and contacts not in the list are removed.
--   (A contact someone has linked to a parent-portal login can't be removed here.) Each needs a name and a phone or an email; at most 6.
-- p_household_name: the family's name; blank = "<student's name>'s family" for a new household, unchanged when editing.
-- Returns {student_id, household_id, created}.
create or replace function public.staff_save_student(p_org uuid, p_student uuid, p_name text, p_level text default null, p_notes text default null,
  p_household uuid default null, p_household_name text default null, p_guardians jsonb default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := staff_students_gate(p_org); s students; hid uuid; nm text := nullif(trim(coalesce(p_name, '')), ''); lv text := nullif(trim(coalesce(p_level, '')), '');
        nt text := nullif(trim(coalesce(p_notes, '')), ''); hn text := nullif(trim(coalesce(p_household_name, '')), ''); owner_uid uuid; created boolean := false;
        clean jsonb := '[]'::jsonb; gj jsonb; c jsonb; gid uuid; first_g record;
begin
  -- ---- validate everything before changing anything
  if nm is null then raise exception 'BAD_STUDENT: give the student a name' using errcode = 'P0001'; end if;
  if length(nm) > 120 then raise exception 'BAD_STUDENT: the name is too long (120 characters at most)' using errcode = 'P0001'; end if;
  if lv is not null and length(lv) > 40 then raise exception 'BAD_STUDENT: the level is too long (40 characters at most)' using errcode = 'P0001'; end if;
  if nt is not null and length(nt) > 1000 then raise exception 'BAD_STUDENT: the notes are too long (1000 characters at most)' using errcode = 'P0001'; end if;
  if hn is not null and length(hn) > 120 then raise exception 'BAD_STUDENT: the family name is too long (120 characters at most)' using errcode = 'P0001'; end if;
  if p_guardians is not null then
    if jsonb_typeof(p_guardians) <> 'array' then raise exception 'BAD_GUARDIAN: guardians must be a list' using errcode = 'P0001'; end if;
    if jsonb_array_length(p_guardians) > 6 then raise exception 'BAD_GUARDIAN: at most 6 parents or guardians per family' using errcode = 'P0001'; end if;
    if jsonb_array_length(p_guardians) = 0 then raise exception 'BAD_GUARDIAN: a family needs at least one parent or guardian to contact' using errcode = 'P0001'; end if;
    for gj in select * from jsonb_array_elements(p_guardians) loop clean := clean || jsonb_build_array(staff_clean_guardian(gj)); end loop;
  end if;

  if p_student is null then                                                      -- ===================== ADD
    if p_household is null then
      if p_guardians is null then
        raise exception 'BAD_GUARDIAN: add a parent or guardian with a phone number or an email, so the centre can reach the family' using errcode = 'P0001'; end if;
    else
      if not exists (select 1 from households h where h.id = p_household and h.org_id = p_org) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
      if exists (select 1 from students x where x.org_id = p_org and x.household_id = p_household and lower(x.name) = lower(nm)) then
        raise exception 'DUPLICATE: % is already in this family', nm using errcode = 'P0001'; end if;
    end if;
    -- filed under the centre owner's login (see the header); the row guard needs them to be in this organisation, which an owner always is
    select m.user_id into owner_uid from memberships m where m.org_id = p_org and m.role = 'owner' and m.status = 'active' and m.user_id is not null
      order by m.created_at limit 1;
    if owner_uid is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    hid := p_household;
    if hid is null then
      insert into households(org_id, name) values (p_org, coalesce(hn, nm || '''s family')) returning id into hid;
    elsif hn is not null then
      update households set name = hn where id = hid and name is distinct from hn;
    end if;
    insert into students(tutor_id, org_id, household_id, name, level, notes) values (owner_uid, p_org, hid, nm, lv, nt) returning * into s;
    created := true;
  else                                                                           -- ===================== EDIT
    select * into s from students where id = p_student and org_id = p_org;
    if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    if p_household is not null and p_household is distinct from s.household_id then
      raise exception 'BAD_STUDENT: moving a student to another family isn''t supported yet' using errcode = 'P0001'; end if;
    hid := s.household_id;
    if hid is null then                                                          -- an older student with no family yet: make one
      insert into households(org_id, name) values (p_org, coalesce(hn, nm || '''s family')) returning id into hid;
    elsif hn is not null then
      update households set name = hn where id = hid and org_id = p_org and name is distinct from hn;
    end if;
    update students set name = nm, level = lv, notes = nt, household_id = hid where id = s.id;
  end if;

  -- ---- the family's contacts
  if p_guardians is not null then
    -- every id must be one of THIS family's contacts (an id from somewhere else is "doesn't exist")
    for c in select * from jsonb_array_elements(clean) loop
      if c->>'id' is not null then
        begin gid := (c->>'id')::uuid; exception when others then raise exception 'NOT_FOUND' using errcode = 'P0001'; end;
        if not exists (select 1 from guardians g where g.id = gid and g.org_id = p_org and g.household_id = hid) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
      end if;
    end loop;
    -- contacts left out of the list are removed, unless a parent-portal login is linked to them
    if exists (select 1 from guardians g where g.org_id = p_org and g.household_id = hid and g.user_id is not null
                 and g.id::text not in (select x->>'id' from jsonb_array_elements(clean) x where x->>'id' is not null)) then
      raise exception 'BAD_GUARDIAN: a contact with a parent login can''t be removed here' using errcode = 'P0001'; end if;
    delete from guardians g where g.org_id = p_org and g.household_id = hid
       and g.id::text not in (select x->>'id' from jsonb_array_elements(clean) x where x->>'id' is not null);
    for c in select * from jsonb_array_elements(clean) loop
      if c->>'id' is not null then
        update guardians set name = c->>'name', relation = c->>'relation', phone = c->>'phone', email = c->>'email' where id = (c->>'id')::uuid;
      else
        insert into guardians(org_id, household_id, name, relation, phone, email, created_at)      -- (clock_timestamp: contacts added in one call keep their order)
        values (p_org, hid, c->>'name', c->>'relation', c->>'phone', c->>'email', clock_timestamp());
      end if;
    end loop;
  end if;

  -- ---- keep the older single-parent fields equal to the family's first contact (what tutor_my_lessons, messages and invoices still read)
  select g.name, g.phone into first_g from guardians g where g.org_id = p_org and g.household_id = hid order by g.created_at, g.id limit 1;
  update households set phone_key = org_phone_key(first_g.phone) where id = hid and phone_key is distinct from org_phone_key(first_g.phone);
  update students set contact = first_g.phone, recipient_name = first_g.name
   where org_id = p_org and household_id = hid and (contact is distinct from first_g.phone or recipient_name is distinct from first_g.name);

  insert into audit_log(org_id, actor, action, table_name, row_id, after)
  values (p_org, auth.uid(), case when created then 'staff_student_add' else 'staff_student_edit' end, 'students', s.id::text,
          jsonb_build_object('name', nm, 'level', lv, 'household_id', hid, 'guardians_replaced', p_guardians is not null));
  return jsonb_build_object('student_id', s.id, 'household_id', hid, 'created', created);
end $$;

-- ---------------------------------------------------------------- 4. discontinue / bring back
-- p_end_date = "lessons run until" (inclusive), today or earlier or later, between 2000 and 2100. null = bring the student back (clears the date).
-- Once the date has passed the student's weekly slots are switched off; bringing them back (or a date still to come) switches them on. Lessons stay.
create or replace function public.staff_set_student_end(p_org uuid, p_student uuid, p_end_date date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := staff_students_gate(p_org); s students; ended boolean;
begin
  select * into s from students where id = p_student and org_id = p_org;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_end_date is not null and (p_end_date < date '2000-01-01' or p_end_date > date '2100-01-01') then
    raise exception 'BAD_DATE: pick a sensible date' using errcode = 'P0001'; end if;
  ended := p_end_date is not null and p_end_date < today;
  update students set end_date = p_end_date, active = not ended where id = s.id;
  update recurring_slots set active = not ended where org_id = p_org and student_id = s.id and active = ended;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), case when p_end_date is null then 'staff_student_reactivate' else 'staff_student_end' end, 'students', s.id::text,
          jsonb_build_object('end_date', s.end_date), jsonb_build_object('end_date', p_end_date));
  return jsonb_build_object('student_id', s.id, 'end_date', p_end_date, 'ended', ended);
end $$;

-- ---------------------------------------------------------------- who may call what
-- The four screens' functions: signed-in users only (each one checks the person itself). The gate and the contact cleaner are internal.
revoke all on function public.staff_students(uuid, text, text, int, int) from public, anon;
revoke all on function public.staff_student(uuid, uuid) from public, anon;
revoke all on function public.staff_save_student(uuid, uuid, text, text, text, uuid, text, jsonb) from public, anon;
revoke all on function public.staff_set_student_end(uuid, uuid, date) from public, anon;
grant execute on function public.staff_students(uuid, text, text, int, int) to authenticated;
grant execute on function public.staff_student(uuid, uuid) to authenticated;
grant execute on function public.staff_save_student(uuid, uuid, text, text, text, uuid, text, jsonb) to authenticated;
grant execute on function public.staff_set_student_end(uuid, uuid, date) to authenticated;
revoke all on function public.staff_students_gate(uuid) from public, anon, authenticated;
revoke all on function public.staff_clean_guardian(jsonb) from public, anon, authenticated;
