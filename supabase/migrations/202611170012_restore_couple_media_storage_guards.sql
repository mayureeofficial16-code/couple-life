-- Restore the restrictive couple-media guards created by migration 006.
-- This is forward-only: it restores policy definitions without touching rows.
-- Run after migrations 007-011 if those are deployed as one ordered batch.

do $$
begin
  if to_regclass('storage.objects') is null then
    raise exception 'storage.objects is required before restoring couple-media policies';
  end if;
  if to_regprocedure('public.can_access_couple_media(text,boolean)') is null then
    raise exception 'public.can_access_couple_media(text,boolean) is required before restoring couple-media policies';
  end if;

  drop policy if exists "restrict couple media reads" on storage.objects;
  create policy "restrict couple media reads" on storage.objects as restrictive for select to public using (
    bucket_id<>'couple-media' or (auth.uid() is not null and public.can_access_couple_media(name,false))
  );

  drop policy if exists "restrict couple media inserts" on storage.objects;
  create policy "restrict couple media inserts" on storage.objects as restrictive for insert to public with check (
    bucket_id<>'couple-media' or (auth.uid() is not null and public.can_access_couple_media(name,true))
  );

  drop policy if exists "restrict couple media updates" on storage.objects;
  create policy "restrict couple media updates" on storage.objects as restrictive for update to public
    using (bucket_id<>'couple-media' or (auth.uid() is not null and public.can_access_couple_media(name,true)))
    with check (bucket_id<>'couple-media' or (auth.uid() is not null and public.can_access_couple_media(name,true)));

  drop policy if exists "restrict couple media deletes" on storage.objects;
  create policy "restrict couple media deletes" on storage.objects as restrictive for delete to public using (
    bucket_id<>'couple-media' or (auth.uid() is not null and public.can_access_couple_media(name,true))
  );
end
$$;
