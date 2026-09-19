insert into storage.buckets (id, name, public) values ('dashboard-assets', 'dashboard-assets', true) on conflict (id) do update set public = true;

create policy dashboard_assets_public_read on storage.objects for select using (bucket_id = 'dashboard-assets');
create policy dashboard_assets_public_insert on storage.objects for insert with check (bucket_id = 'dashboard-assets');
create policy dashboard_assets_public_update on storage.objects for update using (bucket_id = 'dashboard-assets') with check (bucket_id = 'dashboard-assets');
create policy dashboard_assets_public_delete on storage.objects for delete using (bucket_id = 'dashboard-assets');