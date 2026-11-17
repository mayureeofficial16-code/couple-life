-- Admin-reviewed campaigns, rate-limited inquiries, public creatives and click reporting.
-- No campaign is auto-approved and no advertiser payment is simulated.

alter table public.advertising_inquiries add column if not exists user_id uuid references auth.users(id) on delete set null;
alter table public.advertising_inquiries add column if not exists reviewed_at timestamptz;
alter table public.advertising_inquiries add column if not exists reviewed_by uuid references auth.users(id);
create index if not exists advertising_inquiries_user_created on public.advertising_inquiries(user_id,created_at desc);

alter table public.ad_campaigns add column if not exists creative_path text;
alter table public.ad_campaigns add column if not exists creative_alt text;
alter table public.ad_campaigns add column if not exists booked_duration_days integer;
alter table public.ad_campaigns add column if not exists quoted_price_myr integer;
alter table public.ad_campaigns add column if not exists booked_by uuid references auth.users(id);
revoke insert,update,delete on public.ad_campaigns from anon,authenticated;
grant select on public.ad_campaigns to anon,authenticated;
do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.ad_campaigns'::regclass and conname='ad_campaign_creative_path_safe') then
    alter table public.ad_campaigns add constraint ad_campaign_creative_path_safe check(creative_path is null or (creative_path like 'campaigns/%' and length(creative_path)<=500)) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.ad_campaigns'::regclass and conname='ad_campaign_duration_quote_valid') then
    alter table public.ad_campaigns add constraint ad_campaign_duration_quote_valid check((booked_duration_days is null or booked_duration_days between 1 and 90) and (quoted_price_myr is null or quoted_price_myr>=0)) not valid;
  end if;
end $$;

create table if not exists public.ad_clicks(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  campaign_id uuid not null references public.ad_campaigns(id) on delete cascade,
  session_id uuid not null unique references public.ad_view_sessions(id) on delete cascade,
  clicked_at timestamptz not null default now()
);
create index if not exists ad_clicks_campaign_clicked on public.ad_clicks(campaign_id,clicked_at desc);
alter table public.ad_clicks enable row level security;
drop policy if exists "admin reads ad clicks" on public.ad_clicks;
drop policy if exists "user reads own ad clicks" on public.ad_clicks;
create policy "admin reads ad clicks" on public.ad_clicks for select to authenticated using(public.is_platform_admin());
create policy "user reads own ad clicks" on public.ad_clicks for select to authenticated using(user_id=auth.uid());
revoke all on public.ad_clicks from anon,authenticated;
grant select on public.ad_clicks to authenticated;

-- Public inquiry form submission is authenticated and limited per account; direct table writes are disabled.
drop policy if exists "public submits ad inquiry" on public.advertising_inquiries;
revoke insert,update,delete on public.advertising_inquiries from anon,authenticated;
grant select on public.advertising_inquiries to authenticated;
create or replace function public.submit_advertising_inquiry(
  contact_name text, company_name text, contact_email text, message text, website text default ''
) returns uuid language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); inquiry_id uuid; recent_count integer;
begin
  if uid is null then raise exception 'Sign in to send an advertiser inquiry'; end if;
  if nullif(trim(coalesce(website,'')),'') is not null then raise exception 'Inquiry could not be accepted'; end if;
  if length(trim(coalesce(contact_name,''))) not between 1 and 120 or
     length(trim(coalesce(company_name,''))) not between 1 and 160 or
     length(trim(coalesce(contact_email,''))) not between 3 and 320 or
     trim(contact_email) !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or
     length(trim(coalesce(message,''))) not between 1 and 4000 then
    raise exception 'Check the inquiry details and try again';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(uid::text,808811));
  select count(*) into recent_count from public.advertising_inquiries where user_id=uid and created_at>now()-interval '24 hours';
  if recent_count>=3 then raise exception 'Inquiry limit reached; try again tomorrow'; end if;
  insert into public.advertising_inquiries(user_id,contact_name,company_name,contact_email,message)
    values(uid,trim(contact_name),trim(company_name),lower(trim(contact_email)),trim(message)) returning id into inquiry_id;
  return inquiry_id;
end
$$;
revoke all on function public.submit_advertising_inquiry(text,text,text,text,text) from public,anon;
grant execute on function public.submit_advertising_inquiry(text,text,text,text,text) to authenticated;

-- Public creatives contain advertising only; only platform admins can upload or alter them.
do $$ begin
  if exists(select 1 from storage.buckets where id='advertising-creatives' and
    (not public or file_size_limit<>5242880 or allowed_mime_types is distinct from array['image/jpeg','image/png','image/webp'])) then
    raise exception 'The existing advertising-creatives bucket does not match the expected public image-only configuration; review it before applying this migration';
  end if;
  insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
  values('advertising-creatives','advertising-creatives',true,5242880,array['image/jpeg','image/png','image/webp'])
  on conflict(id) do nothing;
end $$;
drop policy if exists "public read ad creatives" on storage.objects;
drop policy if exists "admins upload ad creatives" on storage.objects;
drop policy if exists "admins update ad creatives" on storage.objects;
drop policy if exists "admins delete ad creatives" on storage.objects;
create policy "public read ad creatives" on storage.objects for select to anon,authenticated using(bucket_id='advertising-creatives');
create policy "admins upload ad creatives" on storage.objects for insert to authenticated with check(bucket_id='advertising-creatives' and name like 'campaigns/%' and public.is_platform_admin());
create policy "admins update ad creatives" on storage.objects for update to authenticated
  using(bucket_id='advertising-creatives' and name like 'campaigns/%' and public.is_platform_admin())
  with check(bucket_id='advertising-creatives' and name like 'campaigns/%' and public.is_platform_admin());
create policy "admins delete ad creatives" on storage.objects for delete to authenticated using(bucket_id='advertising-creatives' and name like 'campaigns/%' and public.is_platform_admin());
-- Restrictive guards prevent broader pre-existing storage policies from authorizing writes here.
drop policy if exists "ad creatives admin-only insert guard" on storage.objects;
drop policy if exists "ad creatives admin-only update guard" on storage.objects;
drop policy if exists "ad creatives admin-only delete guard" on storage.objects;
create policy "ad creatives admin-only insert guard" on storage.objects as restrictive for insert to public
  with check(bucket_id<>'advertising-creatives' or (name like 'campaigns/%' and public.is_platform_admin()));
create policy "ad creatives admin-only update guard" on storage.objects as restrictive for update to public
  using(bucket_id<>'advertising-creatives' or (name like 'campaigns/%' and public.is_platform_admin()))
  with check(bucket_id<>'advertising-creatives' or (name like 'campaigns/%' and public.is_platform_admin()));
create policy "ad creatives admin-only delete guard" on storage.objects as restrictive for delete to public
  using(bucket_id<>'advertising-creatives' or (name like 'campaigns/%' and public.is_platform_admin()));

create table if not exists public.ad_campaign_admin_audit(
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.ad_campaigns(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  old_status text,
  new_status text not null,
  occurred_at timestamptz not null default now()
);
alter table public.ad_campaign_admin_audit enable row level security;
drop policy if exists "platform admins read campaign audit" on public.ad_campaign_admin_audit;
create policy "platform admins read campaign audit" on public.ad_campaign_admin_audit for select to authenticated using(public.is_platform_admin());
revoke all on public.ad_campaign_admin_audit from anon,authenticated;
grant select on public.ad_campaign_admin_audit to authenticated;

create or replace function public.audit_ad_campaign_status_change()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if old.status is distinct from new.status then
    insert into public.ad_campaign_admin_audit(campaign_id,actor_id,old_status,new_status)
    values(new.id,auth.uid(),old.status,new.status);
  end if;
  return new;
end
$$;
drop trigger if exists ad_campaign_status_audit on public.ad_campaigns;
create trigger ad_campaign_status_audit after update of status on public.ad_campaigns
for each row execute function public.audit_ad_campaign_status_change();

create or replace function public.admin_create_ad_campaign(
  company_name text, advertiser_description text, billboard_id smallint, headline text,
  offer text, destination_url text, starts_at timestamptz, duration_days integer,
  creative_path text default null, creative_alt text default null
) returns uuid language plpgsql security definer set search_path=public as $$
#variable_conflict use_variable
declare slot public.billboard_slots%rowtype; package_row public.ad_packages%rowtype; advertiser uuid; campaign_id uuid; campaign_expiry timestamptz; price integer;
begin
  if auth.uid() is null or not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
  if length(trim(coalesce(company_name,''))) not between 1 and 160 or length(trim(coalesce(advertiser_description,'')))>2000 or
     length(trim(coalesce(headline,''))) not between 1 and 120 or length(trim(coalesce(offer,'')))>500 or
     length(trim(coalesce(destination_url,'')))>2048 or trim(destination_url) !~* '^https://' or
     starts_at is null or starts_at<now()-interval '1 minute' or duration_days not between 1 and 90 or
     length(trim(coalesce(creative_alt,'')))>240 then
    raise exception 'Campaign details are invalid';
  end if;
  if creative_path is not null and (creative_path not like 'campaigns/%' or length(creative_path)>500) then raise exception 'Creative path is invalid'; end if;
  select * into slot from public.billboard_slots where id=billboard_id and active for share;
  if not found then raise exception 'Billboard placement is unavailable'; end if;
  select * into package_row from public.ad_packages where package=slot.package and active;
  if not found then raise exception 'Advertising package is unavailable'; end if;
  campaign_expiry:=starts_at+duration_days*interval '1 day';
  price:=ceil(package_row.price_myr::numeric*duration_days/greatest(package_row.duration_days,1))::integer;
  perform pg_advisory_xact_lock(808812,billboard_id::integer);
  if exists(select 1 from public.ad_campaigns c where c.billboard_id=billboard_id and c.status in ('pending','active') and c.starts_at<campaign_expiry and c.expires_at>starts_at) then
    raise exception 'This billboard already has a campaign booked for that time';
  end if;
  insert into public.advertisers(company_name,description) values(trim(company_name),trim(coalesce(advertiser_description,''))) returning id into advertiser;
  insert into public.ad_campaigns(advertiser_id,billboard_id,headline,offer,destination_url,starts_at,expires_at,status,creative_path,creative_alt,booked_duration_days,quoted_price_myr,booked_by)
    values(advertiser,billboard_id,trim(headline),nullif(trim(offer),''),trim(destination_url),starts_at,campaign_expiry,'pending',creative_path,nullif(trim(creative_alt),''),duration_days,price,auth.uid()) returning id into campaign_id;
  return campaign_id;
end
$$;
revoke all on function public.admin_create_ad_campaign(text,text,smallint,text,text,text,timestamptz,integer,text,text) from public,anon;
grant execute on function public.admin_create_ad_campaign(text,text,smallint,text,text,text,timestamptz,integer,text,text) to authenticated;

create or replace function public.admin_set_ad_campaign_status(campaign uuid, next_status text)
returns boolean language plpgsql security definer set search_path=public as $$
declare row public.ad_campaigns%rowtype;
begin
  if auth.uid() is null or not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
  if next_status not in ('active','paused','expired') then raise exception 'Campaign status is invalid'; end if;
  select * into row from public.ad_campaigns where id=campaign for update;
  if not found then raise exception 'Campaign not found'; end if;
  if next_status='active' then
    if row.expires_at<=now() then raise exception 'This campaign has expired'; end if;
    if exists(select 1 from public.ad_campaigns c where c.id<>campaign and c.billboard_id=row.billboard_id and c.status in ('pending','active') and c.starts_at<row.expires_at and c.expires_at>row.starts_at) then
      raise exception 'Another campaign is booked on this billboard during that time';
    end if;
  end if;
  update public.ad_campaigns set status=next_status where id=campaign;
  return true;
end
$$;
revoke all on function public.admin_set_ad_campaign_status(uuid,text) from public,anon;
grant execute on function public.admin_set_ad_campaign_status(uuid,text) to authenticated;

create or replace function public.admin_mark_ad_inquiry_reviewed(inquiry uuid)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null or not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
  update public.advertising_inquiries set reviewed_at=now(),reviewed_by=auth.uid() where id=inquiry;
  if not found then raise exception 'Inquiry not found'; end if;
  return true;
end
$$;
revoke all on function public.admin_mark_ad_inquiry_reviewed(uuid) from public,anon;
grant execute on function public.admin_mark_ad_inquiry_reviewed(uuid) to authenticated;

-- Each session click is counted; the existing daily claim table remains the reward limit.
create or replace function public.record_ad_click(view_session uuid)
returns boolean language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); s public.ad_view_sessions%rowtype; click_id uuid; claim_id uuid;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into s from public.ad_view_sessions where id=view_session and user_id=uid for update;
  if not found or s.completed_at is not null or not public.ad_campaign_is_active(s.campaign_id) then raise exception 'Advertisement session is invalid'; end if;
  insert into public.ad_clicks(user_id,campaign_id,session_id) values(uid,s.campaign_id,s.id) on conflict(session_id) do nothing returning id into click_id;
  if click_id is null then return false; end if;
  insert into public.advertisement_events(user_id,campaign_id,event_type) values(uid,s.campaign_id,'click') on conflict do nothing;
  insert into public.ad_reward_claims(user_id,campaign_id,session_id) values(uid,s.campaign_id,s.id)
    on conflict(user_id,campaign_id,claimed_on) do nothing returning id into claim_id;
  if claim_id is null then return false; end if;
  insert into public.diamond_wallets(user_id,diamonds) values(uid,0) on conflict(user_id) do nothing;
  update public.diamond_wallets set diamonds=diamonds+1 where user_id=uid;
  insert into public.diamond_transactions(user_id,amount,reason,idempotency_key) values(uid,1,'sponsored_ad_click',s.id);
  insert into public.advertisement_events(user_id,campaign_id,event_type) values(uid,s.campaign_id,'reward') on conflict do nothing;
  return true;
end
$$;
revoke all on function public.record_ad_click(uuid) from public,anon;
grant execute on function public.record_ad_click(uuid) to authenticated;
