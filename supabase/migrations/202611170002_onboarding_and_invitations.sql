-- Couple Life account onboarding and single-use partner invitations.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

alter table public.profiles add column if not exists birthday date;
alter table public.couples add column if not exists partner_a_birthday date;
alter table public.couples add column if not exists partner_b_birthday date;
alter table public.couples add column if not exists relationship_nickname text;
alter table public.couples add column if not exists setup_complete_at timestamptz;
alter table public.couples add column if not exists relationship_confirmations uuid[] not null default '{}';
alter table public.couples add column if not exists created_by uuid references auth.users(id);
alter table public.couple_members add column if not exists created_at timestamptz not null default now();
update public.couples c set created_by=(select cm.user_id from public.couple_members cm where cm.couple_id=c.id order by cm.created_at asc limit 1) where c.created_by is null;
alter table public.invitations add column if not exists redeemed_at timestamptz;
alter table public.invitations add column if not exists declined_by uuid references auth.users(id);
alter table public.invitations add column if not exists declined_at timestamptz;

create or replace function public.create_profile_for_new_user()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  raw_name text;
  base_name text;
begin
  raw_name := coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email,'@',1), 'Player');
  base_name := lower(regexp_replace(raw_name,'[^a-zA-Z0-9_]+','_','g'));
  insert into public.profiles(id,username,display_name,avatar_url)
  values(new.id, left(coalesce(nullif(base_name,''),'player'),32)||'_'||substr(replace(new.id::text,'-',''),1,6), raw_name, new.raw_user_meta_data->>'avatar_url')
  on conflict(id) do update set display_name=excluded.display_name;
  return new;
end
$$;
drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile after insert on auth.users
for each row execute function public.create_profile_for_new_user();

create or replace function public.create_couple_invitation()
returns table(invitation_code text, couple_id uuid, expires_at timestamptz)
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := auth.uid();
  cid uuid;
  members integer;
  code text;
  expiry timestamptz := now() + interval '7 days';
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select cm.couple_id into cid from public.couple_members cm where cm.user_id=uid and cm.approved_at is not null;
  if cid is null then
    insert into public.couples(created_by) values(uid) returning id into cid;
    insert into public.couple_members(couple_id,user_id,approved_at) values(cid,uid,now());
    insert into public.worlds(couple_id) values(cid);
    insert into public.wallets(couple_id) values(cid);
  else
    select count(*) into members from public.couple_members cm where cm.couple_id=cid and cm.approved_at is not null;
    if members >= 2 then raise exception 'This couple already has two connected partners'; end if;
  end if;
  insert into public.diamond_wallets(user_id) values(uid) on conflict(user_id) do nothing;
  code := upper(encode(gen_random_bytes(8),'hex'));
  insert into public.invitations(couple_id,code_hash,expires_at,created_by)
  values(cid,encode(digest(code,'sha256'),'hex'),expiry,uid);
  return query select code,cid,expiry;
end
$$;

create or replace function public.accept_couple_invitation(input_code text)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := auth.uid();
  invitation public.invitations%rowtype;
  members integer;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if input_code is null or length(trim(input_code)) <> 16 then raise exception 'Invitation code is invalid'; end if;
  if exists(select 1 from public.couple_members where user_id=uid) then raise exception 'This account already belongs to a couple'; end if;
  select * into invitation from public.invitations i
  where i.code_hash=encode(digest(upper(trim(input_code)),'sha256'),'hex')
    and i.redeemed_at is null and i.declined_at is null and i.expires_at > now()
  for update;
  if not found then raise exception 'Invitation is expired or has already been used'; end if;
  if invitation.created_by=uid then raise exception 'You cannot accept your own invitation'; end if;
  perform 1 from public.couples where id=invitation.couple_id for update;
  select count(*) into members from public.couple_members cm where cm.couple_id=invitation.couple_id and cm.approved_at is not null;
  if members >= 2 then raise exception 'This couple is already connected'; end if;
  insert into public.couple_members(couple_id,user_id,approved_at) values(invitation.couple_id,uid,now());
  update public.invitations set redeemed_by=uid,redeemed_at=now() where id=invitation.id;
  insert into public.diamond_wallets(user_id) values(uid) on conflict(user_id) do nothing;
  return invitation.couple_id;
end
$$;

create or replace function public.decline_couple_invitation(input_code text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := auth.uid();
  invitation public.invitations%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if input_code is null or length(trim(input_code)) <> 16 then raise exception 'Invitation code is invalid'; end if;
  select * into invitation from public.invitations i
  where i.code_hash=encode(digest(upper(trim(input_code)),'sha256'),'hex')
    and i.redeemed_at is null and i.declined_at is null and i.expires_at > now()
  for update;
  if not found then raise exception 'Invitation is expired or already handled'; end if;
  if invitation.created_by=uid then raise exception 'You cannot decline your own invitation'; end if;
  update public.invitations set declined_by=uid,declined_at=now() where id=invitation.id;
  return true;
end
$$;

create or replace function public.complete_relationship_setup(
  target_couple uuid, anniversary_on date, birthday_a date, birthday_b date, nickname text default null
) returns timestamptz language plpgsql security definer set search_path=public as $$
declare completed timestamptz;
        confirmations uuid[];
begin
  if auth.uid() is null or not public.is_couple_member(target_couple) then raise exception 'Couple access required'; end if;
  if (select count(*) from public.couple_members cm where cm.couple_id=target_couple and cm.approved_at is not null) <> 2 then
    raise exception 'Both partners must connect before relationship setup';
  end if;
  if anniversary_on is null or anniversary_on > current_date then raise exception 'Enter a valid anniversary date'; end if;
  update public.couples set anniversary=anniversary_on,partner_a_birthday=birthday_a,partner_b_birthday=birthday_b,
    relationship_nickname=nullif(trim(nickname),''),
    relationship_confirmations=case when auth.uid()=any(relationship_confirmations) then relationship_confirmations else array_append(relationship_confirmations,auth.uid()) end
    where id=target_couple returning relationship_confirmations into confirmations;
  if cardinality(confirmations) >= 2 then
    update public.couples set setup_complete_at=now() where id=target_couple returning setup_complete_at into completed;
  end if;
  return completed;
end
$$;

alter table public.profiles enable row level security;
alter table public.invitations enable row level security;
drop policy if exists "read own profile" on public.profiles;
create policy "read self and connected partner profiles" on public.profiles for select using (
  id=auth.uid() or exists(
    select 1 from public.couple_members mine join public.couple_members theirs using(couple_id)
    where mine.user_id=auth.uid() and mine.approved_at is not null and theirs.user_id=profiles.id and theirs.approved_at is not null
  )
);
drop policy if exists "update own profile" on public.profiles;
create policy "update own profile" on public.profiles for update using(id=auth.uid()) with check(id=auth.uid());
drop policy if exists "read member couples" on public.couples;
create policy "read member couples" on public.couples for select using(public.is_couple_member(id));

revoke all on function public.create_couple_invitation() from public, anon;
revoke all on function public.accept_couple_invitation(text) from public, anon;
revoke all on function public.decline_couple_invitation(text) from public, anon;
revoke all on function public.complete_relationship_setup(uuid,date,date,date,text) from public, anon;
grant execute on function public.create_couple_invitation() to authenticated;
grant execute on function public.accept_couple_invitation(text) to authenticated;
grant execute on function public.decline_couple_invitation(text) to authenticated;
grant execute on function public.complete_relationship_setup(uuid,date,date,date,text) to authenticated;

do $$
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='worlds') then alter publication supabase_realtime add table public.worlds; end if;
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='pets') then alter publication supabase_realtime add table public.pets; end if;
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='businesses') then alter publication supabase_realtime add table public.businesses; end if;
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='game_rooms') then alter publication supabase_realtime add table public.game_rooms; end if;
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='couple_members') then alter publication supabase_realtime add table public.couple_members; end if;
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='couples') then alter publication supabase_realtime add table public.couples; end if;
  end if;
end $$;
