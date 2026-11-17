import React from 'react'
import { supabase } from './lib/supabase'

type Slot={id:number;placement:string;package:string;monthly_price_myr:number;active:boolean}
type Campaign={id:string;advertiser_id:string;billboard_id:number;headline:string;offer:string|null;destination_url:string;starts_at:string;expires_at:string;status:string;creative_path:string|null;creative_alt:string|null;booked_duration_days:number|null;quoted_price_myr:number|null}
type Inquiry={id:string;contact_name:string;company_name:string;contact_email:string;message:string;created_at:string;reviewed_at:string|null}
type Props={connected:boolean;onMessage?:(message:string)=>void}
type CampaignForm={company:string;description:string;headline:string;offer:string;url:string;billboard:string;starts:string;days:string;alt:string}
const emptyForm:CampaignForm={company:'',description:'',headline:'',offer:'',url:'',billboard:'',starts:'',days:'30',alt:''}

export default function AdvertisingCenter({connected,onMessage=()=>undefined}:Props){
  const [slots,setSlots]=React.useState<Slot[]>([])
  const [campaigns,setCampaigns]=React.useState<Campaign[]>([])
  const [advertisers,setAdvertisers]=React.useState<Record<string,string>>({})
  const [inquiries,setInquiries]=React.useState<Inquiry[]>([])
  const [admin,setAdmin]=React.useState(false)
  const [tab,setTab]=React.useState<'market'|'admin'>('market')
  const [loading,setLoading]=React.useState(true)
  const [busy,setBusy]=React.useState(false)
  const [error,setError]=React.useState('')
  const [form,setForm]=React.useState(emptyForm)
  const [creative,setCreative]=React.useState<File|null>(null)
  const [inquiry,setInquiry]=React.useState({contactName:'',companyName:'',email:'',message:'',website:''})
  const [sessionCounts,setSessionCounts]=React.useState<Record<string,{impressions:number;clicks:number}>>({})

  const load=React.useCallback(async()=>{
    if(!supabase){setLoading(false);return}
    setLoading(true);setError('')
    try{
      const [slotResult,campaignResult,adminResult]=await Promise.all([
        supabase.from('billboard_slots').select('id,placement,package,monthly_price_myr,active').eq('active',true).order('id'),
        supabase.from('ad_campaigns').select('id,advertiser_id,billboard_id,headline,offer,destination_url,starts_at,expires_at,status,creative_path,creative_alt,booked_duration_days,quoted_price_myr').order('created_at',{ascending:false}).limit(100),
        connected?supabase.rpc('is_platform_admin'):Promise.resolve({data:false,error:null} as const),
      ])
      if(slotResult.error)throw slotResult.error
      if(campaignResult.error)throw campaignResult.error
      const isAdmin=Boolean(adminResult.data)&&!adminResult.error
      setAdmin(isAdmin);setSlots(slotResult.data||[])
      const campaignRows=(campaignResult.data||[]) as Campaign[]
      setCampaigns(campaignRows)
      const advertiserIds=[...new Set(campaignRows.map(c=>c.advertiser_id))]
      if(advertiserIds.length){const {data,error}=await supabase.from('advertisers').select('id,company_name').in('id',advertiserIds);if(error)throw error;setAdvertisers(Object.fromEntries((data||[]).map(x=>[x.id,x.company_name])))}else setAdvertisers({})
      if(isAdmin){
        const {data,error}=await supabase.from('advertising_inquiries').select('id,contact_name,company_name,contact_email,message,created_at,reviewed_at').order('created_at',{ascending:false}).limit(100)
        if(error)throw error
        setInquiries((data||[]) as Inquiry[])
        const counts=await Promise.all(campaignRows.map(async campaign=>{
          const [impressions,clicks]=await Promise.all([
            supabase!.from('ad_view_sessions').select('id',{count:'exact',head:true}).eq('campaign_id',campaign.id),
            supabase!.from('ad_clicks').select('id',{count:'exact',head:true}).eq('campaign_id',campaign.id),
          ])
          return [campaign.id,{impressions:impressions.count||0,clicks:clicks.count||0}] as const
        }))
        setSessionCounts(Object.fromEntries(counts))
      }else{setInquiries([]);setSessionCounts({})}
    }catch(e){setError(e instanceof Error?e.message:'Advertising data could not be loaded.')}
    finally{setLoading(false)}
  },[connected])

  React.useEffect(()=>{void load()},[load])
  const active=campaigns.filter(c=>c.status==='active'&&Date.parse(c.starts_at)<=Date.now()&&Date.parse(c.expires_at)>Date.now())
  const markReviewed=async(id:string)=>{if(!supabase)return;setBusy(true);setError('');try{const {error}=await supabase.rpc('admin_mark_ad_inquiry_reviewed',{inquiry:id});if(error)throw error;await load()}catch(e){setError(e instanceof Error?e.message:'Inquiry status could not be updated.')}finally{setBusy(false)}}
  const changeCampaign=async(id:string,status:'active'|'paused'|'expired')=>{if(!supabase)return;setBusy(true);setError('');try{const {error}=await supabase.rpc('admin_set_ad_campaign_status',{campaign:id,next_status:status});if(error)throw error;await load()}catch(e){setError(e instanceof Error?e.message:'Campaign status could not be changed.')}finally{setBusy(false)}}
  const sendInquiry=async(e:React.FormEvent)=>{e.preventDefault();if(!supabase)return;setBusy(true);setError('');try{const {error}=await supabase.rpc('submit_advertising_inquiry',{contact_name:inquiry.contactName,company_name:inquiry.companyName,contact_email:inquiry.email,message:inquiry.message,website:inquiry.website});if(error)throw error;setInquiry({contactName:'',companyName:'',email:'',message:'',website:''});onMessage('Your advertising inquiry has been sent for review.')}catch(e){setError(e instanceof Error?e.message:'Inquiry could not be sent. Sign in and try again.')}finally{setBusy(false)}}
  const createCampaign=async(e:React.FormEvent)=>{
    e.preventDefault();if(!supabase)return;setBusy(true);setError('');let path:string|undefined
    try{
      if(creative){const mimeExt:Record<string,string>={'image/jpeg':'jpg','image/png':'png','image/webp':'webp'};if(!mimeExt[creative.type])throw new Error('Creative must be JPG, PNG or WebP.');if(creative.size>5*1024*1024)throw new Error('Creative must be smaller than 5 MB.');path=`campaigns/${crypto.randomUUID()}.${mimeExt[creative.type]}`;const {error}=await supabase.storage.from('advertising-creatives').upload(path,creative,{contentType:creative.type,upsert:false});if(error)throw error}
      const {error}=await supabase.rpc('admin_create_ad_campaign',{company_name:form.company,advertiser_description:form.description,billboard_id:Number(form.billboard),headline:form.headline,offer:form.offer||null,destination_url:form.url,starts_at:new Date(form.starts).toISOString(),duration_days:Number(form.days),creative_path:path||null,creative_alt:form.alt||null})
      if(error){if(path)await supabase.storage.from('advertising-creatives').remove([path]);throw error}
      setForm(emptyForm);setCreative(null);await load();onMessage('Campaign created as pending approval. No payment was taken.')
    }catch(e){setError(e instanceof Error?e.message:'Campaign could not be created.')}
    finally{setBusy(false)}
  }

  if(!connected)return <><style>{adStyles}</style><section className="page-card"><div className="eyebrow">COUPLE LIFE ADVERTISING</div><h1>Reach the neighborhood</h1><p className="sub">Sign in to send an advertising inquiry. Active sponsored campaigns will appear here when available.</p><div className="ad-public-slots">{slots.map(slot=><div className="ad-slot" key={slot.id}><span>Billboard {String(slot.id).padStart(2,'0')}</span><b>{slot.placement}</b><small>{slot.package} · MYR {slot.monthly_price_myr.toLocaleString()}/package period</small></div>)}</div></section></>

  return <><style>{adStyles}</style><section className="page-card ad-center"><div className="eyebrow">COUPLE LIFE ADVERTISING</div><h1>Neighborhood sponsors</h1><p className="sub">Real campaigns only. Each billboard follows its scheduled dates and administrator approval.</p>
    {admin&&<div className="shop-tabs"><button className={tab==='market'?'active':''} onClick={()=>setTab('market')}>Campaigns</button><button className={tab==='admin'?'active':''} onClick={()=>setTab('admin')}>Admin and reports</button></div>}
    {loading?<p className="ad-empty">Loading advertising information…</p>:error&&<div role="alert" className="auth-error">{error}</div>}
    {!loading&&tab==='market'&&<>
      {active.length?active.map(c=><AdCard key={c.id} campaign={c} company={advertisers[c.advertiser_id]||'Sponsored'} onMessage={onMessage}/>):<div className="ad-empty">There are no active campaigns right now. The ten billboard locations remain available for future bookings.</div>}
      <div className="ad-slot-grid">{slots.map(slot=>{const campaign=active.find(c=>c.billboard_id===slot.id);return <div className={`ad-slot ${campaign?'ad-slot-filled':''}`} key={slot.id}><span>Billboard {String(slot.id).padStart(2,'0')}</span><b>{campaign?.headline||slot.placement}</b><small>{campaign?advertisers[campaign.advertiser_id]||'Sponsored':`${slot.package} · MYR ${slot.monthly_price_myr.toLocaleString()}/package period`}</small></div>})}</div>
      <div className="ad-inquiry"><h2>Ask about advertising</h2><p className="sub">Inquiries are reviewed by the Couple Life team. Sending one does not book a campaign or take payment.</p><form className="ad-form" onSubmit={e=>void sendInquiry(e)}><label>Your name<input maxLength={120} required value={inquiry.contactName} onChange={e=>setInquiry(s=>({...s,contactName:e.target.value}))}/></label><label>Company<input maxLength={160} required value={inquiry.companyName} onChange={e=>setInquiry(s=>({...s,companyName:e.target.value}))}/></label><label>Work email<input type="email" maxLength={320} required value={inquiry.email} onChange={e=>setInquiry(s=>({...s,email:e.target.value}))}/></label><label>What would you like to promote?<textarea maxLength={4000} required value={inquiry.message} onChange={e=>setInquiry(s=>({...s,message:e.target.value}))}/></label><label className="ad-honeypot" aria-hidden="true">Website<input tabIndex={-1} autoComplete="off" value={inquiry.website} onChange={e=>setInquiry(s=>({...s,website:e.target.value}))}/></label><button className="button coral" disabled={busy}>{busy?'Sending…':'Send inquiry'}</button></form></div>
    </>}
    {!loading&&admin&&tab==='admin'&&<div className="ad-admin">
      <div className="ad-admin-columns"><section><h2>New scheduled campaign</h2><p className="sub">New campaigns remain pending until approved. Pricing is a quote only; payment processing is not configured.</p><form className="ad-form" onSubmit={e=>void createCampaign(e)}><label>Company<input required maxLength={160} value={form.company} onChange={e=>setForm(s=>({...s,company:e.target.value}))}/></label><label>Advertiser description<input maxLength={2000} value={form.description} onChange={e=>setForm(s=>({...s,description:e.target.value}))}/></label><label>Billboard<select required value={form.billboard} onChange={e=>setForm(s=>({...s,billboard:e.target.value}))}><option value="">Choose a placement</option>{slots.map(slot=><option key={slot.id} value={slot.id}>{slot.id}. {slot.placement} · {slot.package} · MYR {slot.monthly_price_myr}/package period</option>)}</select></label><label>Headline<input required maxLength={120} value={form.headline} onChange={e=>setForm(s=>({...s,headline:e.target.value}))}/></label><label>Offer or detail<input maxLength={500} value={form.offer} onChange={e=>setForm(s=>({...s,offer:e.target.value}))}/></label><label>External destination (HTTPS)<input type="url" required value={form.url} onChange={e=>setForm(s=>({...s,url:e.target.value}))} placeholder="https://example.com"/></label><label>Start date and time<input type="datetime-local" required value={form.starts} onChange={e=>setForm(s=>({...s,starts:e.target.value}))}/></label><label>Duration in days<input type="number" min="1" max="90" required value={form.days} onChange={e=>setForm(s=>({...s,days:e.target.value}))}/></label><label>Creative alt text<input maxLength={240} value={form.alt} onChange={e=>setForm(s=>({...s,alt:e.target.value}))}/></label><label>Creative image<input type="file" accept="image/jpeg,image/png,image/webp" onChange={e=>setCreative(e.target.files?.[0]||null)}/></label><button className="button coral" disabled={busy||!form.billboard}>{busy?'Saving…':'Create pending campaign'}</button></form></section>
        <section><h2>Advertiser inquiries</h2>{inquiries.length?inquiries.map(item=><article className="ad-inquiry-row" key={item.id}><div><b>{item.company_name}</b><small>{item.contact_name} · {item.contact_email} · {new Date(item.created_at).toLocaleString()}</small><p>{item.message}</p></div><button className="button small" disabled={busy||!!item.reviewed_at} onClick={()=>void markReviewed(item.id)}>{item.reviewed_at?'Reviewed':'Mark reviewed'}</button></article>):<div className="ad-empty">No advertiser inquiries.</div>}</section></div>
      <h2>Campaign scheduling and reports</h2><div className="ad-admin-campaigns">{campaigns.map(c=>{const counts=sessionCounts[c.id]||{impressions:0,clicks:0};const ended=Date.parse(c.expires_at)<=Date.now();const effective=ended?'expired':c.status;return <article className="ad-campaign-row" key={c.id}><div className="ad-campaign-copy"><b>{c.headline}</b><small>{advertisers[c.advertiser_id]||'Advertiser'} · Billboard {c.billboard_id} · {new Date(c.starts_at).toLocaleString()} – {new Date(c.expires_at).toLocaleString()}</small><small>Status: {effective}{c.quoted_price_myr!==null?` · Quote MYR ${c.quoted_price_myr}`:''} · {counts.impressions} impressions · {counts.clicks} clicks</small></div>{c.status==='pending'&&!ended&&<button className="button small" disabled={busy} onClick={()=>void changeCampaign(c.id,'active')}>Approve</button>}{c.status==='active'&&!ended&&<button className="button small" disabled={busy} onClick={()=>void changeCampaign(c.id,'paused')}>Pause</button>}{c.status==='paused'&&!ended&&<button className="button small" disabled={busy} onClick={()=>void changeCampaign(c.id,'active')}>Resume</button>}</article>})}</div>
    </div>}
  </section></>
}

const adStyles=`
.ad-public-slots,.ad-slot-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:9px;margin:20px 0}.ad-slot{display:grid;gap:5px;padding:12px;border:1px dashed #e8ded5;border-radius:10px;background:#fdfaf6}.ad-slot>span,.ad-live-copy>small{font-size:8px;font-weight:900;letter-spacing:.9px;color:#b58e80}.ad-slot>b{font-size:11px}.ad-slot small{font-size:9px;color:#9b9298}.ad-slot-filled{border-style:solid;background:#f4f6ee}.ad-empty{padding:22px;background:#fcf8f3;border:1px dashed #e9dfd7;border-radius:11px;margin:16px 0;color:#918791;font-size:11px;text-align:center}.ad-live-card{display:flex;align-items:center;justify-content:space-between;gap:18px;padding:17px;margin:14px 0;border:1px solid #eee4dc;border-radius:14px;background:#fffaf5}.ad-live-copy{flex:1;min-width:0}.ad-live-copy h2{margin:7px 0;font-size:17px}.ad-live-copy p{font-size:11px;color:#847a83}.ad-live-copy>a{display:inline-block;margin-top:4px;color:#ad6d60;font-size:10px;font-weight:900;text-decoration:none}.ad-live-card>img{width:140px;max-height:105px;object-fit:cover;border-radius:8px}.ad-inquiry{margin-top:25px;padding-top:18px;border-top:1px solid #eee8e1}.ad-form{display:grid;gap:10px;margin-top:13px}.ad-form label{display:grid;gap:5px;color:#807780;font-size:10px;font-weight:800}.ad-form input,.ad-form select,.ad-form textarea{width:100%;border:1px solid #eee5df;border-radius:8px;background:white;padding:9px 10px;color:#554d56;font:inherit;font-size:11px}.ad-form textarea{min-height:90px;resize:vertical}.ad-honeypot{position:absolute!important;left:-10000px!important;width:1px;height:1px;overflow:hidden}.ad-admin{margin-top:20px}.ad-admin-columns{display:grid;grid-template-columns:minmax(250px,1fr) minmax(250px,1fr);gap:20px}.ad-admin-columns>section{min-width:0}.ad-admin h2,.ad-inquiry h2{font-size:15px}.ad-inquiry-row,.ad-campaign-row{display:flex;justify-content:space-between;align-items:center;gap:10px;border-top:1px solid #f0eae5;padding:12px 2px}.ad-inquiry-row>div,.ad-campaign-copy{min-width:0;flex:1}.ad-inquiry-row b,.ad-campaign-copy b{display:block;font-size:11px}.ad-inquiry-row small,.ad-campaign-copy small{display:block;margin-top:4px;color:#99909a;font-size:9px;overflow-wrap:anywhere}.ad-inquiry-row p{margin:7px 0 0;color:#716a72;font-size:10px;white-space:pre-wrap;overflow-wrap:anywhere}.ad-campaign-row{flex-wrap:wrap}.ad-admin-campaigns{margin-top:10px}.ad-center .button:disabled{opacity:.55;cursor:not-allowed;transform:none}
@media(max-width:650px){.ad-public-slots,.ad-slot-grid{grid-template-columns:1fr}.ad-live-card{align-items:flex-start;flex-direction:column}.ad-live-card>img{width:100%;max-height:180px}.ad-admin-columns{grid-template-columns:1fr}.ad-inquiry-row{align-items:flex-start;flex-direction:column}}
`

function AdCard({campaign,company,onMessage}:{campaign:Campaign;company:string;onMessage:(message:string)=>void}){
  const [session,setSession]=React.useState<string|null>(null)
  const [error,setError]=React.useState('')
  const [visible,setVisible]=React.useState(false)
  const [completed,setCompleted]=React.useState(false)
  const ref=React.useRef<HTMLElement|null>(null)
  const onMessageRef=React.useRef(onMessage)
  const sessionRef=React.useRef<string|null>(null)
  const startRequested=React.useRef(false)
  const supabaseClient=supabase
  React.useEffect(()=>{onMessageRef.current=onMessage},[onMessage])
  const ensureSession=React.useCallback(async()=>{
    if(!supabaseClient)return null
    if(sessionRef.current)return sessionRef.current
    const {data,error}=await supabaseClient.rpc('start_ad_view',{campaign:campaign.id})
    if(error)throw error
    const id=String(data);sessionRef.current=id;setSession(id);return id
  },[supabaseClient,campaign.id])
  React.useEffect(()=>{
    if(!supabaseClient)return
    const element=ref.current
    if(!element||typeof IntersectionObserver==='undefined')return
    let intersects=false
    const updateVisibility=()=>{
      const canView=intersects&&document.visibilityState==='visible'
      setVisible(canView)
      if(canView&&!startRequested.current){
        startRequested.current=true
        void ensureSession().catch(e=>setError(e instanceof Error?e.message:'The advertisement view could not be started.'))
      }
    }
    const observer=new IntersectionObserver(entries=>{
      const entry=entries.find(item=>item.target===element)
      intersects=!!entry?.isIntersecting&&entry.intersectionRatio>=0.5
      updateVisibility()
    },{threshold:[0.5]})
    const onVisibility=()=>updateVisibility()
    document.addEventListener('visibilitychange',onVisibility)
    observer.observe(element)
    return()=>{observer.disconnect();document.removeEventListener('visibilitychange',onVisibility)}
  },[supabaseClient,campaign.id,ensureSession])
  React.useEffect(()=>{
    if(!session||!visible||completed||!supabaseClient)return
    const timer=window.setTimeout(async()=>{
      try{
        const {data,error}=await supabaseClient.rpc('complete_ad_view',{view_session:session})
        if(error)throw error
        const result=data as {rewarded?:boolean}
        setCompleted(true)
        onMessageRef.current(result?.rewarded?'Thanks for viewing this sponsor · 1 personal diamond earned.':'Thanks for viewing this sponsor. Today’s reward for this campaign was already claimed.')
      }catch(e){setError(e instanceof Error?e.message:'The advertisement view could not be completed.')}
    },15000)
    return()=>window.clearTimeout(timer)
  },[session,visible,completed,supabaseClient])
  const clicked=async()=>{
    if(!supabaseClient)return
    try{
      const sessionId=await ensureSession()
      if(!sessionId)return
      const {data,error}=await supabaseClient.rpc('record_ad_click',{view_session:sessionId});if(error)throw error
      if(data===true)onMessage('Your sponsor visit was recorded.')
      else onMessage('This sponsor visit was already recorded.')
    }catch(e){setError(e instanceof Error?e.message:'The click could not be recorded.')}
  }
  const media=campaign.creative_path&&supabaseClient?supabaseClient.storage.from('advertising-creatives').getPublicUrl(campaign.creative_path).data.publicUrl:null
  return <article className="ad-live-card" ref={ref as React.RefObject<HTMLElement>}><div className="ad-live-copy"><small>SPONSORED · {company}</small><h2>{campaign.headline}</h2>{campaign.offer&&<p>{campaign.offer}</p>}<a href={campaign.destination_url} target="_blank" rel="noopener noreferrer" onClick={()=>void clicked()}>Visit sponsor ↗</a></div>{media&&<img src={media} alt={campaign.creative_alt||`${company} campaign`} loading="lazy"/>}{error&&<small role="status">{error}</small>}</article>
}
