-- Couple-scoped world persistence, server-authoritative economy, businesses, pets and ads.

alter table public.worlds add column if not exists revision bigint not null default 0;
alter table public.wallet_transactions add column if not exists idempotency_key uuid;
alter table public.diamond_transactions add column if not exists idempotency_key uuid;
create unique index if not exists wallet_tx_actor_idempotency on public.wallet_transactions(actor_id,idempotency_key) where idempotency_key is not null;
create unique index if not exists diamond_tx_user_idempotency on public.diamond_transactions(user_id,idempotency_key) where idempotency_key is not null;
create index if not exists wallet_tx_couple_created on public.wallet_transactions(couple_id,created_at desc);
create index if not exists businesses_couple on public.businesses(couple_id);
create index if not exists pets_couple on public.pets(couple_id);

create table if not exists public.item_catalog (
  id text primary key,
  name text not null,
  category text not null,
  coin_price integer check(coin_price is null or coin_price>=0),
  diamond_price integer check(diamond_price is null or diamond_price>=0),
  ownership_scope text not null default 'shared' check(ownership_scope in ('shared','individual')),
  stackable boolean not null default false,
  active boolean not null default true,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now()
);
insert into public.item_catalog(id,name,category,coin_price,diamond_price,ownership_scope,stackable,metadata) values
 ('Window seat','Window seat','furniture',65,null,'shared',false,'{"asset":"window-seat"}'),
 ('Tiny garden','Tiny garden','garden',90,null,'shared',false,'{"asset":"tiny-garden"}'),
 ('Love seat','Love seat','furniture',120,null,'shared',false,'{"asset":"love-seat"}'),
 ('Warm lamp','Warm lamp','furniture',45,null,'shared',false,'{"asset":"warm-lamp"}'),
 ('Tea table','Tea table','furniture',75,null,'shared',false,'{"asset":"tea-table"}'),
 ('Flower rug','Flower rug','furniture',55,null,'shared',false,'{"asset":"flower-rug"}'),
 ('pet-food','Pet food','supplies',10,null,'shared',true,'{"asset":"pet-food"}'),
 ('outfit-sunshine','Sunshine outfit','fashion',null,25,'individual',false,'{"asset":"outfit-sunshine"}'),
 ('pet-cat','Cat adoption','pets',120,null,'shared',false,'{"kind":"cat"}'),
 ('pet-dog','Dog adoption','pets',120,null,'shared',false,'{"kind":"dog"}'),
 ('pet-rabbit','Rabbit adoption','pets',120,null,'shared',false,'{"kind":"rabbit"}'),
 ('pet-hamster','Hamster adoption','pets',120,null,'shared',false,'{"kind":"hamster"}')
on conflict(id) do update set name=excluded.name,category=excluded.category,coin_price=excluded.coin_price,diamond_price=excluded.diamond_price,ownership_scope=excluded.ownership_scope,stackable=excluded.stackable,metadata=excluded.metadata;

create table if not exists public.user_inventory (
  user_id uuid not null references auth.users(id) on delete cascade,
  item_id text not null references public.item_catalog(id),
  quantity integer not null default 1 check(quantity>0),
  acquired_at timestamptz not null default now(),
  primary key(user_id,item_id)
);

create table if not exists public.business_catalog (
  kind text primary key,
  display_name text not null,
  coin_price integer not null check(coin_price>=0),
  income_per_day integer not null check(income_per_day>=0),
  active boolean not null default true
);
insert into public.business_catalog(kind,display_name,coin_price,income_per_day) values
 ('cafe','Kopi & Co.',200,35),('bakery','Little Oven',260,48),('flower_shop','Bloom & Petal',180,28),
 ('restaurant','Garden Plate',420,72),('supermarket','Sunbeam Market',500,85),('clothing_shop','Sunday Threads',350,58),
 ('pet_shop','Paw & Whisker',380,62),('beauty_salon','Petal Studio',320,52)
on conflict(kind) do update set display_name=excluded.display_name,coin_price=excluded.coin_price,income_per_day=excluded.income_per_day;
alter table public.businesses add column if not exists display_name text;
alter table public.businesses add column if not exists updated_at timestamptz not null default now();
alter table public.pets add column if not exists adoption_key uuid unique;
alter table public.pets add column if not exists updated_at timestamptz not null default now();

create table if not exists public.platform_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now()
);
create or replace function public.is_platform_admin()
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.platform_admins where user_id=auth.uid())
$$;

create table if not exists public.billboard_slots (
  id smallint primary key check(id between 1 and 10),
  placement text not null,
  package text not null check(package in ('standard','premium','featured','exclusive')),
  monthly_price_myr integer not null check(monthly_price_myr>=0),
  active boolean not null default true
);
insert into public.billboard_slots(id,placement,package,monthly_price_myr) values
 (1,'Neighbourhood entrance','standard',300),(2,'Main street','standard',300),(3,'Supermarket area','standard',300),(4,'Shopping district','standard',300),(5,'Residential street','standard',300),
 (6,'Town square','premium',600),(7,'Park entrance','premium',600),(8,'Restaurant district','premium',600),
 (9,'Business district','featured',1000),(10,'Arcade entrance','featured',1000)
on conflict(id) do update set placement=excluded.placement,package=excluded.package,monthly_price_myr=excluded.monthly_price_myr;
create table if not exists public.advertisers (
  id uuid primary key default gen_random_uuid(),
  company_name text not null,
  logo_url text,
  description text not null default '',
  created_at timestamptz not null default now()
);
create table if not exists public.ad_campaigns (
  id uuid primary key default gen_random_uuid(),
  advertiser_id uuid not null references public.advertisers(id) on delete cascade,
  billboard_id smallint not null references public.billboard_slots(id),
  headline text not null,
  offer text,
  destination_url text not null check(destination_url ~ '^https://'),
  starts_at timestamptz not null,
  expires_at timestamptz not null,
  status text not null default 'pending' check(status in ('pending','active','paused','expired')),
  created_at timestamptz not null default now(),
  check(expires_at>starts_at)
);
create index if not exists campaign_billboard_window on public.ad_campaigns(billboard_id,starts_at,expires_at);
create index if not exists active_campaign_window on public.ad_campaigns(status,starts_at,expires_at);
create table if not exists public.advertising_inquiries (
  id uuid primary key default gen_random_uuid(),
  contact_name text not null,
  company_name text not null,
  contact_email text not null,
  message text not null,
  created_at timestamptz not null default now()
);
create table if not exists public.ad_view_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  campaign_id uuid not null references public.ad_campaigns(id) on delete cascade,
  started_at timestamptz not null default now(),
  completed_at timestamptz
);
create table if not exists public.advertisement_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  campaign_id uuid not null references public.ad_campaigns(id) on delete cascade,
  event_type text not null check(event_type in ('open','click','reward')),
  event_day date not null default ((now() at time zone 'utc')::date),
  occurred_at timestamptz not null default now(),
  unique(user_id,campaign_id,event_type,event_day)
);
create table if not exists public.ad_reward_claims (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  campaign_id uuid not null references public.ad_campaigns(id) on delete cascade,
  session_id uuid not null unique references public.ad_view_sessions(id),
  claimed_on date not null default ((now() at time zone 'utc')::date),
  claimed_at timestamptz not null default now(),
  unique(user_id,campaign_id,claimed_on)
);
create table if not exists public.ad_packages (
  package text primary key check(package in ('standard','premium','featured','exclusive')),
  duration_days integer not null default 30 check(duration_days>0),
  price_myr integer not null check(price_myr>=0),
  active boolean not null default true
);
insert into public.ad_packages(package,duration_days,price_myr) values
 ('standard',30,300),('premium',30,600),('featured',30,1000),('exclusive',30,2000)
on conflict(package) do nothing;

-- The shared world JSON only contains allowed decoration state. Wallets and businesses have separate protected records.
drop policy if exists "members update world" on public.worlds;
drop policy if exists "members manage inventory" on public.inventory;
create policy "members read inventory" on public.inventory for select using(public.is_couple_member(couple_id));
drop policy if exists "members manage businesses" on public.businesses;
create policy "members read businesses" on public.businesses for select using(public.is_couple_member(couple_id));
drop policy if exists "members manage pets" on public.pets;
create policy "members read pets" on public.pets for select using(public.is_couple_member(couple_id));
alter table public.user_inventory enable row level security;
alter table public.item_catalog enable row level security;
alter table public.business_catalog enable row level security;
alter table public.platform_admins enable row level security;
alter table public.billboard_slots enable row level security;
alter table public.advertisers enable row level security;
alter table public.ad_campaigns enable row level security;
alter table public.advertising_inquiries enable row level security;
alter table public.ad_view_sessions enable row level security;
alter table public.advertisement_events enable row level security;
alter table public.ad_reward_claims enable row level security;
alter table public.ad_packages enable row level security;
create policy "read active catalog" on public.item_catalog for select using(active);
create policy "read business catalog" on public.business_catalog for select using(active);
create policy "admin manages item catalog" on public.item_catalog for all using(public.is_platform_admin()) with check(public.is_platform_admin());
create policy "admin manages business catalog" on public.business_catalog for all using(public.is_platform_admin()) with check(public.is_platform_admin());
create policy "read own cosmetic inventory" on public.user_inventory for select using(user_id=auth.uid());
create policy "read billboard locations" on public.billboard_slots for select using(active);
create policy "read active ads" on public.advertisers for select using(exists(select 1 from public.ad_campaigns c where c.advertiser_id=advertisers.id and c.status='active' and c.starts_at<=now() and c.expires_at>now()));
create policy "read active campaigns" on public.ad_campaigns for select using(status='active' and starts_at<=now() and expires_at>now());
create policy "read ad packages" on public.ad_packages for select using(active);
create policy "admin manages platform" on public.platform_admins for select using(user_id=auth.uid());
create policy "admin manages ad campaigns" on public.advertisers for all using(public.is_platform_admin()) with check(public.is_platform_admin());
create policy "admin manages campaign rows" on public.ad_campaigns for all using(public.is_platform_admin()) with check(public.is_platform_admin());
create policy "admin manages ad locations" on public.billboard_slots for all using(public.is_platform_admin()) with check(public.is_platform_admin());
create policy "admin manages packages" on public.ad_packages for all using(public.is_platform_admin()) with check(public.is_platform_admin());
create policy "public submits ad inquiry" on public.advertising_inquiries for insert to anon,authenticated with check(length(contact_name) between 1 and 120 and length(company_name) between 1 and 160 and length(contact_email) between 3 and 320 and length(message) between 1 and 4000);
create policy "admin reads ad inquiries" on public.advertising_inquiries for select using(public.is_platform_admin());
create policy "user reads own ad views" on public.ad_view_sessions for select using(user_id=auth.uid());
create policy "admin reads ad view sessions" on public.ad_view_sessions for select using(public.is_platform_admin());
create policy "admin reads ad metrics" on public.advertisement_events for select using(public.is_platform_admin());
create policy "admin reads ad rewards" on public.ad_reward_claims for select using(public.is_platform_admin());
create policy "user reads own ad rewards" on public.ad_reward_claims for select using(user_id=auth.uid());

create or replace function public.purchase_item(item_key text, pay_with text, request_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare uid uuid:=auth.uid(); cid uuid; product public.item_catalog%rowtype; price integer; coin_balance bigint; diamond_balance bigint; already boolean;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if pay_with not in ('coins','diamonds') or request_id is null then raise exception 'Invalid purchase request'; end if;
  select couple_id into cid from public.couple_members where user_id=uid and approved_at is not null;
  if cid is null then raise exception 'Connect your partner before shopping'; end if;
  select * into product from public.item_catalog where id=item_key and active for update;
  if not found then raise exception 'This item is no longer available'; end if;
  if pay_with='coins' then
    select coins into coin_balance from public.wallets where couple_id=cid for update;
    if coin_balance is null then raise exception 'Shared wallet not found'; end if;
  else
    select diamonds into diamond_balance from public.diamond_wallets where user_id=uid for update;
    if diamond_balance is null then raise exception 'Personal wallet not found'; end if;
  end if;
  price:=case when pay_with='coins' then product.coin_price else product.diamond_price end;
  if price is null then raise exception 'This item cannot be purchased with that currency'; end if;
  if exists(select 1 from public.wallet_transactions where actor_id=uid and idempotency_key=request_id) or exists(select 1 from public.diamond_transactions where user_id=uid and idempotency_key=request_id) then
    if not exists(select 1 from public.wallet_transactions where actor_id=uid and idempotency_key=request_id and reason='shop:'||item_key and amount=-price)
       and not exists(select 1 from public.diamond_transactions where user_id=uid and idempotency_key=request_id and reason='shop:'||item_key and amount=-price) then
      raise exception 'This transaction key has already been used';
    end if;
    select coins into coin_balance from public.wallets where couple_id=cid;
    select diamonds into diamond_balance from public.diamond_wallets where user_id=uid;
    return jsonb_build_object('coins',coin_balance,'diamonds',diamond_balance,'replayed',true);
  end if;
  if not product.stackable then
    already:=case when product.ownership_scope='shared' then exists(select 1 from public.inventory where couple_id=cid and item_id=item_key) else exists(select 1 from public.user_inventory where user_id=uid and item_id=item_key) end;
    if already then raise exception 'This item is already owned'; end if;
  end if;
  if pay_with='coins' then
    update public.wallets set coins=coins-price where couple_id=cid and coins>=price returning coins into coin_balance;
    if coin_balance is null then raise exception 'Not enough shared coins'; end if;
    insert into public.wallet_transactions(couple_id,actor_id,amount,reason,idempotency_key) values(cid,uid,-price,'shop:'||item_key,request_id);
  else
    update public.diamond_wallets set diamonds=diamonds-price where user_id=uid and diamonds>=price returning diamonds into diamond_balance;
    if diamond_balance is null then raise exception 'Not enough personal diamonds'; end if;
    insert into public.diamond_transactions(user_id,amount,reason,idempotency_key) values(uid,-price,'shop:'||item_key,request_id);
  end if;
  if product.ownership_scope='shared' then
    insert into public.inventory(couple_id,item_id,quantity) values(cid,item_key,1) on conflict(couple_id,item_id) do update set quantity=public.inventory.quantity+1;
  else
    insert into public.user_inventory(user_id,item_id,quantity) values(uid,item_key,1) on conflict(user_id,item_id) do update set quantity=public.user_inventory.quantity+1;
  end if;
  select coins into coin_balance from public.wallets where couple_id=cid;
  select diamonds into diamond_balance from public.diamond_wallets where user_id=uid;
  return jsonb_build_object('coins',coin_balance,'diamonds',diamond_balance,'item_id',item_key);
end
$$;

create or replace function public.save_world_state(target_couple uuid, expected_revision bigint, next_game_state jsonb)
returns bigint language plpgsql security definer set search_path=public as $$
declare current_revision bigint; game jsonb; placed jsonb; entry jsonb; nm text; xx integer; yy integer; occupied text[]:='{}';
begin
  if auth.uid() is null or not public.is_couple_member(target_couple) then raise exception 'Couple access required'; end if;
  if expected_revision is null or expected_revision<0 then raise exception 'World revision is invalid'; end if;
  if next_game_state is null or jsonb_typeof(next_game_state)<>'object' or octet_length(next_game_state::text)>131072 then raise exception 'World update is invalid or too large'; end if;
  game:=next_game_state;
  if (game - array['owned','placedFurniture','post'])<>'{}'::jsonb then raise exception 'Unsupported world fields'; end if;
  if jsonb_typeof(coalesce(game->'owned','[]'::jsonb))<>'array' or jsonb_typeof(coalesce(game->'placedFurniture','[]'::jsonb))<>'array' then raise exception 'Invalid furniture data'; end if;
  if game ? 'post' and jsonb_typeof(game->'post') not in ('string','null') then raise exception 'Memory text is invalid'; end if;
  if jsonb_array_length(coalesce(game->'owned','[]'::jsonb))>150 or jsonb_array_length(coalesce(game->'placedFurniture','[]'::jsonb))>100 then raise exception 'World item limit reached'; end if;
  if length(coalesce(game->>'post',''))>2000 then raise exception 'Memory is too long'; end if;
  for nm in select jsonb_array_elements_text(coalesce(game->'owned','[]'::jsonb)) loop
    if not exists(select 1 from public.inventory where couple_id=target_couple and item_id=nm and quantity>0) and not exists(select 1 from public.businesses where couple_id=target_couple and display_name=nm) then raise exception 'World contains an item this couple does not own'; end if;
  end loop;
  placed:=coalesce(game->'placedFurniture','[]'::jsonb);
  for entry in select jsonb_array_elements(placed) loop
    nm:=entry->>'name'; xx:=(entry->>'x')::integer; yy:=(entry->>'y')::integer;
    if nm is null or not (nm=any(array(select jsonb_array_elements_text(coalesce(game->'owned','[]'::jsonb))))) then raise exception 'Placed furniture must be owned'; end if;
    if xx is null or yy is null or xx<7 or xx>17 or yy<7 or yy>9 then raise exception 'Furniture position is outside the home plot'; end if;
    if (xx||','||yy)=any(occupied) then raise exception 'Furniture cannot overlap'; end if;
    occupied:=array_append(occupied,xx||','||yy);
  end loop;
  select revision into current_revision from public.worlds where couple_id=target_couple for update;
  if current_revision is null then raise exception 'Shared world not found'; end if;
  if current_revision<>expected_revision then raise exception 'WORLD_CONFLICT'; end if;
  update public.worlds set state=jsonb_set(state,'{game}',game,true),revision=revision+1,updated_at=now() where couple_id=target_couple returning revision into current_revision;
  return current_revision;
end
$$;

create or replace function public.purchase_business(business_kind text, request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); cid uuid; product public.business_catalog%rowtype; balance bigint; business_id uuid;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if request_id is null then raise exception 'Invalid purchase request'; end if;
  select couple_id into cid from public.couple_members where user_id=uid and approved_at is not null;
  if cid is null then raise exception 'Couple connection required'; end if;
  select coins into balance from public.wallets where couple_id=cid for update;
  if balance is null then raise exception 'Shared wallet not found'; end if;
  select * into product from public.business_catalog where kind=business_kind and active for share;
  if not found then raise exception 'Business unavailable'; end if;
  if exists(select 1 from public.wallet_transactions where actor_id=uid and idempotency_key=request_id) then select coins into balance from public.wallets where couple_id=cid; return jsonb_build_object('coins',balance,'replayed',true); end if;
  if exists(select 1 from public.businesses where couple_id=cid and kind=business_kind) then raise exception 'This couple already owns that business'; end if;
  update public.wallets set coins=coins-product.coin_price where couple_id=cid and coins>=product.coin_price returning coins into balance;
  if balance is null then raise exception 'Not enough shared coins'; end if;
  insert into public.businesses(couple_id,kind,display_name) values(cid,business_kind,product.display_name) returning id into business_id;
  insert into public.wallet_transactions(couple_id,actor_id,amount,reason,idempotency_key) values(cid,uid,-product.coin_price,'business:'||business_kind,request_id);
  return jsonb_build_object('coins',balance,'business_id',business_id);
end
$$;

create or replace function public.collect_business_income(business_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); cid uuid; row public.businesses%rowtype; rate integer; days_earned integer; amount bigint; balance bigint;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if request_id is null then raise exception 'Invalid upgrade request'; end if;
  select couple_id into cid from public.couple_members where user_id=uid and approved_at is not null;
  if cid is null then raise exception 'Couple connection required'; end if;
  select * into row from public.businesses where id=business_id and couple_id=cid for update;
  if not found then raise exception 'Business not found'; end if;
  select income_per_day into rate from public.business_catalog where kind=row.kind and active;
  days_earned:=floor(extract(epoch from least(now()-row.collected_at,interval '7 days'))/86400)::integer;
  amount:=days_earned*rate*row.level;
  if amount<=0 then raise exception 'Your next business earnings are still growing'; end if;
  update public.wallets set coins=coins+amount where couple_id=cid returning coins into balance;
  update public.businesses set collected_at=case when now()-row.collected_at>=interval '7 days' then now() else row.collected_at+days_earned*interval '1 day' end,updated_at=now() where id=business_id;
  insert into public.wallet_transactions(couple_id,actor_id,amount,reason,idempotency_key) values(cid,uid,amount,'business_income:'||row.kind,gen_random_uuid());
  return jsonb_build_object('coins',balance,'earned',amount);
end
$$;

create or replace function public.upgrade_business(business_id uuid, request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); cid uuid; row public.businesses%rowtype; cost integer; balance bigint;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if request_id is null then raise exception 'Invalid upgrade request'; end if;
  select couple_id into cid from public.couple_members where user_id=uid and approved_at is not null;
  if cid is null then raise exception 'Couple connection required'; end if;
  select * into row from public.businesses where id=business_id and couple_id=cid for update;
  if not found then raise exception 'Business not found'; end if;
  if exists(select 1 from public.wallet_transactions where actor_id=uid and idempotency_key=request_id) then select coins into balance from public.wallets where couple_id=cid;return jsonb_build_object('coins',balance,'replayed',true);end if;
  select coin_price into cost from public.business_catalog where kind=row.kind;
  cost:=greatest(25,floor(cost*0.4*row.level)::integer);
  update public.wallets set coins=coins-cost where couple_id=cid and coins>=cost returning coins into balance;
  if balance is null then raise exception 'Not enough shared coins'; end if;
  update public.businesses set level=level+1,updated_at=now() where id=business_id;
  insert into public.wallet_transactions(couple_id,actor_id,amount,reason,idempotency_key) values(cid,uid,-cost,'business_upgrade:'||row.kind,request_id);
  return jsonb_build_object('coins',balance,'level',row.level+1);
end
$$;

create or replace function public.adopt_pet(pet_kind text, pet_name text, request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); cid uuid; item_key text; existing public.pets%rowtype; result jsonb; new_pet_id uuid;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if pet_kind not in ('cat','dog','rabbit','hamster') or length(trim(coalesce(pet_name,''))) not between 1 and 24 then raise exception 'Pet details are invalid'; end if;
  select couple_id into cid from public.couple_members where user_id=uid and approved_at is not null;
  if cid is null then raise exception 'Couple connection required'; end if;
  select * into existing from public.pets where adoption_key=request_id and couple_id=cid;
  if found then return jsonb_build_object('pet_id',existing.id,'replayed',true); end if;
  item_key:='pet-'||pet_kind;
  result:=public.purchase_item(item_key,'coins',request_id);
  select * into existing from public.pets where adoption_key=request_id and couple_id=cid;
  if found then return jsonb_build_object('pet_id',existing.id,'replayed',true); end if;
  delete from public.inventory where couple_id=cid and item_id=item_key and quantity=1;
  if not found then update public.inventory set quantity=quantity-1 where couple_id=cid and item_id=item_key and quantity>1; end if;
  insert into public.pets(couple_id,name,kind,adoption_key) values(cid,trim(pet_name),pet_kind,request_id) returning id into new_pet_id;
  return jsonb_build_object('pet_id',new_pet_id,'coins',result->'coins');
end
$$;

create or replace function public.care_for_pet(pet_id uuid, care_action text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); cid uuid; pet public.pets%rowtype; qty integer; new_hunger integer; new_happiness integer;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select couple_id into cid from public.couple_members where user_id=uid and approved_at is not null;
  if cid is null then raise exception 'Couple connection required'; end if;
  select * into pet from public.pets where id=pet_id and couple_id=cid for update;
  if not found then raise exception 'Pet not found'; end if;
  if care_action='feed' then
    select quantity into qty from public.inventory where couple_id=cid and item_id='pet-food' for update;
    if coalesce(qty,0)<1 then raise exception 'Buy pet food at the market first'; end if;
    if qty=1 then delete from public.inventory where couple_id=cid and item_id='pet-food'; else update public.inventory set quantity=quantity-1 where couple_id=cid and item_id='pet-food'; end if;
    update public.pets set hunger=greatest(0,hunger-35),updated_at=now() where id=pet_id returning hunger,happiness into new_hunger,new_happiness;
  elsif care_action in ('play','groom','water') then
    update public.pets set happiness=least(100,happiness+case when care_action='play' then 15 else 8 end),updated_at=now() where id=pet_id returning hunger,happiness into new_hunger,new_happiness;
  else raise exception 'Unknown pet care action'; end if;
  return jsonb_build_object('hunger',new_hunger,'happiness',new_happiness);
end
$$;

create or replace function public.ad_campaign_is_active(campaign uuid)
returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.ad_campaigns where id=campaign and status='active' and starts_at<=now() and expires_at>now())
$$;
create or replace function public.start_ad_view(campaign uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); session_id uuid;
begin
 if uid is null then raise exception 'Sign in to continue'; end if;
 if not public.ad_campaign_is_active(campaign) then raise exception 'This advertisement has ended'; end if;
 insert into public.ad_view_sessions(user_id,campaign_id) values(uid,campaign) returning id into session_id;
 insert into public.advertisement_events(user_id,campaign_id,event_type) values(uid,campaign,'open') on conflict do nothing;
 return session_id;
end $$;
create or replace function public.record_ad_click(view_session uuid)
returns boolean language plpgsql security definer set search_path=public as $$
declare s public.ad_view_sessions%rowtype;
begin
 select * into s from public.ad_view_sessions where id=view_session and user_id=auth.uid();
 if not found or not public.ad_campaign_is_active(s.campaign_id) then raise exception 'Advertisement session is invalid'; end if;
 insert into public.advertisement_events(user_id,campaign_id,event_type) values(auth.uid(),s.campaign_id,'click') on conflict do nothing;
 return true;
end $$;
create or replace function public.complete_ad_view(view_session uuid)
returns bigint language plpgsql security definer set search_path=public as $$
declare s public.ad_view_sessions%rowtype; new_balance bigint;
begin
 select * into s from public.ad_view_sessions where id=view_session and user_id=auth.uid() for update;
 if not found then raise exception 'Advertisement session not found'; end if;
 if s.completed_at is not null then raise exception 'This advertisement reward has already been claimed'; end if;
 if s.started_at>now()-interval '15 seconds' then raise exception 'Keep the advertisement open for a moment to finish your view'; end if;
 if not public.ad_campaign_is_active(s.campaign_id) then raise exception 'This campaign has ended'; end if;
 insert into public.ad_reward_claims(user_id,campaign_id,session_id) values(auth.uid(),s.campaign_id,s.id);
 insert into public.diamond_wallets(user_id,diamonds) values(auth.uid(),0) on conflict(user_id) do nothing;
 update public.diamond_wallets set diamonds=diamonds+1 where user_id=auth.uid() returning diamonds into new_balance;
 insert into public.diamond_transactions(user_id,amount,reason,idempotency_key) values(auth.uid(),1,'sponsored_ad_view',s.id);
 insert into public.advertisement_events(user_id,campaign_id,event_type) values(auth.uid(),s.campaign_id,'reward') on conflict do nothing;
 update public.ad_view_sessions set completed_at=now() where id=s.id;
 return new_balance;
end $$;

-- Private Realtime channels use couple:<uuid> topics. A user can subscribe or send only for their approved couple.
create or replace function public.can_use_own_couple_channel()
returns boolean language sql stable security definer set search_path=public as $$
 select case when realtime.topic() ~ '^couple:[0-9a-fA-F-]{36}$' then exists(
   select 1 from public.couple_members where couple_id=substring(realtime.topic() from 8)::uuid and user_id=auth.uid() and approved_at is not null
 ) else false end
$$;
drop policy if exists "couple channel members read" on realtime.messages;
drop policy if exists "couple channel members send" on realtime.messages;
create policy "couple channel members read" on realtime.messages for select to authenticated using(public.can_use_own_couple_channel());
create policy "couple channel members send" on realtime.messages for insert to authenticated with check(public.can_use_own_couple_channel());

-- Lock down data writes: all money and ownership changes are performed by security-definer RPCs above.
revoke all on function public.purchase_item(text,text,uuid) from public,anon;
revoke all on function public.save_world_state(uuid,bigint,jsonb) from public,anon;
revoke all on function public.purchase_business(text,uuid) from public,anon;
revoke all on function public.collect_business_income(uuid) from public,anon;
revoke all on function public.upgrade_business(uuid,uuid) from public,anon;
revoke all on function public.adopt_pet(text,text,uuid) from public,anon;
revoke all on function public.care_for_pet(uuid,text) from public,anon;
revoke all on function public.start_ad_view(uuid) from public,anon;
revoke all on function public.record_ad_click(uuid) from public,anon;
revoke all on function public.complete_ad_view(uuid) from public,anon;
grant execute on function public.purchase_item(text,text,uuid) to authenticated;
grant execute on function public.save_world_state(uuid,bigint,jsonb) to authenticated;
grant execute on function public.purchase_business(text,uuid) to authenticated;
grant execute on function public.collect_business_income(uuid) to authenticated;
grant execute on function public.upgrade_business(uuid,uuid) to authenticated;
grant execute on function public.adopt_pet(text,text,uuid) to authenticated;
grant execute on function public.care_for_pet(uuid,text) to authenticated;
grant execute on function public.start_ad_view(uuid) to authenticated;
grant execute on function public.record_ad_click(uuid) to authenticated;
grant execute on function public.complete_ad_view(uuid) to authenticated;

do $$
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='wallets') then alter publication supabase_realtime add table public.wallets; end if;
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='inventory') then alter publication supabase_realtime add table public.inventory; end if;
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='ad_campaigns') then alter publication supabase_realtime add table public.ad_campaigns; end if;
  end if;
end $$;
