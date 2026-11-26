-- T7: invite emails. Needs db/migration_org_foundation.sql (memberships, org_can, audit_row).
-- Adds ONLY: a send log (server-only), a reserve step that enforces the rate limit in SQL, and a status read for the people list.
-- Safe to run twice. Undo: db/migration_invites_down.sql.
--
-- How a send works (api/send-invite.js):
--   1. the browser asks the server to email membership X; the server calls org_invite_mail_reserve(X) AS THE CALLER (their token), so the
--      permission check and the limits below run in SQL, not in JS: the owner or a staff admin with manage_tutors, an invite that is still
--      'invited', at most 1 mail per invite per 10 minutes, at most 5 per invite per 24 hours, at most 30 per organisation per hour.
--   2. a successful reserve writes a 'pending' log row and returns what the email needs (address, name, role, centre, inviter).
--   3. the server (service role) then sends the mail and marks the row 'sent' / 'failed' / 'blocked_preview'.
-- Nobody but the server reads or writes the log table directly (row-level security on, no policies). The log holds NO address and
-- NO link: only ids, times, Brevo's message id and a status. It is audited like every other table.

create table if not exists public.org_invite_mail_log (
  id               uuid primary key default gen_random_uuid(),
  membership_id    uuid not null references public.memberships(id) on delete cascade,
  org_id           uuid not null references public.organisations(id) on delete cascade,
  sent_by          uuid,                                    -- the signed-in person who pressed Send / Resend
  sent_at          timestamptz not null default now(),
  status           text not null default 'pending' check (status in ('pending','sent','failed','blocked_preview')),
  brevo_message_id text
);
create index if not exists org_invite_mail_log_member on public.org_invite_mail_log(membership_id, sent_at desc);
create index if not exists org_invite_mail_log_org on public.org_invite_mail_log(org_id, sent_at desc);
alter table public.org_invite_mail_log enable row level security;       -- no policies on purpose: only the service role (server) can touch it
revoke all on public.org_invite_mail_log from anon, authenticated;

drop trigger if exists audit_row on public.org_invite_mail_log;
create trigger audit_row after insert or update or delete on public.org_invite_mail_log for each row execute function public.audit_row();

-- Reserve one send. Returns { ok: true, log_id, email, name, role, centre, inviter } or { ok: false, reason, retry_minutes? }.
-- Refusals about WHO you are raise 42501 (the server answers 403); refusals about the invite's state come back as data.
create or replace function public.org_invite_mail_reserve(p_member uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare mm memberships; last_at timestamptz; n_day int; n_org int; lid uuid; who text; centre text;
begin
  select * into mm from memberships where id = p_member for update;           -- the lock makes two quick presses count one after the other
  if not found or not org_can(mm.org_id, 'manage_tutors') then raise exception 'Not allowed' using errcode = '42501'; end if;
  if mm.status <> 'invited' or mm.user_id is not null or mm.invited_email is null then return jsonb_build_object('ok', false, 'reason', 'not_invited'); end if;
  select max(sent_at), count(*) filter (where sent_at > now() - interval '24 hours') into last_at, n_day
    from org_invite_mail_log where membership_id = p_member and status in ('pending','sent');
  if last_at is not null and last_at > now() - interval '10 minutes' then
    return jsonb_build_object('ok', false, 'reason', 'too_soon', 'retry_minutes', greatest(1, ceil(extract(epoch from (last_at + interval '10 minutes' - now())) / 60)::int));
  end if;
  if n_day >= 5 then return jsonb_build_object('ok', false, 'reason', 'daily_limit'); end if;
  select count(*) into n_org from org_invite_mail_log where org_id = mm.org_id and sent_at > now() - interval '1 hour' and status in ('pending','sent');
  if n_org >= 30 then return jsonb_build_object('ok', false, 'reason', 'org_limit'); end if;
  insert into org_invite_mail_log(membership_id, org_id, sent_by) values (p_member, mm.org_id, auth.uid()) returning id into lid;
  select display_name into who from memberships where org_id = mm.org_id and user_id = auth.uid() and status = 'active' limit 1;
  select trading_name into centre from organisations where id = mm.org_id;
  return jsonb_build_object('ok', true, 'log_id', lid, 'email', mm.invited_email, 'name', mm.display_name, 'role', mm.role,
                            'centre', centre, 'inviter', coalesce(who, centre));
end $$;

-- For the people list: when each pending invite was created / last emailed and how many mails went out in the last 24 hours
-- (never the address or the link).
create or replace function public.org_invite_mail_status(p_org uuid)
returns table(member_id uuid, invited_at timestamptz, last_sent_at timestamptz, sent_24h int, can_resend_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not org_can(p_org, 'manage_tutors') then raise exception 'Not allowed' using errcode = '42501'; end if;
  return query
    select m.id, m.created_at, l.last_at, coalesce(l.n_day, 0)::int, case when l.last_any is null then null else l.last_any + interval '10 minutes' end
    from memberships m
    left join lateral (select max(sent_at) filter (where status = 'sent') last_at,
                              max(sent_at) filter (where status in ('pending','sent')) last_any,
                              count(*) filter (where sent_at > now() - interval '24 hours' and status in ('pending','sent')) n_day
                         from org_invite_mail_log x where x.membership_id = m.id) l on true
    where m.org_id = p_org and m.status = 'invited' and m.user_id is null;
end $$;

-- who may call what
do $$
declare f text;
begin
  foreach f in array array['org_invite_mail_reserve(uuid)','org_invite_mail_status(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
