create extension if not exists pgcrypto;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  display_name text not null,
  avatar_url text,
  created_at timestamptz not null default now()
);
create table public.couples (
  id uuid primary key default gen_random_uuid(),
  anniversary date,
  privacy text not null default 'private' check (privacy in ('private','friends','public')),
  created_at timestamptz not null default now()
);
create table public.couple_members (
  couple_id uuid not null references public.couples(id) on delete cascade,
  user_id uuid not null unique references auth.users(id) on delete cascade,
  approved_at timestamptz,
  primary key (couple_id,user_id)
);
create table public.invitations (
  id uuid primary key default gen_random_uuid(), couple_id uuid not null references public.couples(id) on delete cascade,
  code_hash text unique not null, expires_at timestamptz not null, redeemed_by uuid references auth.users(id),
  created_by uuid not null references auth.users(id), created_at timestamptz not null default now()
);
create table public.worlds (
  couple_id uuid primary key references public.couples(id) on delete cascade,
  state jsonb not null default '{"theme":"Malaysia","plot":"starter"}', updated_at timestamptz not null default now()
);
create table public.wallets (
  couple_id uuid primary key references public.couples(id) on delete cascade, coins bigint not null default 480 check(coins>=0)
);
create table public.diamond_wallets (
  user_id uuid primary key references auth.users(id) on delete cascade, diamonds bigint not null default 0 check(diamonds>=0)
);
create table public.wallet_transactions (
  id uuid primary key default gen_random_uuid(), couple_id uuid not null references public.couples(id),
  actor_id uuid not null references auth.users(id), amount bigint not null, reason text not null, created_at timestamptz not null default now()
);
create table public.diamond_transactions (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id), amount bigint not null,
  reason text not null, created_at timestamptz not null default now()
);
create table public.relationship_dates (id uuid primary key default gen_random_uuid(), couple_id uuid not null references public.couples(id) on delete cascade, title text not null, event_date date not null, kind text not null default 'special');
create table public.posts (id uuid primary key default gen_random_uuid(), couple_id uuid not null references public.couples(id) on delete cascade, author_id uuid not null references auth.users(id), body text not null, created_at timestamptz not null default now());
create table public.comments (id uuid primary key default gen_random_uuid(), post_id uuid not null references public.posts(id) on delete cascade, author_id uuid not null references auth.users(id), body text not null, created_at timestamptz not null default now());
create table public.reactions (post_id uuid not null references public.posts(id) on delete cascade, user_id uuid not null references auth.users(id), reaction text not null, primary key(post_id,user_id));
create table public.game_rooms (id uuid primary key default gen_random_uuid(), couple_id uuid not null references public.couples(id) on delete cascade, game text not null, state jsonb not null default '{}', status text not null default 'waiting', updated_at timestamptz not null default now());
create table public.businesses (id uuid primary key default gen_random_uuid(), couple_id uuid not null references public.couples(id) on delete cascade, kind text not null, level integer not null default 1 check(level>0), opened_at timestamptz not null default now(), collected_at timestamptz not null default now());
create table public.pets (id uuid primary key default gen_random_uuid(), couple_id uuid not null references public.couples(id) on delete cascade, name text not null, kind text not null, happiness integer not null default 90 check(happiness between 0 and 100), hunger integer not null default 15 check(hunger between 0 and 100));
create table public.inventory (id uuid primary key default gen_random_uuid(), couple_id uuid not null references public.couples(id) on delete cascade, item_id text not null, quantity integer not null default 1 check(quantity>0), unique(couple_id,item_id));

create function public.is_couple_member(target uuid) returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.couple_members where couple_id=target and user_id=auth.uid() and approved_at is not null)
$$;
alter table public.profiles enable row level security;
alter table public.couples enable row level security;
alter table public.couple_members enable row level security;
alter table public.worlds enable row level security;
alter table public.wallets enable row level security;
alter table public.diamond_wallets enable row level security;
alter table public.wallet_transactions enable row level security;
alter table public.diamond_transactions enable row level security;
alter table public.relationship_dates enable row level security;
alter table public.posts enable row level security;
alter table public.comments enable row level security;
alter table public.reactions enable row level security;
alter table public.game_rooms enable row level security;
alter table public.businesses enable row level security;
alter table public.pets enable row level security;
alter table public.inventory enable row level security;
create policy "read own profile" on public.profiles for select using(id=auth.uid());
create policy "update own profile" on public.profiles for update using(id=auth.uid());
create policy "read member couples" on public.couples for select using(public.is_couple_member(id));
create policy "read couple membership" on public.couple_members for select using(public.is_couple_member(couple_id) or user_id=auth.uid());
create policy "members read world" on public.worlds for select using(public.is_couple_member(couple_id));
create policy "members update world" on public.worlds for update using(public.is_couple_member(couple_id)) with check(public.is_couple_member(couple_id));
create policy "members read wallet" on public.wallets for select using(public.is_couple_member(couple_id));
create policy "owner read diamonds" on public.diamond_wallets for select using(user_id=auth.uid());
create policy "members read wallet history" on public.wallet_transactions for select using(public.is_couple_member(couple_id));
create policy "owner read diamond history" on public.diamond_transactions for select using(user_id=auth.uid());
create policy "members manage dates" on public.relationship_dates for all using(public.is_couple_member(couple_id)) with check(public.is_couple_member(couple_id));
create policy "members manage posts" on public.posts for all using(public.is_couple_member(couple_id)) with check(public.is_couple_member(couple_id) and author_id=auth.uid());
create policy "members read games" on public.game_rooms for select using(public.is_couple_member(couple_id));
create policy "members manage businesses" on public.businesses for all using(public.is_couple_member(couple_id)) with check(public.is_couple_member(couple_id));
create policy "members manage pets" on public.pets for all using(public.is_couple_member(couple_id)) with check(public.is_couple_member(couple_id));
create policy "members manage inventory" on public.inventory for all using(public.is_couple_member(couple_id)) with check(public.is_couple_member(couple_id));

-- Production currency changes belong in SECURITY DEFINER RPCs with row locking,
-- idempotency keys, and an authenticated actor check; the browser prototype never
-- connects to this schema and does not present its simulated coins as verified.
