-- T4 S0: every new centre-money setting is validated on save: every allowed value, the exact refusal, the edge and one past it.
-- Run by tests/sql/run.sh (throwaway Postgres only). Generated from the same lists as db/migration_money_settings.sql; reuses t.* from org_test.sql.
\set ON_ERROR_STOP on
set client_min_messages = notice;

-- put a value at a path, creating the objects on the way
create function t.pp(doc jsonb, path text[], val jsonb) returns jsonb language plpgsql as $$
declare i int;
begin
  for i in 1..array_length(path, 1) - 1 loop
    if jsonb_typeof(doc #> path[1:i]) is distinct from 'object' then doc := jsonb_set(doc, path[1:i], '{}'::jsonb); end if;
  end loop;
  return jsonb_set(doc, path, val);
end $$;
-- the settings are accepted
create function t.accepts(doc jsonb, msg text) returns void language plpgsql as $$
begin
  begin perform org_validate_settings(doc); exception when others then raise exception 'FAIL: % was refused: %', msg, sqlerrm; end;
  raise notice 'PASS accepted: %', msg;
end $$;
-- the settings are refused with exactly this message
create function t.refuses(doc jsonb, expect text, msg text) returns void language plpgsql as $$
declare m text;
begin
  begin perform org_validate_settings(doc); exception when others then m := sqlerrm; end;
  if m is null then raise exception 'FAIL: % was accepted', msg; end if;
  if m <> expect then raise exception 'FAIL: % refused with "%" instead of "%"', msg, m, expect; end if;
  raise notice 'PASS refused: % (%)', msg, m;
end $$;

grant execute on all functions in schema t to authenticated, service_role;

-- ===================================================================== settings saved before this migration still pass
select t.accepts(t.centre_settings(), 'the old minimal centre settings (no new keys)');
select t.accepts(org_solo_settings((select p from profiles p limit 1)), 'a solo tutor''s settings (no new keys)');
select t.accepts(t.pp(t.centre_settings(), '{billing,late_fee}', '{"enabled":true,"amount_cents":1000,"after_days":7}'), 'an old late-fee block (enabled, amount, days only)');
select t.accepts(t.pp(t.centre_settings(), '{billing,one_off_fees,deposit_cents}', '2500'), 'an old deposit amount');
select t.accepts(t.pp(t.centre_settings(), '{tutor_pay,rate_model}', '"per_student_lesson"'), 'an old pay rate model');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,mode}', 'null'), 'a null new key counts as not set');

-- ===================================================================== choices: every allowed value, a wrong value, a wrong type
select t.accepts(t.pp(t.centre_settings(), '{tutor_pay,rate_model}', '"per_lesson"'), 'tutor_pay,rate_model = per_lesson');
select t.accepts(t.pp(t.centre_settings(), '{tutor_pay,rate_model}', '"per_hour"'), 'tutor_pay,rate_model = per_hour');
select t.accepts(t.pp(t.centre_settings(), '{tutor_pay,rate_model}', '"per_student_lesson"'), 'tutor_pay,rate_model = per_student_lesson');
select t.accepts(t.pp(t.centre_settings(), '{tutor_pay,rate_model}', '"monthly_fixed"'), 'tutor_pay,rate_model = monthly_fixed');
select t.accepts(t.pp(t.centre_settings(), '{tutor_pay,rate_model}', '"percent_of_fee"'), 'tutor_pay,rate_model = percent_of_fee');
select t.refuses(t.pp(t.centre_settings(), '{tutor_pay,rate_model}', '"nonsense"'), 'Unknown tutor pay rate', 'tutor_pay,rate_model = nonsense');
select t.refuses(t.pp(t.centre_settings(), '{tutor_pay,rate_model}', '1'), 'Unknown tutor pay rate', 'tutor_pay,rate_model as a number');
select t.accepts(t.pp(t.centre_settings(), '{tutor_pay,percent_base}', '"billed_after_discounts"'), 'tutor_pay,percent_base = billed_after_discounts');
select t.accepts(t.pp(t.centre_settings(), '{tutor_pay,percent_base}', '"list_price"'), 'tutor_pay,percent_base = list_price');
select t.refuses(t.pp(t.centre_settings(), '{tutor_pay,percent_base}', '"nonsense"'), 'Unknown percentage pay base', 'tutor_pay,percent_base = nonsense');
select t.refuses(t.pp(t.centre_settings(), '{tutor_pay,percent_base}', '1'), 'Unknown percentage pay base', 'tutor_pay,percent_base as a number');
select t.accepts(t.pp(t.centre_settings(), '{tutor_pay,part_payments}', '"after_full"'), 'tutor_pay,part_payments = after_full');
select t.accepts(t.pp(t.centre_settings(), '{tutor_pay,part_payments}', '"pro_rata"'), 'tutor_pay,part_payments = pro_rata');
select t.refuses(t.pp(t.centre_settings(), '{tutor_pay,part_payments}', '"nonsense"'), 'Unknown part-payment pay rule', 'tutor_pay,part_payments = nonsense');
select t.refuses(t.pp(t.centre_settings(), '{tutor_pay,part_payments}', '1'), 'Unknown part-payment pay rule', 'tutor_pay,part_payments as a number');
select t.accepts(t.pp(t.centre_settings(), '{tutor_pay,cancelled_lessons}', '"pay_if_charged"'), 'tutor_pay,cancelled_lessons = pay_if_charged');
select t.accepts(t.pp(t.centre_settings(), '{tutor_pay,cancelled_lessons}', '"pay_rate"'), 'tutor_pay,cancelled_lessons = pay_rate');
select t.accepts(t.pp(t.centre_settings(), '{tutor_pay,cancelled_lessons}', '"pay_nothing"'), 'tutor_pay,cancelled_lessons = pay_nothing');
select t.refuses(t.pp(t.centre_settings(), '{tutor_pay,cancelled_lessons}', '"nonsense"'), 'Unknown cancelled-lesson pay rule', 'tutor_pay,cancelled_lessons = nonsense');
select t.refuses(t.pp(t.centre_settings(), '{tutor_pay,cancelled_lessons}', '1'), 'Unknown cancelled-lesson pay rule', 'tutor_pay,cancelled_lessons as a number');
select t.accepts(t.pp(t.centre_settings(), '{tutor_pay,group_count}', '"attended"'), 'tutor_pay,group_count = attended');
select t.accepts(t.pp(t.centre_settings(), '{tutor_pay,group_count}', '"enrolled"'), 'tutor_pay,group_count = enrolled');
select t.refuses(t.pp(t.centre_settings(), '{tutor_pay,group_count}', '"nonsense"'), 'Unknown group pay count', 'tutor_pay,group_count = nonsense');
select t.refuses(t.pp(t.centre_settings(), '{tutor_pay,group_count}', '1'), 'Unknown group pay count', 'tutor_pay,group_count as a number');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,mode}', '"none"'), 'billing,deposit,mode = none');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,mode}', '"fixed"'), 'billing,deposit,mode = fixed');
select t.accepts(t.pp(t.pp(t.centre_settings(), '{billing,deposit,mode}', '"percent_first_month"'), '{billing,deposit,percent_bp}', '5000'), 'billing,deposit,mode = percent_first_month (with a percentage)');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,mode}', '"nonsense"'), 'Unknown deposit mode', 'billing,deposit,mode = nonsense');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,mode}', '1'), 'Unknown deposit mode', 'billing,deposit,mode as a number');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,due}', '"with_first_invoice"'), 'billing,deposit,due = with_first_invoice');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,due}', '"before_first_lesson"'), 'billing,deposit,due = before_first_lesson');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,due}', '"nonsense"'), 'Unknown deposit due rule', 'billing,deposit,due = nonsense');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,due}', '1'), 'Unknown deposit due rule', 'billing,deposit,due as a number');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,waived_by}', '"owner"'), 'billing,deposit,waived_by = owner');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,waived_by}', '"issue_invoices"'), 'billing,deposit,waived_by = issue_invoices');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,waived_by}', '"nobody"'), 'billing,deposit,waived_by = nobody');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,waived_by}', '"nonsense"'), 'Unknown deposit waiver rule', 'billing,deposit,waived_by = nonsense');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,waived_by}', '1'), 'Unknown deposit waiver rule', 'billing,deposit,waived_by as a number');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,release}', '"refund_full"'), 'billing,deposit,release = refund_full');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,release}', '"refund_less_unpaid"'), 'billing,deposit,release = refund_less_unpaid');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,release}', '"admin_decides"'), 'billing,deposit,release = admin_decides');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,release}', '"nonsense"'), 'Unknown deposit release rule', 'billing,deposit,release = nonsense');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,release}', '1'), 'Unknown deposit release rule', 'billing,deposit,release as a number');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,refund_approved_by}', '"owner"'), 'billing,deposit,refund_approved_by = owner');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,refund_approved_by}', '"staff"'), 'billing,deposit,refund_approved_by = staff');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,refund_approved_by}', '"four_eyes"'), 'billing,deposit,refund_approved_by = four_eyes');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,refund_approved_by}', '"nonsense"'), 'Unknown deposit refund approver', 'billing,deposit,refund_approved_by = nonsense');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,refund_approved_by}', '1'), 'Unknown deposit refund approver', 'billing,deposit,refund_approved_by as a number');
select t.accepts(t.pp(t.centre_settings(), '{billing,late_fee,repeat}', '"none"'), 'billing,late_fee,repeat = none');
select t.accepts(t.pp(t.centre_settings(), '{billing,late_fee,repeat}', '"once"'), 'billing,late_fee,repeat = once');
select t.accepts(t.pp(t.centre_settings(), '{billing,late_fee,repeat}', '"monthly"'), 'billing,late_fee,repeat = monthly');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,repeat}', '"nonsense"'), 'Unknown late fee repeat', 'billing,late_fee,repeat = nonsense');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,repeat}', '1'), 'Unknown late fee repeat', 'billing,late_fee,repeat as a number');
select t.accepts(t.pp(t.centre_settings(), '{billing,late_fee,type}', '"fixed"'), 'billing,late_fee,type = fixed');
select t.accepts(t.pp(t.pp(t.centre_settings(), '{billing,late_fee,type}', '"percent"'), '{billing,late_fee,percent_bp}', '5000'), 'billing,late_fee,type = percent (with a percentage)');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,type}', '"nonsense"'), 'Unknown late fee type', 'billing,late_fee,type = nonsense');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,type}', '1'), 'Unknown late fee type', 'billing,late_fee,type as a number');
select t.accepts(t.pp(t.centre_settings(), '{billing,late_fee,show_as}', '"next_invoice_line"'), 'billing,late_fee,show_as = next_invoice_line');
select t.accepts(t.pp(t.centre_settings(), '{billing,late_fee,show_as}', '"own_invoice"'), 'billing,late_fee,show_as = own_invoice');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,show_as}', '"nonsense"'), 'Unknown late fee placement', 'billing,late_fee,show_as = nonsense');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,show_as}', '1'), 'Unknown late fee placement', 'billing,late_fee,show_as as a number');
select t.accepts(t.pp(t.centre_settings(), '{billing,late_fee,waived_by}', '"owner"'), 'billing,late_fee,waived_by = owner');
select t.accepts(t.pp(t.centre_settings(), '{billing,late_fee,waived_by}', '"issue_invoices"'), 'billing,late_fee,waived_by = issue_invoices');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,waived_by}', '"nonsense"'), 'Unknown late fee waiver rule', 'billing,late_fee,waived_by = nonsense');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,waived_by}', '1'), 'Unknown late fee waiver rule', 'billing,late_fee,waived_by as a number');
select t.accepts(t.pp(t.centre_settings(), '{lessons,class_type}', '"one_to_one"'), 'lessons,class_type = one_to_one');
select t.accepts(t.pp(t.centre_settings(), '{lessons,class_type}', '"group"'), 'lessons,class_type = group');
select t.accepts(t.pp(t.centre_settings(), '{lessons,class_type}', '"both"'), 'lessons,class_type = both');
select t.refuses(t.pp(t.centre_settings(), '{lessons,class_type}', '"nonsense"'), 'Unknown class type', 'lessons,class_type = nonsense');
select t.refuses(t.pp(t.centre_settings(), '{lessons,class_type}', '1'), 'Unknown class type', 'lessons,class_type as a number');

-- ===================================================================== yes/no settings
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,taxable}', 'true'), 'billing,deposit,taxable = true');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,taxable}', 'false'), 'billing,deposit,taxable = false');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,taxable}', '"yes"'), 'Setting {billing,deposit,taxable} must be yes or no', 'billing,deposit,taxable = yes');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,taxable}', '1'), 'Setting {billing,deposit,taxable} must be yes or no', 'billing,deposit,taxable = 1');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,top_up}', 'true'), 'billing,deposit,top_up = true');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,top_up}', 'false'), 'billing,deposit,top_up = false');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,top_up}', '"yes"'), 'Setting {billing,deposit,top_up} must be yes or no', 'billing,deposit,top_up = yes');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,top_up}', '1'), 'Setting {billing,deposit,top_up} must be yes or no', 'billing,deposit,top_up = 1');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,set_off_unpaid}', 'true'), 'billing,deposit,set_off_unpaid = true');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,set_off_unpaid}', 'false'), 'billing,deposit,set_off_unpaid = false');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,set_off_unpaid}', '"yes"'), 'Setting {billing,deposit,set_off_unpaid} must be yes or no', 'billing,deposit,set_off_unpaid = yes');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,set_off_unpaid}', '1'), 'Setting {billing,deposit,set_off_unpaid} must be yes or no', 'billing,deposit,set_off_unpaid = 1');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,final_month}', 'true'), 'billing,deposit,final_month = true');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,final_month}', 'false'), 'billing,deposit,final_month = false');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,final_month}', '"yes"'), 'Setting {billing,deposit,final_month} must be yes or no', 'billing,deposit,final_month = yes');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,final_month}', '1'), 'Setting {billing,deposit,final_month} must be yes or no', 'billing,deposit,final_month = 1');
select t.accepts(t.pp(t.centre_settings(), '{billing,trials,charged}', 'true'), 'billing,trials,charged = true');
select t.accepts(t.pp(t.centre_settings(), '{billing,trials,charged}', 'false'), 'billing,trials,charged = false');
select t.refuses(t.pp(t.centre_settings(), '{billing,trials,charged}', '"yes"'), 'Setting {billing,trials,charged} must be yes or no', 'billing,trials,charged = yes');
select t.refuses(t.pp(t.centre_settings(), '{billing,trials,charged}', '1'), 'Setting {billing,trials,charged} must be yes or no', 'billing,trials,charged = 1');

-- ===================================================================== numbers: the edge, one past it, fractions, text, negatives
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,percent_bp}', '0'), 'billing,deposit,percent_bp at its lowest (0)');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,percent_bp}', '10000'), 'billing,deposit,percent_bp at its highest (10000)');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,percent_bp}', '10001'), 'Deposit percentage must be between 0% and 100%', 'billing,deposit,percent_bp one past the highest');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,percent_bp}', '-1'), 'Deposit percentage must be between 0% and 100%', 'billing,deposit,percent_bp one below the lowest');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,percent_bp}', '12.5'), 'Deposit percentage must be between 0% and 100%', 'billing,deposit,percent_bp with a fraction');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,percent_bp}', '"0"'), 'Deposit percentage must be between 0% and 100%', 'billing,deposit,percent_bp as text');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,forfeit_notice_days}', '0'), 'billing,deposit,forfeit_notice_days at its lowest (0)');
select t.accepts(t.pp(t.centre_settings(), '{billing,deposit,forfeit_notice_days}', '90'), 'billing,deposit,forfeit_notice_days at its highest (90)');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,forfeit_notice_days}', '91'), 'Deposit notice must be 0-90 days', 'billing,deposit,forfeit_notice_days one past the highest');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,forfeit_notice_days}', '-1'), 'Deposit notice must be 0-90 days', 'billing,deposit,forfeit_notice_days one below the lowest');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,forfeit_notice_days}', '12.5'), 'Deposit notice must be 0-90 days', 'billing,deposit,forfeit_notice_days with a fraction');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,forfeit_notice_days}', '"0"'), 'Deposit notice must be 0-90 days', 'billing,deposit,forfeit_notice_days as text');
select t.accepts(t.pp(t.centre_settings(), '{billing,late_fee,percent_bp}', '0'), 'billing,late_fee,percent_bp at its lowest (0)');
select t.accepts(t.pp(t.centre_settings(), '{billing,late_fee,percent_bp}', '10000'), 'billing,late_fee,percent_bp at its highest (10000)');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,percent_bp}', '10001'), 'Late fee percentage must be between 0% and 100%', 'billing,late_fee,percent_bp one past the highest');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,percent_bp}', '-1'), 'Late fee percentage must be between 0% and 100%', 'billing,late_fee,percent_bp one below the lowest');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,percent_bp}', '12.5'), 'Late fee percentage must be between 0% and 100%', 'billing,late_fee,percent_bp with a fraction');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,percent_bp}', '"0"'), 'Late fee percentage must be between 0% and 100%', 'billing,late_fee,percent_bp as text');
select t.accepts(t.pp(t.centre_settings(), '{billing,late_fee,after_days}', '0'), 'billing,late_fee,after_days at its lowest (0)');
select t.accepts(t.pp(t.centre_settings(), '{billing,late_fee,after_days}', '365'), 'billing,late_fee,after_days at its highest (365)');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,after_days}', '366'), 'Late fee grace period must be 0-365 days', 'billing,late_fee,after_days one past the highest');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,after_days}', '-1'), 'Late fee grace period must be 0-365 days', 'billing,late_fee,after_days one below the lowest');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,after_days}', '12.5'), 'Late fee grace period must be 0-365 days', 'billing,late_fee,after_days with a fraction');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,after_days}', '"0"'), 'Late fee grace period must be 0-365 days', 'billing,late_fee,after_days as text');
select t.accepts(t.pp(t.centre_settings(), '{billing,late_fee,cap_cents}', '0'), 'billing,late_fee,cap_cents at its lowest (0)');
select t.accepts(t.pp(t.centre_settings(), '{billing,late_fee,cap_cents}', '100000000'), 'billing,late_fee,cap_cents at its highest (100000000)');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,cap_cents}', '100000001'), 'Late fee limit must be a whole number of cents, 0 to 100000000', 'billing,late_fee,cap_cents one past the highest');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,cap_cents}', '-1'), 'Late fee limit must be a whole number of cents, 0 to 100000000', 'billing,late_fee,cap_cents one below the lowest');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,cap_cents}', '12.5'), 'Late fee limit must be a whole number of cents, 0 to 100000000', 'billing,late_fee,cap_cents with a fraction');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,cap_cents}', '"0"'), 'Late fee limit must be a whole number of cents, 0 to 100000000', 'billing,late_fee,cap_cents as text');
select t.accepts(t.pp(t.centre_settings(), '{billing,late_fee,amount_cents}', '0'), 'billing,late_fee,amount_cents at its lowest (0)');
select t.accepts(t.pp(t.centre_settings(), '{billing,late_fee,amount_cents}', '100000000'), 'billing,late_fee,amount_cents at its highest (100000000)');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,amount_cents}', '100000001'), 'Late fee amount must be a whole number of cents, 0 to 100000000', 'billing,late_fee,amount_cents one past the highest');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,amount_cents}', '-1'), 'Late fee amount must be a whole number of cents, 0 to 100000000', 'billing,late_fee,amount_cents one below the lowest');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,amount_cents}', '12.5'), 'Late fee amount must be a whole number of cents, 0 to 100000000', 'billing,late_fee,amount_cents with a fraction');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,amount_cents}', '"0"'), 'Late fee amount must be a whole number of cents, 0 to 100000000', 'billing,late_fee,amount_cents as text');
select t.accepts(t.pp(t.centre_settings(), '{billing,one_off_fees,deposit_cents}', '0'), 'billing,one_off_fees,deposit_cents at its lowest (0)');
select t.accepts(t.pp(t.centre_settings(), '{billing,one_off_fees,deposit_cents}', '100000000'), 'billing,one_off_fees,deposit_cents at its highest (100000000)');
select t.refuses(t.pp(t.centre_settings(), '{billing,one_off_fees,deposit_cents}', '100000001'), 'Deposit amount must be a whole number of cents, 0 to 100000000', 'billing,one_off_fees,deposit_cents one past the highest');
select t.refuses(t.pp(t.centre_settings(), '{billing,one_off_fees,deposit_cents}', '-1'), 'Deposit amount must be a whole number of cents, 0 to 100000000', 'billing,one_off_fees,deposit_cents one below the lowest');
select t.refuses(t.pp(t.centre_settings(), '{billing,one_off_fees,deposit_cents}', '12.5'), 'Deposit amount must be a whole number of cents, 0 to 100000000', 'billing,one_off_fees,deposit_cents with a fraction');
select t.refuses(t.pp(t.centre_settings(), '{billing,one_off_fees,deposit_cents}', '"0"'), 'Deposit amount must be a whole number of cents, 0 to 100000000', 'billing,one_off_fees,deposit_cents as text');
select t.accepts(t.pp(t.centre_settings(), '{profile,next_invoice_number}', '1'), 'profile,next_invoice_number at its lowest (1)');
select t.accepts(t.pp(t.centre_settings(), '{profile,next_invoice_number}', '999999999'), 'profile,next_invoice_number at its highest (999999999)');
select t.refuses(t.pp(t.centre_settings(), '{profile,next_invoice_number}', '1000000000'), 'Next invoice number must be a whole number, 1 or more', 'profile,next_invoice_number one past the highest');
select t.refuses(t.pp(t.centre_settings(), '{profile,next_invoice_number}', '0'), 'Next invoice number must be a whole number, 1 or more', 'profile,next_invoice_number one below the lowest');
select t.refuses(t.pp(t.centre_settings(), '{profile,next_invoice_number}', '12.5'), 'Next invoice number must be a whole number, 1 or more', 'profile,next_invoice_number with a fraction');
select t.refuses(t.pp(t.centre_settings(), '{profile,next_invoice_number}', '"1"'), 'Next invoice number must be a whole number, 1 or more', 'profile,next_invoice_number as text');

-- ===================================================================== a percentage mode needs a real percentage
select t.accepts(t.pp(t.pp(t.centre_settings(), '{billing,deposit,mode}', '"percent_first_month"'), '{billing,deposit,percent_bp}', '5000'), 'deposit 50% of the first month');
select t.accepts(t.pp(t.pp(t.centre_settings(), '{billing,deposit,mode}', '"percent_first_month"'), '{billing,deposit,percent_bp}', '1'), 'deposit 0.01% (the lowest real percentage)');
select t.accepts(t.pp(t.pp(t.centre_settings(), '{billing,deposit,mode}', '"percent_first_month"'), '{billing,deposit,percent_bp}', '10000'), 'deposit 100%');
select t.refuses(t.pp(t.pp(t.centre_settings(), '{billing,deposit,mode}', '"percent_first_month"'), '{billing,deposit,percent_bp}', '0'), 'Deposit percentage must be between 0.01% and 100%', 'percent mode with 0%');
select t.refuses(t.pp(t.pp(t.centre_settings(), '{billing,deposit,mode}', '"percent_first_month"'), '{billing,deposit,percent_bp}', '10001'), 'Deposit percentage must be between 0% and 100%', 'percent mode with 100.01%');
select t.refuses(t.pp(t.centre_settings(), '{billing,deposit,mode}', '"percent_first_month"'), 'Deposit percentage must be between 0.01% and 100%', 'percent mode with no percentage at all');
select t.accepts(t.pp(t.pp(t.centre_settings(), '{billing,deposit,mode}', '"fixed"'), '{billing,deposit,percent_bp}', '0'), 'fixed mode may leave the percentage at 0');
select t.accepts(t.pp(t.pp(t.centre_settings(), '{billing,late_fee,type}', '"percent"'), '{billing,late_fee,percent_bp}', '500'), 'late fee 5% of what is unpaid');
select t.accepts(t.pp(t.pp(t.centre_settings(), '{billing,late_fee,type}', '"percent"'), '{billing,late_fee,percent_bp}', '1'), 'late fee 0.01%');
select t.refuses(t.pp(t.pp(t.centre_settings(), '{billing,late_fee,type}', '"percent"'), '{billing,late_fee,percent_bp}', '0'), 'Late fee percentage must be between 0.01% and 100%', 'percent late fee with 0%');
select t.refuses(t.pp(t.pp(t.centre_settings(), '{billing,late_fee,type}', '"percent"'), '{billing,late_fee,percent_bp}', '10001'), 'Late fee percentage must be between 0% and 100%', 'percent late fee with 100.01%');
select t.refuses(t.pp(t.centre_settings(), '{billing,late_fee,type}', '"percent"'), 'Late fee percentage must be between 0.01% and 100%', 'percent late fee with no percentage at all');
select t.accepts(t.pp(t.pp(t.centre_settings(), '{billing,late_fee,type}', '"fixed"'), '{billing,late_fee,percent_bp}', '0'), 'fixed late fee may leave the percentage at 0');

-- ===================================================================== the real save paths refuse a bad value and keep a good one
set role authenticated; select t.as('00000000-0000-0000-0000-0000000000a1');
select org_create_centre('Money Centre', t.pp(t.pp(t.centre_settings(), '{billing,deposit,mode}', '"percent_first_month"'), '{billing,deposit,percent_bp}', '5000')) as mc \gset
select t.fails(format('select org_create_centre(%L, %L::jsonb)', 'Bad Percent Centre',
  t.pp(t.pp(t.centre_settings(), '{billing,deposit,mode}', '"percent_first_month"'), '{billing,deposit,percent_bp}', '12000')::text), 'creating a centre with a 120% deposit', 'Deposit percentage');
select org_save_settings(:'mc', t.pp(t.pp(t.centre_settings(), '{billing,late_fee,type}', '"percent"'), '{billing,late_fee,percent_bp}', '500'), current_date) as v \gset
select t.ok(:v >= 2, 'the owner saved a valid late-fee percentage as a new settings version');
select t.fails(format('select org_save_settings(%L, %L::jsonb, current_date)', :'mc',
  t.pp(t.pp(t.centre_settings(), '{billing,late_fee,type}', '"percent"'), '{billing,late_fee,percent_bp}', '0')::text), 'saving a percent late fee of 0%', 'Late fee percentage');
reset role;
select t.ok((select settings #>> '{billing,late_fee,percent_bp}' = '500' from org_settings where org_id = :'mc' order by version desc limit 1), 'the refused save left the saved settings as they were');
select t.ok(exists (select 1 from pg_proc where proname = 'org_validate_settings' and 'search_path=public' = any(proconfig)), 'the validator still has its search_path pinned (function lockdown)');
