-- Undo for migration_tutor_payout.sql (run it FIRST, before migration_tutor_profile_down.sql).
-- WARNING: drops every payout detail tutors entered. The audit rows (masked values only) stay, as the audit log is append-only.
drop function if exists public.tutor_my_payout();
drop function if exists public.tutor_reveal_payout(uuid);
drop function if exists public.tutor_save_payout(uuid, text, text, text, text, boolean);
drop function if exists public.tutor_clear_payout(uuid);
drop function if exists public.td_payout_audit(uuid, uuid, uuid, text, text, text);
drop function if exists public.td_my_centre_tutor(uuid);
drop function if exists public.td_payout_mask(text);
drop table if exists public.tutor_payout_details;
drop function if exists public.tutor_payout_guard();
