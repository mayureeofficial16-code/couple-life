-- Award ad diamonds after an eligible completed view, never on the outbound click.
-- Migration 003 supplies the view, reward-claim, event, and diamond-ledger tables.
-- Migration 006 supplies the rate-limited start_ad_view function.
-- Migration 008 supplies ad_clicks and the campaign scheduling/admin workflow.

create or replace function public.record_ad_click(view_session uuid)
returns boolean language plpgsql security definer set search_path=public as $$
declare
  uid uuid:=auth.uid();
  s public.ad_view_sessions%rowtype;
  click_id uuid;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into s from public.ad_view_sessions
    where id=view_session and user_id=uid for update;
  if not found or not public.ad_campaign_is_active(s.campaign_id) then
    raise exception 'Advertisement session is invalid';
  end if;

  insert into public.ad_clicks(user_id,campaign_id,session_id)
    values(uid,s.campaign_id,s.id)
    on conflict(session_id) do nothing
    returning id into click_id;
  if click_id is null then return false; end if;

  insert into public.advertisement_events(user_id,campaign_id,event_type)
    values(uid,s.campaign_id,'click') on conflict do nothing;
  return true;
end
$$;

-- Return an explicit outcome so the client can distinguish an awarded view from
-- a valid repeat view when the per-player/per-campaign UTC daily claim is used.
drop function if exists public.complete_ad_view(uuid);
create function public.complete_ad_view(view_session uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid:=auth.uid();
  s public.ad_view_sessions%rowtype;
  claim_id uuid;
  balance bigint;
  already_rewarded boolean;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into s from public.ad_view_sessions
    where id=view_session and user_id=uid for update;
  if not found then raise exception 'Advertisement session not found'; end if;

  if s.completed_at is not null then
    select diamonds into balance from public.diamond_wallets where user_id=uid;
    select exists(select 1 from public.ad_reward_claims where session_id=s.id and user_id=uid)
      into already_rewarded;
    return jsonb_build_object('rewarded',already_rewarded,'already_completed',true,'diamonds',coalesce(balance,0));
  end if;
  if s.started_at>now()-interval '15 seconds' then
    raise exception 'Keep the advertisement visible for at least 15 seconds to complete this view';
  end if;
  if not public.ad_campaign_is_active(s.campaign_id) then
    raise exception 'This campaign has ended';
  end if;

  update public.ad_view_sessions set completed_at=now() where id=s.id;
  insert into public.ad_reward_claims(user_id,campaign_id,session_id)
    values(uid,s.campaign_id,s.id)
    on conflict(user_id,campaign_id,claimed_on) do nothing
    returning id into claim_id;

  if claim_id is not null then
    insert into public.diamond_wallets(user_id,diamonds)
      values(uid,0) on conflict(user_id) do nothing;
    update public.diamond_wallets set diamonds=diamonds+1
      where user_id=uid returning diamonds into balance;
    insert into public.diamond_transactions(user_id,amount,reason,idempotency_key)
      values(uid,1,'sponsored_ad_view',s.id);
    insert into public.advertisement_events(user_id,campaign_id,event_type)
      values(uid,s.campaign_id,'reward') on conflict do nothing;
    return jsonb_build_object('rewarded',true,'already_completed',false,'diamonds',balance);
  end if;

  select diamonds into balance from public.diamond_wallets where user_id=uid;
  return jsonb_build_object('rewarded',false,'already_completed',false,'diamonds',coalesce(balance,0));
end
$$;

revoke all on function public.record_ad_click(uuid) from public,anon;
revoke all on function public.complete_ad_view(uuid) from public,anon;
grant execute on function public.record_ad_click(uuid) to authenticated;
grant execute on function public.complete_ad_view(uuid) to authenticated;
