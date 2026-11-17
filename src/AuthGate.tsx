import React from 'react'
import type { Session, User } from '@supabase/supabase-js'
import { publicAppUrl, supabase, supabaseConfigured } from './lib/supabase'

type GateState = { accountMode: 'connected' | 'demo'; partnerName?: string; partnerId?:string; coupleId?:string; userId?:string; displayName?:string; avatar?:string; signOut?: () => void }
type Props = { children: (state: GateState) => React.ReactNode }
type Stage = 'welcome'|'register'|'login'|'forgot'|'recover-password'|'invite'|'accept'|'waiting'|'setup'|'waiting-confirm'|'game'|'demo'
const avatars = ['🌷','🌻','🐈','🐇','🦊','🐻']

export default function AuthGate({children}:Props) {
  const inviteFromUrl = React.useMemo(() => new URLSearchParams(window.location.search).get('invite') || '', [])
  const [stage,setStage]=React.useState<Stage>('welcome')
  const [session,setSession]=React.useState<Session|null>(null)
  const [busy,setBusy]=React.useState(false)
  const [loading,setLoading]=React.useState(supabaseConfigured)
  const [error,setError]=React.useState('')
  const [notice,setNotice]=React.useState('')
  const [name,setName]=React.useState('')
  const [email,setEmail]=React.useState('')
  const [password,setPassword]=React.useState('')
  const [confirm,setConfirm]=React.useState('')
  const [avatar,setAvatar]=React.useState(avatars[0])
  const [code,setCode]=React.useState(inviteFromUrl)
  const [invitationCode,setInvitationCode]=React.useState('')
  const [invitationLink,setInvitationLink]=React.useState('')
  const [coupleId,setCoupleId]=React.useState('')
  const [partnerName,setPartnerName]=React.useState('')
  const [partnerId,setPartnerId]=React.useState('')
  const [userIsA,setUserIsA]=React.useState(true)
  const [anniversary,setAnniversary]=React.useState('')
  const [birthdayA,setBirthdayA]=React.useState('')
  const [birthdayB,setBirthdayB]=React.useState('')
  const [nickname,setNickname]=React.useState('')

  const inspect=React.useCallback(async(user:User)=>{
    if(!supabase)return
    const ownName=typeof user.user_metadata?.display_name==='string'?user.user_metadata.display_name:user.email?.split('@')[0]||'You'
    const ownAvatar=typeof user.user_metadata?.avatar_url==='string'?user.user_metadata.avatar_url:avatars[0]
    setName(ownName);setAvatar(ownAvatar)
    const membership=await supabase.from('couple_members').select('couple_id').eq('user_id',user.id).maybeSingle()
    if(membership.error) throw membership.error
    if(!membership.data){setCoupleId('');setStage(inviteFromUrl?'accept':'invite');return}
    const cid=membership.data.couple_id as string
    setCoupleId(cid)
    const members=await supabase.from('couple_members').select('user_id,created_at',{count:'exact'}).eq('couple_id',cid).not('approved_at','is',null).order('created_at')
    if(members.error) throw members.error
    setUserIsA(members.data?.[0]?.user_id===user.id)
    const otherId=members.data?.find(m=>m.user_id!==user.id)?.user_id
    if(otherId){setPartnerId(otherId);const profile=await supabase.from('profiles').select('display_name').eq('id',otherId).maybeSingle();if(!profile.error&&profile.data)setPartnerName(profile.data.display_name)}
    if((members.count||0)<2){setInvitationCode(localStorage.getItem(`couple-life-invitation-code:${user.id}`)||'');setInvitationLink(localStorage.getItem(`couple-life-invitation-link:${user.id}`)||'');setStage('waiting');return}
    const couple=await supabase.from('couples').select('created_by,anniversary,partner_a_birthday,partner_b_birthday,relationship_nickname,setup_complete_at').eq('id',cid).maybeSingle()
    if(couple.error) throw couple.error
    const isA=couple.data?.created_by?couple.data.created_by===user.id:user.id===members.data?.[0]?.user_id
    setUserIsA(isA)
    if(couple.data){setAnniversary(couple.data.anniversary||'');setBirthdayA(isA?(couple.data.partner_a_birthday||''):(couple.data.partner_b_birthday||''));setBirthdayB(isA?(couple.data.partner_b_birthday||''):(couple.data.partner_a_birthday||''));setNickname(couple.data.relationship_nickname||'')}
    if(couple.data?.setup_complete_at)setStage('game')
    else setStage('setup')
  },[inviteFromUrl])

  React.useEffect(()=>{
    if(!supabase){setLoading(false);return}
    let active=true
    void (async()=>{
      const {data,error:sessionError}=await supabase.auth.getSession()
      if(!active)return
      if(sessionError){setError(sessionError.message);setLoading(false);return}
      setSession(data.session)
      try { if(data.session) await inspect(data.session.user) }
      catch(e){setError(e instanceof Error?e.message:String(e))}
      finally { if(active)setLoading(false) }
    })()
    const {data:{subscription}}=supabase.auth.onAuthStateChange((event,next)=>{
      if(!active)return
      setSession(next)
      if(event==='PASSWORD_RECOVERY'){setPassword('');setConfirm('');setStage('recover-password');setLoading(false);return}
      if(next&&(event==='SIGNED_IN'||event==='USER_UPDATED')){
        setLoading(true)
        window.setTimeout(()=>void inspect(next.user).catch(e=>setError(e.message)).finally(()=>{if(active)setLoading(false)}),0)
      }
      else if(!next){setStage('welcome');setLoading(false)}
    })
    return()=>{active=false;subscription.unsubscribe()}
  },[inspect])

  React.useEffect(()=>{
    const client=supabase
    if(!client||!coupleId||!session||!['waiting','waiting-confirm','setup'].includes(stage))return
    const channel=client.channel(`couple-onboarding-${coupleId}`)
      .on('postgres_changes',{event:'*',schema:'public',table:'couple_members',filter:`couple_id=eq.${coupleId}`},()=>void inspect(session.user).catch(e=>setError(e.message)))
      .on('postgres_changes',{event:'UPDATE',schema:'public',table:'couples',filter:`id=eq.${coupleId}`},()=>void inspect(session.user).catch(e=>setError(e.message)))
      .subscribe()
    return()=>{void client.removeChannel(channel)}
  },[coupleId,session,stage,inspect])

  const signOut=React.useCallback(()=>{if(supabase)void supabase.auth.signOut();setSession(null);setStage('welcome')},[])
  const run=async(action:()=>Promise<void>)=>{setBusy(true);setError('');setNotice('');try{await action()}catch(e){setError(e instanceof Error?e.message:String(e))}finally{setBusy(false)}}
  const register=()=>run(async()=>{
    if(password.length<8)throw new Error('Choose a password with at least 8 characters.')
    if(password!==confirm)throw new Error('Those passwords do not match.')
    const result=await supabase!.auth.signUp({email:email.trim(),password,options:{data:{display_name:name.trim(),avatar_url:avatar},emailRedirectTo:window.location.origin}})
    if(result.error)throw result.error
    if(!result.data.session){setNotice('Check your email to confirm your account, then return here and log in.');setStage('login')}
    else {setSession(result.data.session);if(inviteFromUrl)setStage('accept');else setStage('invite')}
  })
  const login=()=>run(async()=>{
    const result=await supabase!.auth.signInWithPassword({email:email.trim(),password})
    if(result.error)throw result.error
    if(result.data.session){setSession(result.data.session);await inspect(result.data.session.user)}
  })
  const requestPasswordReset=()=>run(async()=>{
    if(!email.trim())throw new Error('Enter the email address for your account first.')
    const recoveryUrl=new URL('/',window.location.origin)
    if(code.trim())recoveryUrl.searchParams.set('invite',code.trim())
    const result=await supabase!.auth.resetPasswordForEmail(email.trim(),{redirectTo:recoveryUrl.toString()})
    if(result.error)throw result.error
    setNotice('If an account uses that email, a password reset link is on its way.')
    setStage('login')
  })
  const updateRecoveredPassword=()=>run(async()=>{
    if(password.length<8)throw new Error('Choose a password with at least 8 characters.')
    if(password!==confirm)throw new Error('Those passwords do not match.')
    const result=await supabase!.auth.updateUser({password})
    if(result.error)throw result.error
    setPassword('');setConfirm('')
    if(result.data.user)await inspect(result.data.user)
    setNotice('Your password has been updated.')
  })
  const createInvite=()=>run(async()=>{
    const result=await supabase!.rpc('create_couple_invitation')
    if(result.error)throw result.error
    const row=Array.isArray(result.data)?result.data[0]:result.data
    if(!row?.invitation_code)throw new Error('The invitation could not be created.')
    const newCode=String(row.invitation_code)
    const base=publicAppUrl()
    const link=base?`${base}/?invite=${encodeURIComponent(newCode)}`:''
    setInvitationCode(newCode);setInvitationLink(link);setCoupleId(row.couple_id)
    if(session){localStorage.setItem(`couple-life-invitation-code:${session.user.id}`,newCode);if(link)localStorage.setItem(`couple-life-invitation-link:${session.user.id}`,link)}
    setStage('waiting')
    if(!base)setNotice('Invitation code created. Add VITE_PUBLIC_APP_URL after deployment to create a public share link. This code is still usable in the app.')
  })
  const acceptInvite=()=>run(async()=>{
    const result=await supabase!.rpc('accept_couple_invitation',{input_code:code.trim()})
    if(result.error)throw result.error
    if(session){setCoupleId(result.data);setNotice('You both said yes. Now set up your shared relationship details.');await inspect(session.user)}
  })
  const declineInvite=()=>run(async()=>{
    const result=await supabase!.rpc('decline_couple_invitation',{input_code:code.trim()})
    if(result.error)throw result.error
    window.history.replaceState({},'',window.location.pathname)
    setCode('');setStage('welcome');setNotice('Invitation declined. You can log in again whenever you are ready.')
    await supabase!.auth.signOut()
  })
  const saveRelationship=()=>run(async()=>{
    if(!anniversary)throw new Error('Choose your anniversary date to continue.')
    const result=await supabase!.rpc('complete_relationship_setup',{target_couple:coupleId,anniversary_on:anniversary,birthday_a:(userIsA?birthdayA:birthdayB)||null,birthday_b:(userIsA?birthdayB:birthdayA)||null,nickname:nickname.trim()||null})
    if(result.error)throw result.error
    if(result.data){setStage('game');setNotice('Both partners confirmed. Welcome home!')}
    else {setStage('waiting-confirm');setNotice('Your details are saved. Waiting for your partner to review and confirm them.')}
  })
  const copy=async(value:string)=>{try{await navigator.clipboard.writeText(value);setNotice('Copied to clipboard.')}catch{setNotice('Copy this value: '+value)}}

  if(stage==='demo')return <>{children({accountMode:'demo',signOut:()=>setStage('welcome')})}</>
  if(stage==='game'&&session&&coupleId)return <>{children({accountMode:'connected',partnerName,partnerId,coupleId,userId:session.user.id,displayName:name,avatar,signOut})}</>
  if(loading)return <main className="auth-screen"><div className="auth-card"><div className="auth-mark">♡</div><p>Opening your little world…</p></div></main>

  return <main className="auth-screen"><div className="auth-card"><div className="auth-brand"><div className="auth-mark">♡</div><div><b>couple life</b><small>a little world together</small></div></div>
    {stage==='welcome'&&<div className="auth-body"><div className="eyebrow">A COZY LITTLE LIFE, BUILT TOGETHER</div><h1>Your little world starts with two.</h1><p>Make a home, raise a pet, grow a dream and keep your favorite memories close.</p><div className="welcome-art"><span>🌴</span><div>🏡</div><span>🌼</span></div>{supabaseConfigured?<><button className="button coral auth-primary" onClick={()=>setStage('register')}>Create account</button><button className="auth-secondary" onClick={()=>setStage('login')}>Already have an account? Log in</button></>:<><div className="config-note">Account sign-in and partner invitations need Supabase setup. Your existing local demo remains available.</div><button className="button coral auth-primary" onClick={()=>setStage('demo')}>Continue with local demo</button></>}</div>}
    {(stage==='register'||stage==='login')&&<div className="auth-body"><button className="back-link" onClick={()=>{setError('');setNotice('');setStage('welcome')}}>← Back</button><div className="eyebrow">{stage==='register'?'LET’S MAKE YOUR ACCOUNT':'WELCOME BACK'}</div><h1>{stage==='register'?'Start your story.':'Come on in.'}</h1><p>{stage==='register'?'Your name and a little avatar are all you need to begin.':'Log in to pick up where your little life left off.'}</p><form className="auth-form" onSubmit={e=>{e.preventDefault();void(stage==='register'?register():login())}}>{stage==='register'&&<><label>Your name<input required autoComplete="name" value={name} onChange={e=>setName(e.target.value)} placeholder="What should we call you?"/></label><div className="avatar-choices" aria-label="Choose an avatar">{avatars.map(a=><button type="button" key={a} className={avatar===a?'chosen':''} onClick={()=>setAvatar(a)}>{a}</button>)}</div></>}<label>Email<input required type="email" autoComplete="email" value={email} onChange={e=>setEmail(e.target.value)} placeholder="you@example.com"/></label><label>Password<input required type="password" autoComplete={stage==='register'?'new-password':'current-password'} value={password} onChange={e=>setPassword(e.target.value)} placeholder={stage==='register'?'At least 8 characters':'Your password'}/></label>{stage==='register'&&<label>Confirm password<input required type="password" autoComplete="new-password" value={confirm} onChange={e=>setConfirm(e.target.value)} placeholder="Type it once more"/></label>}<button className="button coral auth-primary" disabled={busy}>{busy?'One moment…':stage==='register'?'Create my account':'Log in'}</button></form><button className="auth-secondary" onClick={()=>{setError('');setNotice('');setStage(stage==='register'?'login':'register')}}>{stage==='register'?'Already joined? Log in':'New to Couple Life? Create an account'}</button></div>}
    {stage==='login'&&<button className="auth-secondary" onClick={()=>{setError('');setNotice('');setStage('forgot')}}>Forgot your password?</button>}
    {stage==='forgot'&&<div className="auth-body"><button className="back-link" onClick={()=>{setError('');setNotice('');setStage('login')}}>← Back to log in</button><div className="eyebrow">ACCOUNT RECOVERY</div><h1>Let’s get you back in.</h1><p>We’ll send a secure password reset link if an account matches that email.</p><form className="auth-form" onSubmit={e=>{e.preventDefault();void requestPasswordReset()}}><label>Email<input required type="email" autoComplete="email" value={email} onChange={e=>setEmail(e.target.value)} placeholder="you@example.com"/></label><button className="button coral auth-primary" disabled={busy}>{busy?'Sending…':'Send reset link'}</button></form></div>}
    {stage==='recover-password'&&<div className="auth-body"><div className="eyebrow">SECURE YOUR ACCOUNT</div><h1>Choose a new password.</h1><p>Use at least eight characters. You’ll return to your Couple Life account when it’s saved.</p><form className="auth-form" onSubmit={e=>{e.preventDefault();void updateRecoveredPassword()}}><label>New password<input required type="password" autoComplete="new-password" value={password} onChange={e=>setPassword(e.target.value)} minLength={8}/></label><label>Confirm new password<input required type="password" autoComplete="new-password" value={confirm} onChange={e=>setConfirm(e.target.value)}/></label><button className="button coral auth-primary" disabled={busy}>{busy?'Saving…':'Update password'}</button></form></div>}
    {stage==='invite'&&<div className="auth-body"><div className="step-badge">STEP 1 · INVITE YOUR PERSON</div><div className="welcome-art small-art">💌</div><h1>Every little world needs two.</h1><p>Invite your favorite person. They’ll create their own account and accept the connection before your shared setup begins.</p><button className="button coral auth-primary" disabled={busy} onClick={()=>void createInvite()}>{busy?'Making your invite…':'Create invitation'}</button><button className="auth-secondary" onClick={signOut}>Sign out</button></div>}
    {stage==='accept'&&<div className="auth-body"><div className="step-badge">A LITTLE INVITATION FOR YOU</div><div className="welcome-art small-art">💌</div><h1>Your person saved you a place.</h1><p>Accept the invitation to connect your accounts. You can only join one couple.</p><label className="auth-label">INVITATION CODE<input className="auth-input" value={code} onChange={e=>setCode(e.target.value.toUpperCase())} placeholder="Paste your 16-character code"/></label>{session?<><button className="button coral auth-primary" disabled={busy||!code.trim()} onClick={()=>void acceptInvite()}>{busy?'Connecting…':'Accept invitation'}</button><button className="auth-secondary" disabled={busy} onClick={()=>void declineInvite()}>Decline invitation</button><button className="auth-secondary" onClick={signOut}>Sign out</button></>:<><div className="config-note">Log in or create an account first. This invitation code will stay here while you do.</div><button className="button coral auth-primary" onClick={()=>{setError('');setNotice('');setStage('login')}}>Log in to accept</button><button className="auth-secondary" onClick={()=>{setError('');setNotice('');setStage('register')}}>Create an account to accept</button></>}</div>}
    {(stage==='waiting'||stage==='waiting-confirm')&&<div className="auth-body"><div className="step-badge">{stage==='waiting'?'YOUR INVITATION IS READY':'ONE LAST LITTLE YES'}</div><div className="welcome-art small-art">{stage==='waiting'?'💌':'♡'}</div><h1>{stage==='waiting'?'We saved them a spot.':'Let your partner confirm, too.'}</h1><p>{stage==='waiting'?'Your partner needs to create or log in to their own account, then accept this invite.':`Your details are saved${partnerName?` for you and ${partnerName}`:''}. Your partner needs to review and confirm them.`}</p>{stage==='waiting'&&<><div className="invite-code">{invitationCode||'Invitation created'}</div><button className="button outline auth-primary" onClick={()=>void copy(invitationCode)}>Copy invitation code</button>{invitationLink?<><button className="button coral auth-primary" onClick={()=>void copy(invitationLink)}>Copy public invite link</button><div className="share-row"><button onClick={()=>{if(navigator.share)void navigator.share({title:'Join me in Couple Life',text:'Your little world starts with two.',url:invitationLink}).catch(()=>undefined);else void copy(invitationLink)}}>Share</button><a href={`https://wa.me/?text=${encodeURIComponent(`Join me in Couple Life: ${invitationLink}`)}`} target="_blank" rel="noreferrer">WhatsApp</a><a href={`https://t.me/share/url?url=${encodeURIComponent(invitationLink)}&text=${encodeURIComponent('Join me in Couple Life')}`} target="_blank" rel="noreferrer">Telegram</a></div></>:<p className="config-note">Public links are disabled on localhost. Set VITE_PUBLIC_APP_URL to your deployed HTTPS address.</p>}</>}{stage==='waiting-confirm'&&<button className="button outline auth-primary" onClick={()=>{if(session)void inspect(session.user)}}>Check for confirmation</button>}<button className="auth-secondary" onClick={signOut}>Sign out</button></div>}
    {stage==='setup'&&<div className="auth-body"><div className="step-badge">STEP 2 · MAKE THIS WORLD YOURS</div><h1>Let’s make this world yours.</h1><p>Both of you should review and confirm these details. Your shared world opens after the second confirmation.</p><form className="auth-form" onSubmit={e=>{e.preventDefault();void saveRelationship()}}><label>Anniversary date<input required type="date" value={anniversary} onChange={e=>setAnniversary(e.target.value)}/></label><label>Your birthday <span className="optional">optional</span><input type="date" value={birthdayA} onChange={e=>setBirthdayA(e.target.value)}/></label><label>Partner’s birthday <span className="optional">optional</span><input type="date" value={birthdayB} onChange={e=>setBirthdayB(e.target.value)}/></label><label>Relationship nickname <span className="optional">optional</span><input value={nickname} onChange={e=>setNickname(e.target.value)} placeholder="Our little team"/></label><button className="button coral auth-primary" disabled={busy}>{busy?'Saving…':'Review and confirm'}</button></form><button className="auth-secondary" onClick={signOut}>Sign out</button></div>}
    {error&&<div role="alert" className="auth-error">{error}</div>}{notice&&<div role="status" className="auth-notice">{notice}</div>}
    <footer className="auth-footer">A gentle place for the life you’re building together <span>♡</span></footer>
  </div></main>
}
