-- Couple-private, server-authoritative rooms for the six existing arcade games.
alter table public.game_rooms add column if not exists player_a uuid references auth.users(id) on delete cascade;
alter table public.game_rooms add column if not exists player_b uuid references auth.users(id) on delete cascade;
alter table public.game_rooms add column if not exists invite_code_hash text;
alter table public.game_rooms add column if not exists invite_expires_at timestamptz;
alter table public.game_rooms add column if not exists revision bigint not null default 0;
alter table public.game_rooms add column if not exists winner_id uuid references auth.users(id) on delete set null;
alter table public.game_rooms add column if not exists started_at timestamptz;
alter table public.game_rooms add column if not exists finished_at timestamptz;
create unique index if not exists game_room_invite_hash_unique on public.game_rooms(invite_code_hash) where invite_code_hash is not null;
create index if not exists game_rooms_couple_updated on public.game_rooms(couple_id,updated_at desc);

create table if not exists public.game_room_private (
  room_id uuid primary key references public.game_rooms(id) on delete cascade,
  memory_deck jsonb not null default '[]',
  word_answer text not null default 'sunshine',
  created_at timestamptz not null default now()
);
alter table public.game_room_private enable row level security;
revoke all on public.game_room_private from public,anon,authenticated;

-- Helper is used only inside the locked game action RPC.
create or replace function public.game_line_winner(board integer[], row_count integer, column_count integer, required_length integer)
returns integer language plpgsql immutable set search_path=public as $$
declare r integer; c integer; dr integer; dc integer; player integer; n integer; won boolean;
begin
  for r in 0..row_count-1 loop
    for c in 0..column_count-1 loop
      player:=board[r*column_count+c+1];
      if player=0 then continue; end if;
      for dr in -1..1 loop
        for dc in -1..1 loop
          if dr=0 and dc=0 then continue; end if;
          if r+dr*(required_length-1)<0 or r+dr*(required_length-1)>=row_count or c+dc*(required_length-1)<0 or c+dc*(required_length-1)>=column_count then continue; end if;
          won:=true;
          for n in 1..required_length-1 loop
            if board[(r+dr*n)*column_count+(c+dc*n)+1]<>player then won:=false; exit; end if;
          end loop;
          if won then return player; end if;
        end loop;
      end loop;
    end loop;
  end loop;
  return 0;
end
$$;
revoke all on function public.game_line_winner(integer[],integer,integer,integer) from public,anon,authenticated;

create or replace function public.create_game_room(game_kind text)
returns table(room_id uuid, game text, invite_code text, invite_expires_at timestamptz)
language plpgsql security definer set search_path=public,extensions as $$
declare uid uuid:=auth.uid(); cid uuid; code text; new_id uuid; initial_state jsonb; deck jsonb; private_word text;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if game_kind is null or game_kind not in ('tictactoe','connect_four','memory_garden','maze_escape','word_garden','color_reaction') then raise exception 'Unknown game'; end if;
  select couple_id into cid from public.couple_members where user_id=uid and approved_at is not null;
  if cid is null or (select count(*) from public.couple_members where couple_id=cid and approved_at is not null)<>2 then raise exception 'Connect both partners before starting a game'; end if;
  perform 1 from public.couples where id=cid for update;
  -- Retire legacy waiting rows from before player assignments/invite hashes existed.
  -- Keep their records; only close invitations that cannot be resumed securely.
  update public.game_rooms set status='expired',revision=revision+1,updated_at=now()
    where couple_id=cid and status='waiting' and (invite_expires_at is null or invite_expires_at<=now());
  if exists(select 1 from public.game_rooms where couple_id=cid and status in ('waiting','active') and player_a is not null) then raise exception 'Finish or leave your current game room first'; end if;
  code:=upper(encode(extensions.gen_random_bytes(8),'hex'));
  initial_state:=case game_kind
    when 'tictactoe' then jsonb_build_object('board',jsonb_build_array(0,0,0,0,0,0,0,0,0),'turn',uid,'moves',0)
    when 'connect_four' then jsonb_build_object('board',to_jsonb(array_fill(0,ARRAY[42])),'turn',uid,'moves',0)
    when 'memory_garden' then jsonb_build_object('turn',uid,'open','[]'::jsonb,'matched','[]'::jsonb,'revealed_values','{}'::jsonb,'scores',jsonb_build_object(uid::text,0),'moves',0)
    when 'maze_escape' then jsonb_build_object('positions',jsonb_build_object(uid::text,jsonb_build_object('x',0,'y',0)),'moves',0)
    when 'word_garden' then jsonb_build_object('turn',uid,'guesses',0)
    else jsonb_build_object('phase','ready','start_at',null,'response_ms',null)
  end;
  insert into public.game_rooms(couple_id,game,state,status,player_a,invite_code_hash,invite_expires_at,revision)
  values(cid,game_kind,initial_state,'waiting',uid,encode(extensions.digest(code,'sha256'),'hex'),now()+interval '24 hours',0)
  returning id into new_id;
  select jsonb_agg(card order by random()) into deck from unnest(array['flower','flower','orange','orange','cat','cat','cake','cake']) card;
  select word into private_word from unnest(array['sunshine','garden','cuddle','moonlight','rainbow','together']) as words(word) order by random() limit 1;
  insert into public.game_room_private(room_id,memory_deck,word_answer) values(new_id,coalesce(deck,'[]'::jsonb),private_word);
  return query select new_id,game_kind,code,now()+interval '24 hours';
end
$$;

create or replace function public.join_game_room(input_code text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare uid uuid:=auth.uid(); cid uuid; room public.game_rooms%rowtype; room_state jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if input_code is null or length(trim(input_code))<>16 then raise exception 'Game invite code is invalid'; end if;
  select couple_id into cid from public.couple_members where user_id=uid and approved_at is not null;
  if cid is null then raise exception 'Connect your partner before joining a game'; end if;
  select * into room from public.game_rooms where invite_code_hash=encode(extensions.digest(upper(trim(input_code)),'sha256'),'hex') for update;
  if not found or room.status<>'waiting' or room.invite_expires_at<=now() then raise exception 'Game invite is expired or already used'; end if;
  if room.couple_id<>cid then raise exception 'This game invite belongs to another couple'; end if;
  if room.player_a=uid then raise exception 'The room creator cannot join their own invite'; end if;
  if room.player_b is not null then raise exception 'This game already has both partners'; end if;
  room_state:=room.state;
  if room.game='maze_escape' then
    room_state:=jsonb_set(room_state,'{positions}',coalesce(room_state->'positions','{}'::jsonb)||jsonb_build_object(uid::text,jsonb_build_object('x',0,'y',0)),true);
  elsif room.game in ('tictactoe','connect_four','memory_garden','word_garden') then
    room_state:=jsonb_set(room_state,'{turn}',to_jsonb(room.player_a::text),true);
  end if;
  if room.game='memory_garden' then room_state:=jsonb_set(room_state,'{scores}',jsonb_build_object(room.player_a::text,0,uid::text,0),true); end if;
  update public.game_rooms set player_b=uid,invite_code_hash=null,state=room_state,status='active',started_at=now(),revision=revision+1,updated_at=now() where id=room.id;
  return jsonb_build_object('room_id',room.id,'game',room.game,'state',room_state,'revision',room.revision+1,'status','active','player_a',room.player_a,'player_b',uid);
end
$$;

create or replace function public.leave_game_room(target_room uuid, expected_revision bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); room public.game_rooms%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into room from public.game_rooms where id=target_room for update;
  if not found or room.status not in ('waiting','active') then raise exception 'Game room is already closed'; end if;
  if uid is distinct from room.player_a and uid is distinct from room.player_b then raise exception 'You are not a player in this room'; end if;
  if not public.is_couple_member(room.couple_id) then raise exception 'Couple access required'; end if;
  if expected_revision is null or expected_revision<>room.revision then raise exception 'ROOM_CONFLICT'; end if;
  update public.game_rooms set status='cancelled',invite_code_hash=null,revision=revision+1,updated_at=now() where id=room.id returning * into room;
  return jsonb_build_object('room_id',room.id,'status',room.status,'revision',room.revision);
end
$$;

create or replace function public.submit_game_action(target_room uuid, expected_revision bigint, action jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare
  uid uuid:=auth.uid(); room public.game_rooms%rowtype; priv public.game_room_private%rowtype;
  s jsonb; kind text; action_kind text; board integer[]; idx integer; col integer; row_idx integer;
  token integer; line_winner integer; move_count integer; next_status text:='active'; win_id uuid;
  p1 uuid; p2 uuid; turn_id uuid; dx integer; dy integer; x0 integer; y0 integer; x1 integer; y1 integer;
  open_pair integer[]; matched jsonb; reveal jsonb; deck jsonb; first_card text; second_card text;
  scores jsonb; score_a integer; score_b integer; guess_text text; answer text; start_at timestamptz; response_ms integer;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if action is null or jsonb_typeof(action)<>'object' or octet_length(action::text)>2048 then raise exception 'Game action is invalid'; end if;
  select * into room from public.game_rooms where id=target_room for update;
  if not found or room.status<>'active' then raise exception 'Game room is not active'; end if;
  if uid is distinct from room.player_a and uid is distinct from room.player_b then raise exception 'You are not a player in this room'; end if;
  if not public.is_couple_member(room.couple_id) then raise exception 'Couple access required'; end if;
  if expected_revision is null or expected_revision<>room.revision then raise exception 'ROOM_CONFLICT'; end if;
  s:=room.state; kind:=room.game; action_kind:=action->>'type'; p1:=room.player_a; p2:=room.player_b;

  if kind in ('tictactoe','connect_four','memory_garden','word_garden') and (s->>'turn')::uuid<>uid then raise exception 'Wait for your turn'; end if;

  if kind='tictactoe' then
    if action_kind<>'move' then raise exception 'Unknown tic-tac-toe action'; end if;
    idx:=(action->>'index')::integer;
    if idx is null or idx<0 or idx>8 then raise exception 'Choose a square on the board'; end if;
    select array_agg(value::integer order by ordinality) into board from jsonb_array_elements_text(s->'board') with ordinality;
    if board[idx+1]<>0 then raise exception 'That square is already taken'; end if;
    token:=case when uid=p1 then 1 else 2 end; board[idx+1]:=token; move_count:=coalesce((s->>'moves')::integer,0)+1;
    line_winner:=public.game_line_winner(board,3,3,3);
    if line_winner<>0 then next_status:='complete';win_id:=case when line_winner=1 then p1 else p2 end;
    elsif move_count=9 then next_status:='complete'; end if;
    s:=jsonb_build_object('board',to_jsonb(board),'turn',case when next_status='active' then case when uid=p1 then p2 else p1 end else uid end,'moves',move_count);

  elsif kind='connect_four' then
    if action_kind<>'drop' then raise exception 'Unknown Connect Four action'; end if;
    col:=(action->>'column')::integer;
    if col is null or col<0 or col>6 then raise exception 'Choose a column from 1 to 7'; end if;
    select array_agg(value::integer order by ordinality) into board from jsonb_array_elements_text(s->'board') with ordinality;
    row_idx:=5;while row_idx>=0 and board[row_idx*7+col+1]<>0 loop row_idx:=row_idx-1;end loop;
    if row_idx<0 then raise exception 'That column is full'; end if;
    token:=case when uid=p1 then 1 else 2 end;board[row_idx*7+col+1]:=token;move_count:=coalesce((s->>'moves')::integer,0)+1;
    line_winner:=public.game_line_winner(board,6,7,4);
    if line_winner<>0 then next_status:='complete';win_id:=case when line_winner=1 then p1 else p2 end;
    elsif move_count=42 then next_status:='complete'; end if;
    s:=jsonb_build_object('board',to_jsonb(board),'turn',case when next_status='active' then case when uid=p1 then p2 else p1 end else uid end,'moves',move_count);

  elsif kind='memory_garden' then
    if action_kind<>'flip' then raise exception 'Unknown Memory Garden action'; end if;
    idx:=(action->>'index')::integer;if idx is null or idx<0 or idx>7 then raise exception 'Choose a card on the board';end if;
    select * into priv from public.game_room_private where room_id=room.id for update;
    matched:=coalesce(s->'matched','[]'::jsonb);reveal:=coalesce(s->'revealed_values','{}'::jsonb);
    if exists(select 1 from jsonb_array_elements_text(matched) m where m::integer=idx) then raise exception 'That pair is already matched';end if;
    open_pair:=array(select value::integer from jsonb_array_elements_text(coalesce(s->'open','[]'::jsonb)));
    if cardinality(open_pair)=2 then
      reveal:=coalesce(s->'matched_values','{}'::jsonb);open_pair:='{}';
    end if;
    if idx=any(open_pair) then raise exception 'Choose a different card'; end if;
    deck:=priv.memory_deck;second_card:=deck->>idx;
    if cardinality(open_pair)=0 then
      s:=s||jsonb_build_object('open',jsonb_build_array(idx),'revealed_values',reveal||jsonb_build_object(idx::text,second_card),'moves',coalesce((s->>'moves')::integer,0));
    else
      idx:=idx;first_card:=deck->>open_pair[1];move_count:=coalesce((s->>'moves')::integer,0)+1;
      scores:=coalesce(s->'scores','{}'::jsonb);score_a:=coalesce((scores->>uid::text)::integer,0);score_b:=score_a;
      reveal:=reveal||jsonb_build_object(open_pair[1]::text,first_card,idx::text,second_card);
      if first_card=second_card then
        matched:=matched||to_jsonb(open_pair[1])||to_jsonb(idx);score_a:=score_a+1;
        scores:=jsonb_set(scores,array[uid::text],to_jsonb(score_a),true);
        s:=s||jsonb_build_object('open','[]'::jsonb,'matched',matched,'revealed_values',reveal,'matched_values',reveal,'scores',scores,'moves',move_count);
        if jsonb_array_length(matched)=8 then
          next_status:='complete';score_a:=coalesce((scores->>p1::text)::integer,0);score_b:=coalesce((scores->>p2::text)::integer,0);
          if score_a>score_b then win_id:=p1;elsif score_b>score_a then win_id:=p2;end if;
        end if;
      else
        s:=s||jsonb_build_object('open',to_jsonb(open_pair||idx),'revealed_values',reveal,'matched',matched,'matched_values',coalesce(s->'matched_values','{}'::jsonb),'turn',case when uid=p1 then p2 else p1 end,'moves',move_count);
      end if;
    end if;

  elsif kind='maze_escape' then
    if action_kind<>'move' then raise exception 'Unknown maze action';end if;
    dx:=(action->>'dx')::integer;dy:=(action->>'dy')::integer;
    if dx is null or dy is null or abs(dx)+abs(dy)<>1 then raise exception 'Move one tile at a time';end if;
    x0:=(s->'positions'->uid::text->>'x')::integer;y0:=(s->'positions'->uid::text->>'y')::integer;
    x1:=x0+dx;y1:=y0+dy;
    if x1<0 or x1>4 or y1<0 or y1>4 or (x1=1 and y1<4) or (x1=3 and y1>0 and y1<4) then raise exception 'That maze tile is blocked';end if;
    s:=jsonb_set(s,array['positions',uid::text],jsonb_build_object('x',x1,'y',y1),true)||jsonb_build_object('moves',coalesce((s->>'moves')::integer,0)+1);
    if (s->'positions'->p1::text->>'x')::integer=4 and (s->'positions'->p1::text->>'y')::integer=4 and (s->'positions'->p2::text->>'x')::integer=4 and (s->'positions'->p2::text->>'y')::integer=4 then next_status:='complete';win_id:=null;end if;

  elsif kind='word_garden' then
    if action_kind<>'guess' then raise exception 'Unknown Word Garden action';end if;
    guess_text:=lower(trim(coalesce(action->>'guess','')));if length(guess_text)<1 or length(guess_text)>40 then raise exception 'Enter a word of 1 to 40 letters';end if;
    select word_answer into answer from public.game_room_private where room_id=room.id;
    move_count:=coalesce((s->>'guesses')::integer,0)+1;
    s:=s||jsonb_build_object('guesses',move_count,'last_guess',guess_text);
    if guess_text=answer then next_status:='complete';win_id:=uid;else s:=s||jsonb_build_object('turn',case when uid=p1 then p2 else p1 end);end if;

  elsif kind='color_reaction' then
    if action_kind='start' then
      if s->>'phase'<>'ready' then raise exception 'The reaction round has already started';end if;
      start_at:=now()+make_interval(secs=>(2+floor(random()*4))::integer);
      s:=s||jsonb_build_object('phase','waiting','start_at',start_at);
    elsif action_kind='tap' then
      if s->>'phase'<>'waiting' then raise exception 'Start the reaction round first';end if;
      start_at:=(s->>'start_at')::timestamptz;
      if now()<start_at then next_status:='complete';win_id:=case when uid=p1 then p2 else p1 end;s:=s||jsonb_build_object('phase','false_start','false_starter',uid);
      else next_status:='complete';win_id:=uid;response_ms:=floor(extract(epoch from now()-start_at)*1000)::integer;s:=s||jsonb_build_object('phase','complete','response_ms',response_ms,'winner_id',uid);end if;
    else raise exception 'Unknown Color Reaction action';end if;
  else
    raise exception 'Unsupported game';
  end if;

  update public.game_rooms set state=s,status=next_status,winner_id=case when next_status='complete' then win_id else null end,
    finished_at=case when next_status='complete' then now() else null end,revision=revision+1,updated_at=now() where id=room.id returning * into room;
  return jsonb_build_object('room_id',room.id,'game',room.game,'state',room.state,'revision',room.revision,'status',room.status,'winner_id',room.winner_id,'player_a',room.player_a,'player_b',room.player_b);
end
$$;

revoke all on function public.create_game_room(text) from public,anon;
revoke all on function public.join_game_room(text) from public,anon;
revoke all on function public.leave_game_room(uuid,bigint) from public,anon;
revoke all on function public.submit_game_action(uuid,bigint,jsonb) from public,anon;
grant execute on function public.create_game_room(text) to authenticated;
grant execute on function public.join_game_room(text) to authenticated;
grant execute on function public.leave_game_room(uuid,bigint) to authenticated;
grant execute on function public.submit_game_action(uuid,bigint,jsonb) to authenticated;
revoke insert,update,delete on public.game_rooms from anon,authenticated;
