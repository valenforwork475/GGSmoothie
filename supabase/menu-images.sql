-- Shared menu photos for Back Office, online ordering, and POS.

begin;

alter table public.menu_items add column if not exists image_url text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'menu-images', 'menu-images', true, 5242880,
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "public read menu images" on storage.objects;
drop policy if exists "menu editors upload images" on storage.objects;
drop policy if exists "menu editors update images" on storage.objects;
drop policy if exists "menu editors delete images" on storage.objects;

create policy "public read menu images" on storage.objects
  for select to public using (bucket_id = 'menu-images');
create policy "menu editors upload images" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'menu-images' and public.staff_has_permission('menu.edit')
  );
create policy "menu editors update images" on storage.objects
  for update to authenticated using (
    bucket_id = 'menu-images' and public.staff_has_permission('menu.edit')
  ) with check (
    bucket_id = 'menu-images' and public.staff_has_permission('menu.edit')
  );
create policy "menu editors delete images" on storage.objects
  for delete to authenticated using (
    bucket_id = 'menu-images' and public.staff_has_permission('menu.edit')
  );

commit;
