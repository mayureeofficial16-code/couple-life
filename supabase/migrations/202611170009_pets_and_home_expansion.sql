-- Add server-authoritative home rooms and shared pet accessories without replacing existing tables.

alter table public.pets add column if not exists accessories jsonb not null default '[]'::jsonb;
do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.pets'::regclass and conname='pets_accessories_array') then
    alter table public.pets add constraint pets_accessories_array check(jsonb_typeof(accessories)='array' and jsonb_array_length(accessories)<=20) not valid;
  end if;
end $$;

insert into public.item_catalog(id,name,category,coin_price,diamond_price,ownership_scope,stackable,metadata,active) values
 ('pet-bird','Bird adoption','pets',140,null,'shared',false,'{"kind":"bird"}',true),
 ('pet-bow','Pet bow','pet_accessory',45,null,'shared',false,'{"slot":"collar","art":"🎀"}',true),
 ('pet-toy','Pet toy','pet_accessory',35,null,'shared',false,'{"slot":"toy","art":"🧸"}',true),
 ('pet-bed','Cozy pet bed','pet_accessory',90,null,'shared',false,'{"slot":"bed","art":"🛏️"}',true)
on conflict(id) do update set name=excluded.name,category=excluded.category,coin_price=excluded.coin_price,diamond_price=excluded.diamond_price,ownership_scope=excluded.ownership_scope,stackable=excluded.stackable,metadata=excluded.metadata,active=true;

create or replace function public.adopt_pet(pet_kind text,pet_name text,request_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare uid uuid:=auth.uid(); cid uuid; item_key text; existing public.pets%rowtype; result jsonb; new_pet_id uuid;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if pet_kind not in ('cat','dog','rabbit','hamster','bird') or length(trim(coalesce(pet_name,''))) not between 1 and 24 or request_id is null then raise exception 'Pet details are invalid'; end if;
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
revoke all on function public.adopt_pet(text,text,uuid) from public,anon;
grant execute on function public.adopt_pet(text,text,uuid) to authenticated;

create or replace function public.equip_pet_accessory(pet_id uuid,accessory_key text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); cid uuid; pet public.pets%rowtype; qty integer; equipped_now boolean;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select couple_id into cid from public.couple_members where user_id=uid and approved_at is not null;
  if cid is null then raise exception 'Couple connection required'; end if;
  select * into pet from public.pets where id=pet_id and couple_id=cid for update;
  if not found then raise exception 'Pet not found'; end if;
  if not exists(select 1 from public.item_catalog where id=accessory_key and category='pet_accessory' and active) then raise exception 'Pet accessory unavailable'; end if;
  select quantity into qty from public.inventory where couple_id=cid and item_id=accessory_key;
  if coalesce(qty,0)<1 then raise exception 'Buy this accessory from the pet shop first'; end if;
  equipped_now:=coalesce(pet.accessories,'[]'::jsonb) ? accessory_key;
  if equipped_now then
    update public.pets set accessories=accessories-accessory_key,updated_at=now() where id=pet_id;
  else
    if jsonb_array_length(coalesce(pet.accessories,'[]'::jsonb))>=20 then raise exception 'This pet already has the maximum number of accessories'; end if;
    update public.pets set accessories=accessories||jsonb_build_array(accessory_key),happiness=least(100,happiness+3),updated_at=now() where id=pet_id;
  end if;
  return jsonb_build_object('equipped',not equipped_now);
end
$$;
revoke all on function public.equip_pet_accessory(uuid,text) from public,anon;
grant execute on function public.equip_pet_accessory(uuid,text) to authenticated;

create table if not exists public.home_room_catalog(
  room_key text primary key,
  display_name text not null,
  coin_price integer not null check(coin_price>0),
  sort_order integer not null unique check(sort_order>0),
  active boolean not null default true
);
insert into public.home_room_catalog(room_key,display_name,coin_price,sort_order,active) values
 ('garden-room','Garden room',450,1,true),('reading-room','Reading room',700,2,true)
on conflict(room_key) do update set display_name=excluded.display_name,coin_price=excluded.coin_price,sort_order=excluded.sort_order,active=excluded.active;
alter table public.home_room_catalog enable row level security;
drop policy if exists "read active home room catalog" on public.home_room_catalog;
drop policy if exists "admin manages home room catalog" on public.home_room_catalog;
create policy "read active home room catalog" on public.home_room_catalog for select using(active);
create policy "admin manages home room catalog" on public.home_room_catalog for all using(public.is_platform_admin()) with check(public.is_platform_admin());

create table if not exists public.couple_home_rooms(
  couple_id uuid not null references public.couples(id) on delete cascade,
  room_key text not null references public.home_room_catalog(room_key),
  purchased_by uuid not null references auth.users(id),
  unlocked_at timestamptz not null default now(),
  primary key(couple_id,room_key)
);
alter table public.couple_home_rooms enable row level security;
drop policy if exists "members read home rooms" on public.couple_home_rooms;
create policy "members read home rooms" on public.couple_home_rooms for select using(public.is_couple_member(couple_id));

create or replace function public.purchase_home_room(target_room_key text,request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); cid uuid; product public.home_room_catalog%rowtype; balance bigint; previous_key text; old_tx public.wallet_transactions%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if request_id is null then raise exception 'Invalid purchase request'; end if;
  select couple_id into cid from public.couple_members where user_id=uid and approved_at is not null;
  if cid is null then raise exception 'Couple connection required'; end if;
  select * into product from public.home_room_catalog where home_room_catalog.room_key=target_room_key and active;
  if not found then raise exception 'Room expansion unavailable'; end if;
  select * into old_tx from public.wallet_transactions where actor_id=uid and idempotency_key=request_id;
  if found then
    if old_tx.reason<>'house_room:'||target_room_key or old_tx.amount<>-product.coin_price then raise exception 'This transaction key has already been used'; end if;
    select coins into balance from public.wallets where couple_id=cid;
    return jsonb_build_object('coins',balance,'room_key',target_room_key,'replayed',true);
  end if;
  select coins into balance from public.wallets where couple_id=cid for update;
  if balance is null then raise exception 'Shared wallet not found'; end if;
  if exists(select 1 from public.couple_home_rooms where couple_id=cid and couple_home_rooms.room_key=product.room_key) then raise exception 'This room is already unlocked'; end if;
  if product.sort_order>1 then
    select room_key into previous_key from public.home_room_catalog where sort_order=product.sort_order-1 and active;
    if previous_key is null or not exists(select 1 from public.couple_home_rooms where couple_id=cid and couple_home_rooms.room_key=previous_key) then raise exception 'Unlock the previous room first'; end if;
  end if;
  update public.wallets set coins=coins-product.coin_price where couple_id=cid and coins>=product.coin_price returning coins into balance;
  if balance is null then raise exception 'Not enough shared coins'; end if;
  insert into public.couple_home_rooms(couple_id,room_key,purchased_by) values(cid,product.room_key,uid);
  insert into public.wallet_transactions(couple_id,actor_id,amount,reason,idempotency_key) values(cid,uid,-product.coin_price,'house_room:'||target_room_key,request_id);
  return jsonb_build_object('coins',balance,'room_key',target_room_key,'replayed',false);
end
$$;
revoke all on function public.purchase_home_room(text,uuid) from public,anon;
grant execute on function public.purchase_home_room(text,uuid) to authenticated;

do $$ begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') and
     not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='couple_home_rooms') then
    alter publication supabase_realtime add table public.couple_home_rooms;
  end if;
end $$;
