-- Undo of migration_centre_tutor_pay.sql (T4 S7): removes the tutor-pay functions and the three tables (rates, adjustments, pay records).
-- THIS DELETES the centre's rate history, bonuses/deductions and "paid" records. Take a backup first if any centre has used it.
-- Not run on LIVE without the owner's yes. Safe to run twice.
drop function if exists public.centre_tutor_taught_report(uuid, date);
drop function if exists public.centre_tutor_pay_export_log(uuid, date, int, bigint);
drop function if exists public.centre_tutor_pay_reverse(uuid, text);
drop function if exists public.centre_tutor_pay_record(uuid, uuid, date, bigint, date, text, text, text);
drop function if exists public.centre_tutor_pay_adjust(uuid, uuid, bigint, date, text);
drop function if exists public.centre_tutor_pay_detail(uuid, uuid, date);
drop function if exists public.centre_tutor_pay_list(uuid, date);
drop function if exists public.centre_tutor_rate_set(uuid, uuid, uuid, text, text, bigint, int, date, text);
drop function if exists public.centre_tutor_rate_list(uuid);
drop function if exists public.centre_tutor_pay_rows(uuid, date, date, uuid);
drop function if exists public.centre_tutor_monthly(uuid, uuid, date, date, int);
drop function if exists public.centre_tutor_rate_for(uuid, uuid, uuid, text, date);
drop function if exists public.centre_tutor_period(date, int);
drop function if exists public.centre_tutor_pay_gate(uuid, text);
-- the tables go first (their triggers use the guard functions), then the guards
drop table if exists public.tutor_pay_payments;
drop table if exists public.tutor_pay_adjustments;
drop table if exists public.tutor_pay_rates;
drop function if exists public.tutor_pay_payment_guard();
drop function if exists public.tutor_pay_freeze_guard();
drop function if exists public.tutor_pay_frozen_to(uuid, uuid);
drop function if exists public.tutor_pay_appendonly();
