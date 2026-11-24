-- Storage buckets + policies as on live (2026-11). Applied to Supabase projects only (not the local tests).
insert into storage.buckets (id, name, public) values ('receipts', 'receipts', false), ('materials', 'materials', false)
on conflict (id) do nothing;
drop policy if exists "materials bucket owner" on storage.objects;
create policy "materials bucket owner" on storage.objects for all to authenticated
  using (bucket_id = 'materials' and owner = auth.uid()) with check (bucket_id = 'materials' and owner = auth.uid());
drop policy if exists receipts_select_own on storage.objects;
create policy receipts_select_own on storage.objects for select to authenticated using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists receipts_insert_own on storage.objects;
create policy receipts_insert_own on storage.objects for insert to authenticated with check (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists receipts_update_own on storage.objects;
create policy receipts_update_own on storage.objects for update to authenticated using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists receipts_delete_own on storage.objects;
create policy receipts_delete_own on storage.objects for delete to authenticated using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);
