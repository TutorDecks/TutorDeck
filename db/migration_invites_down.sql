-- Undo db/migration_invites.sql: removes the invite-mail log (the audit log keeps its history, it is append-only).
drop function if exists public.org_invite_mail_status(uuid);
drop function if exists public.org_invite_mail_reserve(uuid);
drop table if exists public.org_invite_mail_log;
