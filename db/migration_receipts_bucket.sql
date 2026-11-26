-- =====================================================================
-- Storage bucket for transaction screenshots ("receipts").
-- Private bucket; each tutor can only touch files under their own uid/
-- folder, matching how the app writes paths ("<auth.uid()>/...").
--
-- Easiest: create the bucket in the Supabase dashboard (Storage → New
-- bucket → name "receipts", NOT public), then run just the policies
-- below. Or run the whole file in the SQL editor.
-- =====================================================================

insert into storage.buckets (id, name, public)
values ('receipts', 'receipts', false)
on conflict (id) do nothing;

-- Per-tutor folder isolation: the first path segment must be their uid.
create policy "receipts_select_own" on storage.objects for select to authenticated
  using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "receipts_insert_own" on storage.objects for insert to authenticated
  with check (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "receipts_update_own" on storage.objects for update to authenticated
  using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "receipts_delete_own" on storage.objects for delete to authenticated
  using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);
