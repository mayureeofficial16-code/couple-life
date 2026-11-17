-- Migration 003's income collector accidentally referenced the upgrade RPC's request_id.
-- Replace it with the same couple-scoped, seven-day-capped collector without that stray check.
create or replace function public.collect_business_income(business_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); cid uuid; row public.businesses%rowtype; rate integer; days_earned integer; amount bigint; balance bigint;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select couple_id into cid from public.couple_members where user_id=uid and approved_at is not null;
  if cid is null then raise exception 'Couple connection required'; end if;
  select * into row from public.businesses where id=business_id and couple_id=cid for update;
  if not found then raise exception 'Business not found'; end if;
  select income_per_day into rate from public.business_catalog where kind=row.kind and active;
  if rate is null then raise exception 'Business income is unavailable'; end if;
  days_earned:=floor(extract(epoch from least(now()-row.collected_at,interval '7 days'))/86400)::integer;
  amount:=days_earned*rate*row.level;
  if amount<=0 then raise exception 'Your next business earnings are still growing'; end if;
  update public.wallets set coins=coins+amount where couple_id=cid returning coins into balance;
  if balance is null then raise exception 'Shared wallet not found'; end if;
  update public.businesses set collected_at=case when now()-row.collected_at>=interval '7 days' then now() else row.collected_at+days_earned*interval '1 day' end,updated_at=now() where id=business_id;
  insert into public.wallet_transactions(couple_id,actor_id,amount,reason,idempotency_key) values(cid,uid,amount,'business_income:'||row.kind,gen_random_uuid());
  return jsonb_build_object('coins',balance,'earned',amount);
end
$$;
revoke all on function public.collect_business_income(uuid) from public,anon;
grant execute on function public.collect_business_income(uuid) to authenticated;
