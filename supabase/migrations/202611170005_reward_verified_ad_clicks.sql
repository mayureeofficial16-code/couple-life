-- Award one personal diamond for an authenticated, active-campaign click.
-- Existing per-user/campaign/day event and reward constraints prevent duplicate claims.
create or replace function public.record_ad_click(view_session uuid)
returns boolean language plpgsql security definer set search_path=public as $$
declare
  uid uuid:=auth.uid();
  s public.ad_view_sessions%rowtype;
  inserted_count integer;
  reward_count integer;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into s from public.ad_view_sessions
    where id=view_session and user_id=uid for update;
  if not found or s.completed_at is not null or not public.ad_campaign_is_active(s.campaign_id) then
    raise exception 'Advertisement session is invalid';
  end if;

  insert into public.advertisement_events(user_id,campaign_id,event_type)
    values(uid,s.campaign_id,'click') on conflict do nothing;
  get diagnostics inserted_count=row_count;
  if inserted_count=0 then return false; end if;

  insert into public.ad_reward_claims(user_id,campaign_id,session_id)
    values(uid,s.campaign_id,s.id)
    on conflict(user_id,campaign_id,claimed_on) do nothing;
  get diagnostics reward_count=row_count;
  if reward_count=0 then return false; end if;

  insert into public.diamond_wallets(user_id,diamonds) values(uid,0)
    on conflict(user_id) do nothing;
  update public.diamond_wallets set diamonds=diamonds+1
    where user_id=uid;
  insert into public.diamond_transactions(user_id,amount,reason,idempotency_key)
    values(uid,1,'sponsored_ad_click',s.id);
  insert into public.advertisement_events(user_id,campaign_id,event_type)
    values(uid,s.campaign_id,'reward') on conflict do nothing;
  return true;
end
$$;

create or replace function public.complete_ad_view(view_session uuid)
returns bigint language plpgsql security definer set search_path=public as $$
declare
  uid uuid:=auth.uid();
  s public.ad_view_sessions%rowtype;
  balance bigint;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into s from public.ad_view_sessions
    where id=view_session and user_id=uid for update;
  if not found then raise exception 'Advertisement session not found'; end if;
  if s.completed_at is not null then raise exception 'This advertisement view is already complete'; end if;
  if s.started_at>now()-interval '15 seconds' then raise exception 'Keep the advertisement open for a moment to finish your view'; end if;
  if not public.ad_campaign_is_active(s.campaign_id) then raise exception 'This campaign has ended'; end if;
  if not exists(select 1 from public.advertisement_events e where e.user_id=uid and e.campaign_id=s.campaign_id and e.event_type='click' and e.occurred_at>=s.started_at and e.occurred_at<=now()) then
    raise exception 'Click the active advertisement before completing this view';
  end if;
  update public.ad_view_sessions set completed_at=now() where id=s.id;
  select diamonds into balance from public.diamond_wallets where user_id=uid;
  return coalesce(balance,0);
end
$$;

revoke all on function public.record_ad_click(uuid) from public,anon;
revoke all on function public.complete_ad_view(uuid) from public,anon;
grant execute on function public.record_ad_click(uuid) to authenticated;
grant execute on function public.complete_ad_view(uuid) to authenticated;
