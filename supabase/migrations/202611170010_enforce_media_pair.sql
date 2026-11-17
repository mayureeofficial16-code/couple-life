-- Enforce a complete media path/type pair for new or changed relationship posts.
-- NOT VALID leaves any pre-existing records untouched while enforcing future writes.
do $$ begin
  if not exists(
    select 1 from pg_constraint
    where conrelid='public.posts'::regclass and conname='posts_media_pair_strict'
  ) then
    alter table public.posts add constraint posts_media_pair_strict check (
      (media_path is null and media_type is null) or
      (media_path is not null and media_type is not null and media_type in ('image','video'))
    ) not valid;
  end if;
end $$;