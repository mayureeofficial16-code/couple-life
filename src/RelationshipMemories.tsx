import React from 'react'
import { supabase } from './lib/supabase'

type Comment = { id:string; author_id:string; body:string; created_at:string }
type Memory = { id:string; author_id:string; body:string; created_at:string; media_path:string|null; media_type:'image'|'video'|null; authorName:string; mediaUrl?:string; comments:Comment[]; reactions:{user_id:string;reaction:string}[] }
type Props = {
  connected:boolean; coupleId?:string; userId?:string; partnerName:string
  anniversary:string; birthday:string; nickname:string; demoPost:string
  onDemoPost:(value:string)=>void; onSaveDetails:(anniversary:string,birthday:string,nickname:string)=>Promise<void>
  notify:(message:string)=>void
}

const localKey='couple-life-memory-timeline'
const formats=new Set(['image/jpeg','image/png','image/webp','video/mp4','video/webm'])
const mediaExtensions:Record<string,string>={'image/jpeg':'jpg','image/png':'png','image/webp':'webp','video/mp4':'mp4','video/webm':'webm'}

export default function RelationshipMemories(props:Props){
  const {connected,coupleId,userId,partnerName,anniversary,birthday,nickname,demoPost,onDemoPost,onSaveDetails,notify}=props
  const [items,setItems]=React.useState<Memory[]>([])
  const [draft,setDraft]=React.useState('')
  const [selectedFile,setSelectedFile]=React.useState<File|null>(null)
  const [comments,setComments]=React.useState<Record<string,string>>({})
  const [details,setDetails]=React.useState({anniversary,birthday,nickname})
  const [busy,setBusy]=React.useState(false)
  const [error,setError]=React.useState('')

  React.useEffect(()=>setDetails({anniversary,birthday,nickname}),[anniversary,birthday,nickname])
  const load=React.useCallback(async()=>{
    if(!connected||!coupleId||!supabase)return
    const {data:posts,error:postError}=await supabase.from('posts').select('id,author_id,body,created_at,media_path,media_type').eq('couple_id',coupleId).order('created_at',{ascending:false}).limit(50)
    if(postError)throw postError
    const rows=posts||[]
    if(!rows.length){setItems([]);setError('');return}
    const ids=rows.map(x=>x.id)
    const authors=[...new Set(rows.map(x=>x.author_id))]
    const [profileResult,commentResult,reactionResult]=await Promise.all([
      supabase.from('profiles').select('id,display_name').in('id',authors),
      supabase.from('comments').select('id,post_id,author_id,body,created_at').in('post_id',ids).order('created_at'),
      supabase.from('reactions').select('post_id,user_id,reaction').in('post_id',ids),
    ])
    if(profileResult.error)throw profileResult.error
    if(commentResult.error)throw commentResult.error
    if(reactionResult.error)throw reactionResult.error
    const names=new Map((profileResult.data||[]).map(x=>[x.id,x.display_name]))
    const commentRows=commentResult.data||[]
    const reactionRows=reactionResult.data||[]
    const mapped=await Promise.all(rows.map(async row=>{
      let mediaUrl:string|undefined
      if(row.media_path){const {data,error}=await supabase!.storage.from('couple-media').createSignedUrl(row.media_path,3600);if(!error)mediaUrl=data?.signedUrl}
      return {...row,media_type:row.media_type as Memory['media_type'],authorName:names.get(row.author_id)||'Your partner',mediaUrl,comments:commentRows.filter(c=>c.post_id===row.id),reactions:reactionRows.filter(r=>r.post_id===row.id)}
    }))
    setItems(mapped);setError('')
  },[connected,coupleId])

  React.useEffect(()=>{
    if(connected){void load().catch(e=>setError(e instanceof Error?e.message:'Could not load your memories.'));return}
    try{
      const saved=JSON.parse(localStorage.getItem(localKey)||'[]') as Memory[]
      if(saved.length){setItems(saved);return}
      if(demoPost)setItems([{id:'legacy-demo-memory',author_id:'local',body:demoPost,created_at:new Date().toISOString(),media_path:null,media_type:null,authorName:'You',comments:[],reactions:[]}])
      else setItems([])
    }catch{setItems([])}
  },[connected,load,demoPost])
  React.useEffect(()=>{
    if(!connected||!coupleId||!supabase)return
    const channel=supabase.channel(`couple:${coupleId}`,{config:{private:true}})
      .on('postgres_changes',{event:'*',schema:'public',table:'posts',filter:`couple_id=eq.${coupleId}`},()=>void load().catch(e=>setError(e.message)))
      .on('postgres_changes',{event:'*',schema:'public',table:'comments'},()=>void load().catch(e=>setError(e.message)))
      .on('postgres_changes',{event:'*',schema:'public',table:'reactions'},()=>void load().catch(e=>setError(e.message)))
      .subscribe()
    return()=>{void supabase!.removeChannel(channel)}
  },[connected,coupleId,load])

  const createMemory=async()=>{
    const body=draft.trim()
    if(!body&&!selectedFile){notify('Write a little note or choose a photo or video first.');return}
    if(!connected){
      const item:Memory={id:crypto.randomUUID(),author_id:'local',body,created_at:new Date().toISOString(),media_path:null,media_type:null,authorName:'You',comments:[],reactions:[]}
      const next=[item,...items].slice(0,50);setItems(next);localStorage.setItem(localKey,JSON.stringify(next));onDemoPost(body);setDraft('');setSelectedFile(null);notify('Memory saved on this device.');return
    }
    if(!supabase||!coupleId||!userId)return
    setBusy(true);setError('')
    let path:string|undefined
    try{
      let mediaType:'image'|'video'|null=null
      if(selectedFile){
        if(!formats.has(selectedFile.type))throw new Error('Choose a JPG, PNG, WebP, MP4 or WebM file.')
        if(selectedFile.size>10*1024*1024)throw new Error('Choose a file smaller than 10 MB.')
        mediaType=selectedFile.type.startsWith('image/')?'image':'video'
        path=`${coupleId}/${userId}/${crypto.randomUUID()}.${mediaExtensions[selectedFile.type]}`
        const {error:uploadError}=await supabase.storage.from('couple-media').upload(path,selectedFile,{contentType:selectedFile.type,upsert:false})
        if(uploadError)throw uploadError
      }
      const {error:insertError}=await supabase.from('posts').insert({couple_id:coupleId,author_id:userId,body:body||'Shared a moment together.',media_path:path||null,media_type:path?mediaType:null})
      if(insertError){if(path)await supabase.storage.from('couple-media').remove([path]);throw insertError}
      setDraft('');setSelectedFile(null);await load();notify('Memory added to your shared timeline.')
    }catch(e){setError(e instanceof Error?e.message:'Could not save this memory.')}
    finally{setBusy(false)}
  }

  const toggleReaction=async(item:Memory)=>{
    if(!connected||!supabase||!userId){notify('Reactions are saved in connected couple worlds.');return}
    const existing=item.reactions.find(r=>r.user_id===userId&&r.reaction==='heart')
    const result=existing
      ?await supabase.from('reactions').delete().eq('post_id',item.id).eq('user_id',userId)
      :await supabase.from('reactions').insert({post_id:item.id,user_id:userId,reaction:'heart'})
    if(result.error){setError(result.error.message);return}
    await load()
  }
  const addComment=async(id:string)=>{
    const body=(comments[id]||'').trim()
    if(!body||!connected||!supabase||!userId)return
    if(body.length>1200){setError('Keep a comment under 1,200 characters.');return}
    const {error}=await supabase.from('comments').insert({post_id:id,author_id:userId,body})
    if(error){setError(error.message);return}
    setComments(s=>({...s,[id]:''}));await load()
  }
  const saveDetails=async(e:React.FormEvent)=>{e.preventDefault();setBusy(true);setError('');try{await onSaveDetails(details.anniversary,details.birthday,details.nickname);notify('Couple details saved.')}catch(e){setError(e instanceof Error?e.message:'Could not save couple details.')}finally{setBusy(false)}}

  return <section className="page-card relationship"><div className="eyebrow">YOUR LITTLE CORNER</div><h1>A life, side by side <span>♡</span></h1><p className="sub">All your favorite moments in one cozy place.</p>
    <div className="love-stats"><div><b>{anniversary?daysTogether(anniversary):'—'}</b><small>days together</small></div><div><b>2</b><small>hearts at home</small></div><div><b>{items.length}</b><small>saved moments</small></div></div>
    <form className="relationship-details" onSubmit={saveDetails}><label className="label">OUR ANNIVERSARY<input type="date" required value={details.anniversary} onChange={e=>setDetails(s=>({...s,anniversary:e.target.value}))}/></label>{connected&&<label className="label">YOUR BIRTHDAY <span className="optional">private to your couple</span><input type="date" value={details.birthday} onChange={e=>setDetails(s=>({...s,birthday:e.target.value}))}/></label>}<label className="label">OUR NICKNAME <span className="optional">optional</span><input maxLength={40} value={details.nickname} onChange={e=>setDetails(s=>({...s,nickname:e.target.value}))} placeholder="Our little team"/></label><button className="button outline" disabled={busy}>{busy?'Saving…':'Save couple details'}</button></form>
    <div className="divider"/><h2>Little moments</h2><p className="sub">A private timeline shared with {partnerName||'your partner'}.</p>
    <div className="compose"><span>🌼</span><textarea maxLength={2000} value={draft} onChange={e=>setDraft(e.target.value)} placeholder="Save a sweet little memory…"/><button className="button coral" disabled={busy} onClick={()=>void createMemory()}>{busy?'Saving…':'Save memory'}</button></div>
    {connected&&<div className="memory-attachment"><label className="button small">Add a photo or video<input type="file" accept="image/jpeg,image/png,image/webp,video/mp4,video/webm" onChange={e=>setSelectedFile(e.target.files?.[0]||null)}/></label><small>{selectedFile?`${selectedFile.name} · ${(selectedFile.size/1024/1024).toFixed(1)} MB`:'Private upload · up to 10 MB'}</small>{selectedFile&&<button type="button" className="text-button" onClick={()=>setSelectedFile(null)}>Remove</button>}</div>}
    {error&&<div className="auth-error" role="alert">{error}</div>}
    {items.length===0&&!error&&<div className="timeline-empty">Your timeline is ready for its first little memory.</div>}
    <div className="memory-timeline">{items.map(item=><article className="timeline-memory" key={item.id}><div className="memory-heading"><div className="avatar mini">{item.authorName===partnerName?'🌷':'♡'}</div><div><b>{item.authorName}</b><small>{new Date(item.created_at).toLocaleString()}</small></div></div><p>{item.body}</p>{item.mediaUrl&&item.media_type==='image'&&<img className="memory-media" src={item.mediaUrl} alt="A photo in your private couple memory" loading="lazy"/>}{item.mediaUrl&&item.media_type==='video'&&<video className="memory-media" src={item.mediaUrl} controls preload="metadata"/>}<div className="memory-actions"><button type="button" onClick={()=>void toggleReaction(item)} aria-pressed={item.reactions.some(r=>r.user_id===userId&&r.reaction==='heart')}>♡ {item.reactions.length}</button><span>{item.comments.length} comments</span></div>{connected&&<><div className="memory-comments">{item.comments.map(comment=><p key={comment.id}><b>{comment.author_id===userId?'You':partnerName||'Partner'}:</b> {comment.body}</p>)}</div><form className="comment-form" onSubmit={e=>{e.preventDefault();void addComment(item.id)}}><input maxLength={1200} value={comments[item.id]||''} onChange={e=>setComments(s=>({...s,[item.id]:e.target.value}))} placeholder="Write a kind little comment…"/><button className="button small">Comment</button></form></>}</article>)}</div>
  </section>
}

function daysTogether(date:string){const parts=date.split('-').map(Number);if(parts.length!==3||parts.some(n=>!Number.isInteger(n)))return '—';const [year,month,day]=parts;const start=Date.UTC(year,month-1,day);const today=new Date();const todayStart=Date.UTC(today.getFullYear(),today.getMonth(),today.getDate());return Math.max(0,Math.floor((todayStart-start)/86400000)).toLocaleString()}
