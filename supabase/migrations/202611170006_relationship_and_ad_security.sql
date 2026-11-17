-- Tighten couple-content ownership, enable private media, and bound ad-view creation.

-- Couple membership grants reading, not ownership of a partner's post.
drop policy if exists "members manage posts" on public.posts;
drop policy if exists "members read couple posts" on public.posts;
drop policy if exists "authors create couple posts" on public.posts;
drop policy if exists "authors update own couple posts" on public.posts;
drop policy if exists "authors delete own couple posts" on public.posts;
create policy "members read couple posts" on public.posts for select
  using (public.is_couple_member(couple_id));
create policy "authors create couple posts" on public.posts for insert
  with check (author_id=auth.uid() and public.is_couple_member(couple_id));
create policy "authors update own couple posts" on public.posts for update
  using (author_id=auth.uid() and public.is_couple_member(couple_id))
  with check (author_id=auth.uid() and public.is_couple_member(couple_id));
create policy "authors delete own couple posts" on public.posts for delete
  using (author_id=auth.uid() and public.is_couple_member(couple_id));

alter table public.posts add column if not exists media_path text;
alter table public.posts add column if not exists media_type text;
do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.posts'::regclass and conname='posts_media_pair_valid') then
    alter table public.posts add constraint posts_media_pair_valid
      check ((media_path is null and media_type is null) or (media_path is not null and media_type is not null and media_type in ('image','video'))) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.posts'::regclass and conname='posts_media_path_scoped') then
    alter table public.posts add constraint posts_media_path_scoped
      check (media_path is null or (split_part(media_path,'/',1)=couple_id::text and split_part(media_path,'/',2)=author_id::text and media_path !~ '(^|/)\.\.?(/|$)')) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.posts'::regclass and conname='posts_body_size_valid') then
    alter table public.posts add constraint posts_body_size_valid check(length(body) between 1 and 2000) not valid;
  end if;
end $$;
create index if not exists posts_couple_timeline on public.posts(couple_id,created_at desc);
-- Preserve the prototype's existing single-memory field as the first timeline entry.
insert into public.posts(couple_id,author_id,body,created_at)
select c.id,c.created_by,left(w.state#>>'{game,post}',2000),coalesce(w.updated_at,now())
from public.worlds w join public.couples c on c.id=w.couple_id
where nullif(trim(w.state#>>'{game,post}'),'') is not null and c.created_by is not null
  and not exists(select 1 from public.posts p where p.couple_id=c.id and p.body=left(w.state#>>'{game,post}',2000));

-- Comments and reactions were RLS-enabled but had no member policies.
drop policy if exists "members read post comments" on public.comments;
drop policy if exists "authors create post comments" on public.comments;
drop policy if exists "authors update own comments" on public.comments;
drop policy if exists "authors delete own comments" on public.comments;
create policy "members read post comments" on public.comments for select using (
  exists(select 1 from public.posts p where p.id=post_id and public.is_couple_member(p.couple_id))
);
create policy "authors create post comments" on public.comments for insert with check (
  author_id=auth.uid() and length(body) between 1 and 1200 and
  exists(select 1 from public.posts p where p.id=post_id and public.is_couple_member(p.couple_id))
);
create policy "authors update own comments" on public.comments for update
  using (author_id=auth.uid() and exists(select 1 from public.posts p where p.id=post_id and public.is_couple_member(p.couple_id)))
  with check (author_id=auth.uid() and length(body) between 1 and 1200 and exists(select 1 from public.posts p where p.id=post_id and public.is_couple_member(p.couple_id)));
create policy "authors delete own comments" on public.comments for delete using (
  author_id=auth.uid() and exists(select 1 from public.posts p where p.id=post_id and public.is_couple_member(p.couple_id))
);
do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.comments'::regclass and conname='comments_body_size_valid') then
    alter table public.comments add constraint comments_body_size_valid check(length(body) between 1 and 1200) not valid;
  end if;
end $$;
create index if not exists comments_post_timeline on public.comments(post_id,created_at);

drop policy if exists "members read post reactions" on public.reactions;
drop policy if exists "users create own reactions" on public.reactions;
drop policy if exists "users update own reactions" on public.reactions;
drop policy if exists "users delete own reactions" on public.reactions;
create policy "members read post reactions" on public.reactions for select using (
  exists(select 1 from public.posts p where p.id=post_id and public.is_couple_member(p.couple_id))
);
create policy "users create own reactions" on public.reactions for insert with check (
  user_id=auth.uid() and length(reaction) between 1 and 32 and
  exists(select 1 from public.posts p where p.id=post_id and public.is_couple_member(p.couple_id))
);
create policy "users update own reactions" on public.reactions for update
  using (user_id=auth.uid() and exists(select 1 from public.posts p where p.id=post_id and public.is_couple_member(p.couple_id)))
  with check (user_id=auth.uid() and length(reaction) between 1 and 32 and exists(select 1 from public.posts p where p.id=post_id and public.is_couple_member(p.couple_id)));
create policy "users delete own reactions" on public.reactions for delete using (
  user_id=auth.uid() and exists(select 1 from public.posts p where p.id=post_id and public.is_couple_member(p.couple_id))
);
do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.reactions'::regclass and conname='reactions_value_size_valid') then
    alter table public.reactions add constraint reactions_value_size_valid check(length(reaction) between 1 and 32) not valid;
  end if;
end $$;

-- Couple posts may hold paths only; the underlying storage bucket remains private.
do $$
declare existing_bucket storage.buckets%rowtype;
        media_types text[]:=array['image/jpeg','image/png','image/webp','video/mp4','video/webm'];
begin
  select * into existing_bucket from storage.buckets where id='couple-media';
  if found then
    if existing_bucket.public or existing_bucket.file_size_limit is distinct from 10485760 or existing_bucket.allowed_mime_types is distinct from media_types then
      raise exception 'The existing couple-media bucket settings do not match the required private 10 MB image/video configuration';
    end if;
  else
    insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
    values('couple-media','couple-media',false,10485760,media_types);
  end if;
end $$;
create or replace function public.can_access_couple_media(object_path text, owner_only boolean default false)
returns boolean language plpgsql stable set search_path=public,storage as $$
declare folders text[];
begin
  if auth.uid() is null then return false; end if;
  folders:=storage.foldername(object_path);
  if coalesce(array_length(folders,1),0)<>2 then return false; end if;
  if folders[1]!~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or
     folders[2]!~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then return false; end if;
  if owner_only and folders[2]<>auth.uid()::text then return false; end if;
  return public.is_couple_member(folders[1]::uuid);
end
$$;
grant execute on function public.can_access_couple_media(text,boolean) to public;
drop policy if exists "couple members read shared media" on storage.objects;
drop policy if exists "couple members upload own media path" on storage.objects;
drop policy if exists "owners update own couple media" on storage.objects;
drop policy if exists "owners delete own couple media" on storage.objects;
drop policy if exists "restrict couple media reads" on storage.objects;
drop policy if exists "restrict couple media inserts" on storage.objects;
drop policy if exists "restrict couple media updates" on storage.objects;
drop policy if exists "restrict couple media deletes" on storage.objects;
create policy "couple members read shared media" on storage.objects for select to authenticated using (
  bucket_id='couple-media' and public.can_access_couple_media(name,false)
);
create policy "couple members upload own media path" on storage.objects for insert to authenticated with check (
  bucket_id='couple-media' and public.can_access_couple_media(name,true)
);
create policy "owners update own couple media" on storage.objects for update to authenticated
  using (bucket_id='couple-media' and public.can_access_couple_media(name,true))
  with check (bucket_id='couple-media' and public.can_access_couple_media(name,true));
create policy "owners delete own couple media" on storage.objects for delete to authenticated using (
  bucket_id='couple-media' and public.can_access_couple_media(name,true)
);
-- Restrictive guards prevent any older permissive Storage policy from exposing this bucket.
create policy "restrict couple media reads" on storage.objects as restrictive for select to public using (
  bucket_id<>'couple-media' or (auth.uid() is not null and public.can_access_couple_media(name,false))
);
create policy "restrict couple media inserts" on storage.objects as restrictive for insert to public with check (
  bucket_id<>'couple-media' or (auth.uid() is not null and public.can_access_couple_media(name,true))
);
create policy "restrict couple media updates" on storage.objects as restrictive for update to public
  using (bucket_id<>'couple-media' or (auth.uid() is not null and public.can_access_couple_media(name,true)))
  with check (bucket_id<>'couple-media' or (auth.uid() is not null and public.can_access_couple_media(name,true)));
create policy "restrict couple media deletes" on storage.objects as restrictive for delete to public using (
  bucket_id<>'couple-media' or (auth.uid() is not null and public.can_access_couple_media(name,true))
);

-- Let each partner safely update the anniversary and their own birthday after setup.
create or replace function public.update_relationship_details(target_couple uuid, anniversary_on date, own_birthday date, nickname text default null)
returns boolean language plpgsql security definer set search_path=public as $$
declare creator uuid;
begin
  if auth.uid() is null or not public.is_couple_member(target_couple) then raise exception 'Couple access required'; end if;
  if anniversary_on is null or anniversary_on>current_date then raise exception 'Enter a valid anniversary date'; end if;
  if own_birthday is not null and own_birthday>current_date then raise exception 'Enter a valid birthday'; end if;
  if nickname is not null and length(trim(nickname))>40 then raise exception 'Relationship nickname is too long'; end if;
  select created_by into creator from public.couples where id=target_couple for update;
  if creator is null then raise exception 'Couple profile not found'; end if;
  if creator=auth.uid() then
    update public.couples set anniversary=anniversary_on,partner_a_birthday=own_birthday,relationship_nickname=nullif(trim(nickname),'') where id=target_couple;
  else
    update public.couples set anniversary=anniversary_on,partner_b_birthday=own_birthday,relationship_nickname=nullif(trim(nickname),'') where id=target_couple;
  end if;
  return true;
end
$$;
revoke all on function public.update_relationship_details(uuid,date,date,text) from public,anon;
grant execute on function public.update_relationship_details(uuid,date,date,text) to authenticated;

create index if not exists ad_view_sessions_user_started on public.ad_view_sessions(user_id,started_at desc);
-- A signed-in caller can create only a bounded number of impression sessions per hour.
create or replace function public.start_ad_view(campaign uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); session_id uuid; recent_sessions integer;
begin
  if uid is null then raise exception 'Sign in to continue'; end if;
  if not public.ad_campaign_is_active(campaign) then raise exception 'This advertisement has ended'; end if;
  perform pg_advisory_xact_lock(hashtextextended(uid::text,6060401));
  select count(*) into recent_sessions from public.ad_view_sessions where user_id=uid and started_at>now()-interval '1 hour';
  if recent_sessions>=60 then raise exception 'Ad view limit reached; try again later'; end if;
  insert into public.ad_view_sessions(user_id,campaign_id) values(uid,campaign) returning id into session_id;
  insert into public.advertisement_events(user_id,campaign_id,event_type) values(uid,campaign,'open') on conflict do nothing;
  return session_id;
end
$$;
revoke all on function public.start_ad_view(uuid) from public,anon;
grant execute on function public.start_ad_view(uuid) to authenticated;

do $$ begin
  if not exists(select 1 from pg_publication where pubname='supabase_realtime') then raise exception 'supabase_realtime publication is unavailable'; end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='posts') then alter publication supabase_realtime add table public.posts; end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='comments') then alter publication supabase_realtime add table public.comments; end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='reactions') then alter publication supabase_realtime add table public.reactions; end if;
end $$;
