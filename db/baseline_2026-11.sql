-- =====================================================================================================
-- Baseline: the LIVE TutorDeck schema as of 2026-11-23 (structure only, no data), rebuilt from the live
-- catalog. db/schema.sql is stale; this is what the dev project and the local tests start from.
-- Not included: public.public_schedule() (hard-coded to one account; only the landing page uses it)
-- and the rls_auto_enable event trigger (Supabase project setting).
-- =====================================================================================================

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  role text not null default 'tutor' check (role in ('tutor','student','admin')),
  created_at timestamptz not null default now(),
  business_name text,
  paynow_type text check (paynow_type in ('mobile','uen')),
  paynow_id text,
  invoice_prefix text default 'INV',
  reminder_message text,
  invoice_message text,
  fy_start_month integer not null default 1,
  bank_account_name text,
  bank_name text,
  bank_account_no text,
  bank_swift text,
  welcomed_at timestamptz,
  reminder_checked_at timestamptz,
  getpaid_dismissed_at timestamptz
);

create table if not exists public.students (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  kind text not null default 'individual' check (kind in ('individual','pair','org')),
  level text,
  contact text,
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  recipient_name text,
  household text,
  location text,
  pay_by_bank boolean not null default false,
  end_date date
);
create index if not exists students_tutor_id_idx on public.students (tutor_id);

create table if not exists public.recurring_slots (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references auth.users(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  weekday integer not null check (weekday >= 0 and weekday <= 6),
  start_time time not null,
  end_time time not null,
  subject text,
  rate numeric(8,2) not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  level text,
  split integer not null default 1
);
create index if not exists recurring_slots_tutor_id_idx on public.recurring_slots (tutor_id);

create table if not exists public.lessons (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references auth.users(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  slot_id uuid references public.recurring_slots(id) on delete set null,
  lesson_date date not null,
  start_time time not null,
  end_time time not null,
  subject text,
  rate numeric(8,2) not null,
  amount numeric(10,2) not null default 0,
  status text not null default 'done' check (status in ('scheduled','done','cancelled')),
  paid boolean not null default false,
  paid_date date,
  topics text,
  homework text,
  remarks text,
  created_at timestamptz not null default now(),
  level text,
  split integer not null default 1,
  postponed boolean not null default false,
  slot_date date,
  gcal_event_id text,
  compensation numeric,
  one_off boolean not null default false,
  charge_note text,
  subject_notes jsonb
);
create index if not exists lessons_slot_date_idx on public.lessons (tutor_id, slot_date);
create index if not exists lessons_tutor_id_lesson_date_idx on public.lessons (tutor_id, lesson_date);
create index if not exists lessons_tutor_id_paid_idx on public.lessons (tutor_id, paid);

create table if not exists public.exams (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references auth.users(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  subject text,
  exam_date date,
  topics text,
  remarks text,
  created_at timestamptz not null default now(),
  assessment_type text,
  score numeric,
  max_score numeric
);
create index if not exists exams_tutor_id_exam_date_idx on public.exams (tutor_id, exam_date);

create table if not exists public.invoices (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references auth.users(id) on delete cascade,
  student_id uuid references public.students(id) on delete set null,
  invoice_no text not null,
  issued_date date not null default current_date,
  total numeric not null default 0,
  status text not null default 'issued',
  data jsonb,
  created_at timestamptz not null default now(),
  paid_date date,
  proof_path text,
  sent_at timestamptz,
  share_token uuid not null default gen_random_uuid()
);
create unique index if not exists invoices_share_token_idx on public.invoices (share_token);
create index if not exists invoices_tutor_idx on public.invoices (tutor_id, issued_date desc);

create table if not exists public.materials (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  subject text not null,
  level text not null,
  stream text,
  topic text not null,
  title text not null,
  kind text,
  file_path text not null,
  file_name text,
  size_bytes bigint,
  created_at timestamptz not null default now()
);

create table if not exists public.gcal_links (
  tutor_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  google_email text not null default '',
  calendar_id text,
  refresh_enc text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  sync_state text,
  sync_note text,
  sync_started_at timestamptz,
  sync_at timestamptz
);

create table if not exists public.client_errors (
  id bigint generated by default as identity primary key,
  created_at timestamptz not null default now(),
  tutor_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind text not null check (kind in ('js','promise','db','csp')),
  page text check (char_length(page) <= 200),
  message text not null check (char_length(message) <= 500),
  detail text check (char_length(detail) <= 4000),
  app_version text check (char_length(app_version) <= 20),
  user_agent text check (char_length(user_agent) <= 300)
);
create index if not exists client_errors_created_idx on public.client_errors (created_at desc);
create index if not exists client_errors_tutor_idx on public.client_errors (tutor_id, created_at desc);

-- ---------- functions ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name) values (new.id, new.raw_user_meta_data->>'full_name');
  return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create or replace function public.invoice_by_token(t uuid)
returns table(invoice_no text, issued_date date, total numeric, status text, paid_date date, html text, replaced_by text)
language sql stable security definer set search_path = public as $$
  select i.invoice_no, i.issued_date, i.total, i.status, i.paid_date, i.data->>'html', i.data->>'replaced_by'
  from public.invoices i where i.share_token = t limit 1;
$$;

create or replace function public.client_errors_recent() returns integer
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.client_errors where tutor_id = auth.uid() and created_at > now() - interval '1 hour';
$$;

create or replace function public.client_errors_prune() returns trigger
language plpgsql security definer set search_path = public as $$
begin delete from public.client_errors where created_at < now() - interval '90 days'; return null; end $$;
drop trigger if exists client_errors_prune on public.client_errors;
create trigger client_errors_prune after insert on public.client_errors for each statement execute function public.client_errors_prune();

-- ---------- row-level security (exactly as live) ----------
alter table public.profiles enable row level security;
alter table public.students enable row level security;
alter table public.recurring_slots enable row level security;
alter table public.lessons enable row level security;
alter table public.exams enable row level security;
alter table public.invoices enable row level security;
alter table public.materials enable row level security;
alter table public.gcal_links enable row level security;
alter table public.client_errors enable row level security;

drop policy if exists "own profile" on public.profiles;
create policy "own profile" on public.profiles for all using (id = auth.uid()) with check (id = auth.uid());
drop policy if exists "tutor rw students" on public.students;
create policy "tutor rw students" on public.students for all using (tutor_id = auth.uid()) with check (tutor_id = auth.uid());
drop policy if exists "tutor rw slots" on public.recurring_slots;
create policy "tutor rw slots" on public.recurring_slots for all using (tutor_id = auth.uid()) with check (tutor_id = auth.uid());
drop policy if exists "tutor rw lessons" on public.lessons;
create policy "tutor rw lessons" on public.lessons for all using (tutor_id = auth.uid()) with check (tutor_id = auth.uid());
drop policy if exists "tutor rw exams" on public.exams;
create policy "tutor rw exams" on public.exams for all using (tutor_id = auth.uid()) with check (tutor_id = auth.uid());
drop policy if exists "own invoices" on public.invoices;
create policy "own invoices" on public.invoices for all using (tutor_id = auth.uid()) with check (tutor_id = auth.uid());
drop policy if exists "materials owner all" on public.materials;
create policy "materials owner all" on public.materials for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists "own gcal link" on public.gcal_links;
create policy "own gcal link" on public.gcal_links for all to authenticated using (tutor_id = auth.uid()) with check (tutor_id = auth.uid());
drop policy if exists "insert own errors" on public.client_errors;
create policy "insert own errors" on public.client_errors for insert to authenticated
  with check (tutor_id = auth.uid() and public.client_errors_recent() < 30);
