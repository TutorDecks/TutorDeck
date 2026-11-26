-- =====================================================================
-- TutorDeck — Supabase schema
-- Run this in the Supabase SQL editor (Dashboard → SQL → New query → Run).
-- Multi-tenant: every row is owned by a tutor (auth.uid()) and isolated by RLS.
-- Future-proofed: a `role` column + clean ownership means student/parent
-- read access later is a policy ADD, not a migration.
-- Weekday convention: 0 = Mon ... 6 = Sun  (matches the Mon–Sun planner).
-- =====================================================================

-- ---------- profiles: one row per auth user ----------
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  role        text not null default 'tutor' check (role in ('tutor','student','admin')),
  created_at  timestamptz not null default now()
);

-- ---------- students: a person, a sibling pair, or an org ----------
create table public.students (
  id          uuid primary key default gen_random_uuid(),
  tutor_id    uuid not null references auth.users(id) on delete cascade,
  name        text not null,                       -- e.g. 'Miya', 'Xavier/Jaylon', 'Mindflex'
  kind        text not null default 'individual'
                 check (kind in ('individual','pair','org')),
  level       text,                                -- e.g. 'Sec 3 G3', 'P6', 'JC1'
  contact     text,                                -- phone, for WhatsApp reminders
  notes       text,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------- recurring_slots: the weekly template (drives planner + projection) ----------
-- A student can have several slots (e.g. one Math, one Science) each with its own rate.
create table public.recurring_slots (
  id          uuid primary key default gen_random_uuid(),
  tutor_id    uuid not null references auth.users(id) on delete cascade,
  student_id  uuid not null references public.students(id) on delete cascade,
  weekday     int  not null check (weekday between 0 and 6),  -- 0=Mon … 6=Sun
  start_time  time not null,
  end_time    time not null,
  subject     text,
  rate        numeric(8,2) not null,               -- per hour
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------- lessons: the dated ledger (the heart of the app) ----------
-- amount is stored (not generated) so imported historical values are preserved exactly;
-- the app computes amount = rate * hours on insert/edit.
create table public.lessons (
  id          uuid primary key default gen_random_uuid(),
  tutor_id    uuid not null references auth.users(id) on delete cascade,
  student_id  uuid not null references public.students(id) on delete cascade,
  slot_id     uuid references public.recurring_slots(id) on delete set null,
  lesson_date date not null,
  start_time  time not null,
  end_time    time not null,
  subject     text,
  rate        numeric(8,2) not null,
  amount      numeric(10,2) not null default 0,
  status      text not null default 'done'
                 check (status in ('scheduled','done','cancelled')),
  paid        boolean not null default false,
  paid_date   date,
  topics      text,                                -- from your 'Student matters' notes
  homework    text,
  remarks     text,
  created_at  timestamptz not null default now()
);

-- ---------- exams: per-student, surfaced on the dashboard with a countdown ----------
create table public.exams (
  id          uuid primary key default gen_random_uuid(),
  tutor_id    uuid not null references auth.users(id) on delete cascade,
  student_id  uuid not null references public.students(id) on delete cascade,
  subject     text,
  exam_date   date,
  topics      text,
  remarks     text,
  created_at  timestamptz not null default now()
);

-- ---------- indexes ----------
create index on public.students        (tutor_id);
create index on public.recurring_slots (tutor_id);
create index on public.lessons         (tutor_id, lesson_date);
create index on public.lessons         (tutor_id, paid);
create index on public.exams           (tutor_id, exam_date);

-- =====================================================================
-- Row Level Security — a tutor sees ONLY their own rows
-- =====================================================================
alter table public.profiles        enable row level security;
alter table public.students        enable row level security;
alter table public.recurring_slots enable row level security;
alter table public.lessons         enable row level security;
alter table public.exams           enable row level security;

create policy "own profile" on public.profiles
  for all using (id = auth.uid()) with check (id = auth.uid());

create policy "tutor rw students" on public.students
  for all using (tutor_id = auth.uid()) with check (tutor_id = auth.uid());

create policy "tutor rw slots" on public.recurring_slots
  for all using (tutor_id = auth.uid()) with check (tutor_id = auth.uid());

create policy "tutor rw lessons" on public.lessons
  for all using (tutor_id = auth.uid()) with check (tutor_id = auth.uid());

create policy "tutor rw exams" on public.exams
  for all using (tutor_id = auth.uid()) with check (tutor_id = auth.uid());

-- =====================================================================
-- Auto-create a profile row whenever someone signs up
-- =====================================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, new.raw_user_meta_data->>'full_name');
  return new;
end; $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- =====================================================================
-- LATER (when students/parents log in) — no restructure needed, just:
--   alter table public.students add column student_user_id uuid references auth.users(id);
--   create policy "student reads own lessons" on public.lessons for select
--     using (student_id in (select id from public.students where student_user_id = auth.uid()));
-- =====================================================================
