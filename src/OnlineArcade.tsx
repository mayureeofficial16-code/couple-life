import React from 'react'
import { supabase } from './lib/supabase'

type GameKind='tictactoe'|'connect_four'|'memory_garden'|'maze_escape'|'word_garden'|'color_reaction'
type Room={id:string;couple_id:string;game:GameKind;state:Record<string,any>;revision:number;status:'waiting'|'active'|'complete'|string;winner_id:string|null;player_a:string;player_b:string|null;invite_expires_at:string|null;updated_at:string}
type Props={coupleId:string;userId:string;displayName?:string;partnerName?:string}

const games:{id:GameKind;name:string;hint:string}[]=[
  {id:'tictactoe',name:'Tic-tac-toe',hint:'Take turns placing a symbol. First line of three wins.'},
  {id:'connect_four',name:'Connect Four',hint:'Drop a token. First line of four wins.'},
  {id:'memory_garden',name:'Memory Garden',hint:'Reveal pairs and keep your turn when you match one.'},
  {id:'maze_escape',name:'Maze Escape',hint:'Work together. Both partners need to reach the gate.'},
  {id:'word_garden',name:'Word Garden',hint:'Take turns guessing the hidden garden word.'},
  {id:'color_reaction',name:'Color Reaction',hint:'Start the round and tap after the server-set signal.'},
]
const cardArt:Record<string,string>={flower:'🌷',orange:'🍊',cat:'🐈',cake:'🧁'}

export default function OnlineArcade({coupleId,userId,displayName='You',partnerName='Your partner'}:Props){
  const [rooms,setRooms]=React.useState<Room[]>([])
  const [selectedId,setSelectedId]=React.useState('')
  const [selectedGame,setSelectedGame]=React.useState<GameKind>('tictactoe')
  const [joinCode,setJoinCode]=React.useState('')
  const [shareCode,setShareCode]=React.useState('')
  const [guess,setGuess]=React.useState('')
  const [busy,setBusy]=React.useState(false)
  const [error,setError]=React.useState('')
  const [notice,setNotice]=React.useState('')
  const selected=rooms.find(r=>r.id===selectedId)||null
  const gameName=(id:string)=>games.find(g=>g.id===id)?.name||id

  const refresh=React.useCallback(async()=>{
    if(!supabase)return
    const {data,error}=await supabase.from('game_rooms').select('id,couple_id,game,state,revision,status,winner_id,player_a,player_b,invite_expires_at,updated_at').eq('couple_id',coupleId).order('updated_at',{ascending:false}).limit(20)
    if(error)throw error
    const next=(data||[]) as Room[]
    setRooms(next)
    setSelectedId(current=>current&&next.some(r=>r.id===current)?current:(next[0]?.id||''))
  },[coupleId])

  React.useEffect(()=>{void refresh().catch(e=>setError(e.message||'Could not load game rooms.'))},[refresh])
  React.useEffect(()=>{
    if(!supabase||!coupleId)return
    const channel=supabase.channel(`couple:${coupleId}`,{config:{private:true}})
      .on('postgres_changes',{event:'*',schema:'public',table:'game_rooms',filter:`couple_id=eq.${coupleId}`},()=>void refresh().catch(e=>setError(e.message||'Game room refresh failed.')))
      .subscribe(status=>{if(status==='CHANNEL_ERROR'||status==='TIMED_OUT')setError('Live game updates are reconnecting. Your room remains saved; choose it again after reconnect.')})
    return()=>{void supabase!.removeChannel(channel)}
  },[coupleId,refresh])

  const createRoom=async()=>{
    if(!supabase)return
    setBusy(true);setError('');setNotice('');setShareCode('')
    try{
      const {data,error}=await supabase.rpc('create_game_room',{game_kind:selectedGame})
      if(error)throw error
      const row=Array.isArray(data)?data[0]:data
      if(!row?.room_id||!row?.invite_code)throw new Error('The invite could not be created.')
      setShareCode(String(row.invite_code));setSelectedId(String(row.room_id));setNotice('Share this one-time code with your partner. It expires after 24 hours.')
      await refresh()
    }catch(e){setError(e instanceof Error?e.message:'Could not create the room.')}
    finally{setBusy(false)}
  }
  const joinRoom=async(e:React.FormEvent)=>{
    e.preventDefault();if(!supabase)return
    setBusy(true);setError('');setNotice('')
    try{
      const {data,error}=await supabase.rpc('join_game_room',{input_code:joinCode.trim().toUpperCase()})
      if(error)throw error
      const row=data as {room_id:string}
      if(!row?.room_id)throw new Error('The room could not be joined.')
      setJoinCode('');setSelectedId(row.room_id);await refresh();setNotice('You joined the room. Play turns are stored on the server.')
    }catch(e){setError(e instanceof Error?e.message:'Could not join the room.')}
    finally{setBusy(false)}
  }
  const leaveRoom=async()=>{
    if(!supabase||!selected)return
    setBusy(true);setError('');setNotice('')
    const {error}=await supabase.rpc('leave_game_room',{target_room:selected.id,expected_revision:selected.revision})
    if(error){setError(error.message);await refresh().catch(()=>undefined)}else{setNotice('This room was closed for both partners.');await refresh()}
    setBusy(false)
  }
  const act=async(action:Record<string,unknown>)=>{
    if(!supabase||!selected)return
    setBusy(true);setError('');setNotice('')
    const {data,error}=await supabase.rpc('submit_game_action',{target_room:selected.id,expected_revision:selected.revision,action})
    if(error){setError(error.message.includes('ROOM_CONFLICT')?'Your partner moved first. The latest room state has been refreshed.':error.message);await refresh().catch(()=>undefined);setBusy(false);return}
    if(data&&typeof data==='object'){
      const updated=data as Room
      setRooms(old=>old.map(room=>room.id===updated.id?{...room,...updated}:room))
      if(updated.status==='complete')setNotice(updated.winner_id?`${winnerName(updated.winner_id,selected)} won the round.`:'The round is complete.')
    }
    setBusy(false)
  }
  const copyCode=async()=>{try{await navigator.clipboard.writeText(shareCode);setNotice('Invite code copied.')}catch{setNotice('Copy the code shown above to invite your partner.')}}
  const winnerName=(id:string,room:Room)=>id===userId?displayName:id===room.player_a||id===room.player_b?partnerName:'Player'

  return <section className="page-card arcade online-arcade">
    <div className="eyebrow">PLAY TOGETHER, WHEREVER YOU ARE</div>
    <h1>Online game rooms <span>♡</span></h1>
    <p className="sub">Private to your connected couple. Moves and game results are checked and saved by Supabase. No currency rewards are granted.</p>
    <div className="online-room-tools">
      <label>Choose a game<select value={selectedGame} onChange={e=>setSelectedGame(e.target.value as GameKind)}>{games.map(g=><option key={g.id} value={g.id}>{g.name}</option>)}</select></label>
      <button className="button coral" disabled={busy} onClick={()=>void createRoom()}>{busy?'Working…':'Create partner invite'}</button>
      <form onSubmit={joinRoom}><label>Partner’s invite code<input value={joinCode} onChange={e=>setJoinCode(e.target.value.toUpperCase())} minLength={16} maxLength={16} placeholder="16-character code"/></label><button className="button outline" disabled={busy||joinCode.trim().length!==16}>Join game</button></form>
    </div>
    {shareCode&&<div className="game-invite-code"><b>One-time partner code</b><code>{shareCode}</code><button className="button small" onClick={()=>void copyCode()}>Copy code</button></div>}
    {notice&&<div className="auth-notice" role="status">{notice}</div>}{error&&<div className="auth-error" role="alert">{error}</div>}
    <div className="online-game-layout">
      <aside className="online-room-list"><h2>Your couple’s rooms</h2>{rooms.length===0?<p>No rooms yet. Create an invite for your partner.</p>:rooms.map(room=><button key={room.id} className={selected?.id===room.id?'active':''} onClick={()=>{setSelectedId(room.id);setShareCode('')}}><b>{gameName(room.game)}</b><small>{room.status==='waiting'?'Waiting for your partner':room.status==='active'?'In progress':'Round complete'} · rev {room.revision}</small></button>)}</aside>
      {selected?<div className="online-game-board"><div className="stage-title"><b>{gameName(selected.game)}</b><small>{selected.status==='waiting'?'Waiting for your partner to join':selected.status==='complete'?'Round complete':selected.status==='cancelled'?'Room closed':selected.status==='expired'?'Invite expired':games.find(g=>g.id===selected.game)?.hint}</small></div>{selected.status==='waiting'?<p>Share the invite code with your partner. They must be signed in to this same couple before joining.</p>:selected.status==='complete'?<Result room={selected} userId={userId} names={{a:selected.player_a===userId?displayName:partnerName,b:selected.player_b===userId?displayName:partnerName}}/>:selected.status==='active'?<Game room={selected} userId={userId} disabled={busy} guess={guess} setGuess={setGuess} act={act}/>:<p>This room is closed. You can start a new invitation when you are ready.</p>}{['waiting','active'].includes(selected.status)&&<button className="text-button" disabled={busy} onClick={()=>void leaveRoom()}>Leave and close room</button>}<button className="text-button" onClick={()=>void refresh()}>Refresh room</button></div>:<div className="online-game-board"><p>Select a room or create an invitation to begin.</p></div>}
    </div>
  </section>
}

function Result({room,userId,names}:{room:Room;userId:string;names:{a:string;b:string}}){
  if(room.game==='maze_escape')return <div className="game-result">Both partners reached the gate.</div>
  if(room.game==='color_reaction'&&room.state.phase==='false_start')return <div className="game-result">False start · {room.winner_id===userId?'you':'your partner'} won.</div>
  if(!room.winner_id)return <div className="game-result">It’s a draw.</div>
  const winner=room.winner_id===room.player_a?names.a:room.winner_id===room.player_b?names.b:room.winner_id===userId?'you':'your partner'
  return <div className="game-result">{winner} won. This result came from the server-validated room state.</div>
}

function Game({room,userId,disabled,guess,setGuess,act}:{room:Room;userId:string;disabled:boolean;guess:string;setGuess:(value:string)=>void;act:(action:Record<string,unknown>)=>Promise<void>}){
  const state=room.state||{};const turn=state.turn===userId;const myTurn=turn||room.game==='maze_escape'||room.game==='color_reaction';
  const [signalReady,setSignalReady]=React.useState(false)
  React.useEffect(()=>{
    setSignalReady(false)
    if(room.game!=='color_reaction'||state.phase!=='waiting'||!state.start_at)return
    const delay=Math.max(0,Date.parse(state.start_at)-Date.now())
    const timer=window.setTimeout(()=>setSignalReady(true),delay)
    return()=>window.clearTimeout(timer)
  },[room.game,state.phase,state.start_at])
  if(room.game==='tictactoe'){
    const board=(state.board||[]) as number[]
    return <><p>{myTurn?`Your move · ${turn?'your turn':'partner’s turn'}`:`Waiting for ${room.player_a===userId?'your partner':'your partner'}…`}</p><div className="game-board online-ttt">{board.map((value,index)=><button className="cell" key={index} disabled={disabled||!turn||value!==0} onClick={()=>void act({type:'move',index})}>{value===1?'♡':value===2?'✿':''}</button>)}</div></>
  }
  if(room.game==='connect_four'){
    const board=(state.board||Array(42).fill(0)) as number[]
    return <><p>{turn?'Your move · choose a column':'Waiting for your partner’s move'}</p><div className="connect-room"><div className="connect-drop">{Array.from({length:7},(_,column)=><button key={column} disabled={disabled||!turn} onClick={()=>void act({type:'drop',column})} aria-label={`Drop in column ${column+1}`}>↓</button>)}</div><div className="connect-board">{board.map((value,index)=><div key={index} className={`connect-hole ${value?'filled':''}`} aria-label={value===1?'Partner A token':value===2?'Partner B token':'Empty'}>{value===1?'♡':value===2?'✿':''}</div>)}</div></div></>
  }
  if(room.game==='memory_garden'){
    const matched=(state.matched||[]) as number[];const shown=(state.revealed_values||{}) as Record<string,string>;const scores=(state.scores||{}) as Record<string,number>
    return <><p>{turn?`Your turn · pairs ${scores[userId]||0}`:'Waiting for your partner'} · matched {matched.length/2} of 4</p><div className="memory-board online-memory">{Array.from({length:8},(_,index)=>{const value=shown[String(index)];return <button key={index} disabled={disabled||!turn||matched.includes(index)||!!value} className={`memory-card ${value||matched.includes(index)?'revealed':''}`} onClick={()=>void act({type:'flip',index})}>{value?cardArt[value]||'✦':matched.includes(index)?cardArt[value]||'✦':'✿'}</button>})}</div></>
  }
  if(room.game==='maze_escape'){
    const positions=(state.positions||{}) as Record<string,{x:number;y:number}>
    const own=positions[userId]||{x:0,y:0};const otherId=room.player_a===userId?room.player_b:room.player_a;const partner=otherId?positions[otherId]||{x:0,y:0}:{x:0,y:0}
    return <><p>Cooperative maze · your position {own.x+1},{own.y+1} · partner {partner.x+1},{partner.y+1}</p><div className="maze-grid online-maze">{Array.from({length:25},(_,index)=>{const x=index%5,y=Math.floor(index/5),wall=(x===1&&y<4)||(x===3&&y>0&&y<4),isYou=own.x===x&&own.y===y,isPartner=partner.x===x&&partner.y===y;return <button key={index} disabled={disabled||wall||Math.abs(x-own.x)+Math.abs(y-own.y)!==1} className={`maze-cell ${wall?'wall':''} ${isYou?'here':''} ${x===4&&y===4?'goal':''}`} onClick={()=>void act({type:'move',dx:x-own.x,dy:y-own.y})}>{isYou?(isPartner?'♡✿':'♡'):isPartner?'✿':x===4&&y===4?'✿':''}</button>})}</div></>
  }
  if(room.game==='word_garden')return <><p>{turn?'Your turn to guess':'Waiting for your partner’s guess'} · attempts {state.guesses||0}</p><form className="word-entry" onSubmit={e=>{e.preventDefault();if(turn&&guess.trim()){void act({type:'guess',guess});setGuess('')}}}><input value={guess} onChange={e=>setGuess(e.target.value)} maxLength={40} placeholder="Enter one word" disabled={disabled||!turn}/><button className="button plum" disabled={disabled||!turn||!guess.trim()}>Guess</button></form>{state.last_guess&&<p>Last guess: {state.last_guess}</p>}</>
  if(room.game==='color_reaction')return <><p>{state.phase==='ready'?'Start the server-timed round when you are ready.':state.phase==='waiting'?signalReady?'The signal is live. Tap now!':`Wait for the signal (${new Date(state.start_at).toLocaleTimeString()}).`:'Round state unavailable'}</p><button className="button coral reaction-field" disabled={disabled||state.phase==='false_start'||state.phase==='complete'||(state.phase==='waiting'&&!signalReady)} onClick={()=>void act({type:state.phase==='ready'?'start':'tap'})}>{state.phase==='ready'?'Start reaction round':state.phase==='waiting'?signalReady?'TAP NOW!':'Wait…':'Round complete'}</button></>
  return <p>Unsupported game room.</p>
}
