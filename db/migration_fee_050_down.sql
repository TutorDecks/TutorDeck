-- Undo of migration_fee_050.sql: back to S$100 + 40c for centres on the 50c default, and the old org_create_centre.
-- (A centre with a custom price that happens to be exactly S$100 + 50c cannot be told apart and also goes back to 40c.)
update public.org_plans set per_student_cents = 40 where plan_code = 'centre' and base_cents = 10000 and per_student_cents = 50;

create or replace function public.org_create_centre(p_name text, p_settings jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare o uuid; nm text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  perform org_validate_settings(p_settings);
  insert into organisations(kind, preset, status, trading_name, created_by) values ('centre', 'centre', 'setup', trim(p_name), auth.uid()) returning id into o;
  select coalesce(nullif(p.full_name, ''), split_part(u.email, '@', 1)) into nm from auth.users u left join profiles p on p.id = u.id where u.id = auth.uid();
  insert into memberships(org_id, user_id, display_name, role) values (o, auth.uid(), coalesce(nm, 'Owner'), 'owner');
  insert into org_settings(org_id, version, schema_version, effective_from, settings, created_by) values (o, 1, 1, current_date, p_settings, auth.uid());
  insert into org_plans(org_id, plan_code, base_cents, per_student_cents, effective_from) values (o, 'centre', 10000, 40, current_date);
  return o;
end $$;

drop function if exists public.org_default_centre_plan();
