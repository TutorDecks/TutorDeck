-- Undo of migration_org_separation.sql: removes the same-organisation trigger and its function. Nothing else changed.
do $$
declare t text;
begin
  foreach t in array array['lessons','recurring_slots','exams','invoices'] loop
    execute format('drop trigger if exists org_same_org_guard on public.%I', t);
  end loop;
end $$;
drop function if exists public.org_same_org_guard();
