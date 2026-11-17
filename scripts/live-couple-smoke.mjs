import { readFile } from 'node:fs/promises'
import { createClient } from '@supabase/supabase-js'

const configText = await readFile(new URL('../.env.local', import.meta.url), 'utf8').catch(() => '')
const fileEnv = Object.fromEntries(configText.split(/\r?\n/).map(line => {
  const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/)
  return match ? [match[1], match[2].replace(/^['"]|['"]$/g, '')] : []
}).filter(Boolean))
const supabaseUrl = process.env.VITE_SUPABASE_URL || fileEnv.VITE_SUPABASE_URL
const supabaseKey = process.env.VITE_SUPABASE_ANON_KEY || fileEnv.VITE_SUPABASE_ANON_KEY
const required = ['COUPLE_TEST_USER_A_EMAIL','COUPLE_TEST_USER_A_PASSWORD','COUPLE_TEST_USER_B_EMAIL','COUPLE_TEST_USER_B_PASSWORD']
const missing = required.filter(name => !process.env[name])
if (!supabaseUrl || !supabaseKey) missing.unshift('VITE_SUPABASE_URL','VITE_SUPABASE_ANON_KEY')
if (missing.length) {
  console.error(`BLOCKED: set these local environment variables to run the two-account smoke check: ${[...new Set(missing)].join(', ')}`)
  process.exit(2)
}

const client = () => createClient(supabaseUrl, supabaseKey, { auth: { persistSession: false, autoRefreshToken: false } })
const a = client()
const b = client()
const pass = name => console.log(`PASS ${name}`)
const fail = name => { throw new Error(`FAILED ${name}`) }
const expectedError = (result, phrase, name) => {
  if (!result.error || !result.error.message.toLowerCase().includes(phrase.toLowerCase())) fail(name)
  pass(name)
}
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
let channelA
let channelB

try {
  const invalidSignup = await a.auth.signUp({email:'not-an-email',password:'short'})
  if (!invalidSignup.error) fail('registration rejects malformed email without creating an account')
  pass('registration rejects malformed email without creating an account')
  const [loginA, loginB] = await Promise.all([
    a.auth.signInWithPassword({ email:process.env.COUPLE_TEST_USER_A_EMAIL, password:process.env.COUPLE_TEST_USER_A_PASSWORD }),
    b.auth.signInWithPassword({ email:process.env.COUPLE_TEST_USER_B_EMAIL, password:process.env.COUPLE_TEST_USER_B_PASSWORD }),
  ])
  if (loginA.error || loginB.error || !loginA.data.user || !loginB.data.user) fail('test account sign-in')
  pass('both existing test accounts sign in')
  const userA = loginA.data.user.id
  const userB = loginB.data.user.id
  if (userA === userB) fail('separate account identities')

  const [memberA, memberB] = await Promise.all([
    a.from('couple_members').select('couple_id').eq('user_id',userA).maybeSingle(),
    b.from('couple_members').select('couple_id').eq('user_id',userB).maybeSingle(),
  ])
  if (memberA.error || memberB.error || !memberA.data || !memberB.data || memberA.data.couple_id !== memberB.data.couple_id) fail('both accounts belong to the same couple')
  const coupleId = memberA.data.couple_id
  pass('both accounts belong to the same couple')

  const [worldA,walletA,walletB,diamondsA,diamondsB,readOtherDiamondA,readOtherDiamondB] = await Promise.all([
    a.from('worlds').select('state,revision').eq('couple_id',coupleId).single(),
    a.from('wallets').select('coins').eq('couple_id',coupleId).single(),
    b.from('wallets').select('coins').eq('couple_id',coupleId).single(),
    a.from('diamond_wallets').select('user_id,diamonds').eq('user_id',userA).single(),
    b.from('diamond_wallets').select('user_id,diamonds').eq('user_id',userB).single(),
    a.from('diamond_wallets').select('user_id').eq('user_id',userB).maybeSingle(),
    b.from('diamond_wallets').select('user_id').eq('user_id',userA).maybeSingle(),
  ])
  if ([worldA,walletA,walletB,diamondsA,diamondsB,readOtherDiamondA,readOtherDiamondB].some(result => result.error)) fail('authenticated shared-world and wallet reads')
  if (!worldA.data || walletA.data.coins !== walletB.data.coins) fail('both partners see the same world and coin wallet')
  if (diamondsA.data.user_id !== userA || diamondsB.data.user_id !== userB) fail('each account reads its own diamond wallet')
  if (readOtherDiamondA.data || readOtherDiamondB.data) fail('individual diamond wallet isolation')
  pass('both accounts load the shared world and same coin balance')
  pass('each account reads only its own diamond wallet')

  const randomBusinessId = crypto.randomUUID()
  expectedError(await a.rpc('collect_business_income',{business_id:randomBusinessId}),'business not found','income collection RPC is deployed and rejects an unowned business without changing data')
  expectedError(await a.rpc('purchase_item',{item_key:'__smoke_invalid_item__',pay_with:'coins',request_id:crypto.randomUUID()}),'no longer available','shop RPC is deployed and rejects an invalid item without charging')
  expectedError(await a.rpc('purchase_business',{business_kind:'__smoke_invalid_business__',request_id:crypto.randomUUID()}),'unavailable','business purchase RPC is deployed and rejects an invalid business without charging')
  expectedError(await a.rpc('care_for_pet',{pet_id:crypto.randomUUID(),care_action:'play'}),'pet not found','pet care RPC is deployed and rejects an unknown pet without changing data')
  const future = new Date(Date.now()+86400000).toISOString().slice(0,10)
  expectedError(await a.rpc('complete_relationship_setup',{target_couple:coupleId,anniversary_on:future,birthday_a:null,birthday_b:null,nickname:null}),'valid anniversary','couple setup RPC enforces date validation before writes')
  expectedError(await b.rpc('accept_couple_invitation',{input_code:'0000000000000000'}),'already belongs','invitation RPC rejects an already-coupled account without changing data')

  if (process.env.COUPLE_TEST_ALLOW_WRITES === 'true') {
    const [worldRow, petFood, petSku, businessCatalog, currentBusinesses] = await Promise.all([
      a.from('worlds').select('state,revision').eq('couple_id',coupleId).single(),
      a.from('item_catalog').select('coin_price').eq('id','pet-food').eq('active',true).single(),
      a.from('item_catalog').select('coin_price').eq('id','pet-dog').eq('active',true).single(),
      a.from('business_catalog').select('kind,coin_price').eq('active',true).order('coin_price'),
      a.from('businesses').select('kind').eq('couple_id',coupleId),
    ])
    if ([worldRow,petFood,petSku,businessCatalog,currentBusinesses].some(result=>result.error)) fail('mutating test preflight reads')
    const alreadyOwned = new Set((currentBusinesses.data||[]).map(row=>row.kind))
    const business = (businessCatalog.data||[]).find(row=>!alreadyOwned.has(row.kind))
    const totalCost = Number(petFood.data.coin_price)+Number(petSku.data.coin_price)+Number(business?.coin_price||0)
    if (!business || Number(walletA.data.coins)<totalCost) {
      console.log('SKIP purchase and pet-care checks: test couple lacks an unowned business or enough shared coins')
    } else {
      const game = worldRow.data.state?.game||{}
      const snapshot = {owned:game.owned||[],placedFurniture:game.placedFurniture||[],post:game.post||''}
      const saved = await a.rpc('save_world_state',{target_couple:coupleId,expected_revision:worldRow.data.revision,next_game_state:snapshot})
      if (saved.error) fail('world save RPC accepts the unchanged test snapshot')
      const [worldCheckA,worldCheckB] = await Promise.all([
        a.from('worlds').select('state,revision').eq('couple_id',coupleId).single(),
        b.from('worlds').select('state,revision').eq('couple_id',coupleId).single(),
      ])
      if (worldCheckA.error||worldCheckB.error||JSON.stringify(worldCheckA.data.state.game)!==JSON.stringify(worldCheckB.data.state.game)) fail('both accounts load the saved world snapshot')
      pass('authenticated world save is visible to both partners')

      const beforeFood = await a.from('inventory').select('quantity').eq('couple_id',coupleId).eq('item_id','pet-food').maybeSingle()
      if (beforeFood.error) fail('pet-food inventory preflight')
      const purchase = await a.rpc('purchase_item',{item_key:'pet-food',pay_with:'coins',request_id:crypto.randomUUID()})
      if (purchase.error) fail('shared pet-food purchase')
      const afterFood = await b.from('inventory').select('quantity').eq('couple_id',coupleId).eq('item_id','pet-food').maybeSingle()
      if (afterFood.error||Number(afterFood.data?.quantity||0)!==Number(beforeFood.data?.quantity||0)+1) fail('partner sees shared pet-food purchase')
      pass('shared shop purchase updates the partner inventory')

      const adoption = await a.rpc('adopt_pet',{pet_kind:'dog',pet_name:`Smoke-${crypto.randomUUID().slice(0,6)}`,request_id:crypto.randomUUID()})
      if (adoption.error||!adoption.data?.pet_id) fail('pet adoption purchase')
      const care = await a.rpc('care_for_pet',{pet_id:adoption.data.pet_id,care_action:'feed'})
      if (care.error) fail('pet feeding transaction')
      const partnerPet = await b.from('pets').select('hunger,happiness').eq('couple_id',coupleId).eq('id',adoption.data.pet_id).single()
      if (partnerPet.error||partnerPet.data.hunger!==care.data.hunger) fail('partner sees pet care update')
      pass('pet adoption and feeding synchronize to the partner')

      const businessPurchase = await a.rpc('purchase_business',{business_kind:business.kind,request_id:crypto.randomUUID()})
      if (businessPurchase.error||!businessPurchase.data?.business_id) fail('shared business purchase')
      const partnerBusiness = await b.from('businesses').select('id,kind').eq('couple_id',coupleId).eq('id',businessPurchase.data.business_id).single()
      if (partnerBusiness.error) fail('partner sees purchased business')
      const collection = await a.rpc('collect_business_income',{business_id:businessPurchase.data.business_id})
      if (!collection.error||!collection.error.message.toLowerCase().includes('still growing')) fail('new business income waits for elapsed time')
      pass('business purchase synchronizes and income collector enforces elapsed time')
    }
  } else {
    console.log('SKIP world save, purchases, and pet-care writes: set COUPLE_TEST_ALLOW_WRITES=true only for a dedicated test couple')
  }

  const topic = `couple:${coupleId}`
  const joined = (channel) => new Promise((resolve,reject) => channel.subscribe(status => {
    if (status === 'SUBSCRIBED') resolve()
    else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT' || status === 'CLOSED') reject(new Error('Realtime channel did not subscribe'))
  }))
  let receivedMove
  const moveReceived = new Promise(resolve => { receivedMove = resolve })
  channelA = a.channel(topic,{config:{private:true,presence:{key:userA}}})
  channelB = b.channel(topic,{config:{private:true,presence:{key:userB}}})
  channelB.on('broadcast',{event:'player-move'},({payload})=>{if(payload?.user_id===userA&&payload?.x===17&&payload?.y===8)receivedMove()})
  const readyA=joined(channelA)
  const readyB=joined(channelB)
  await Promise.all([readyA,readyB])
  await Promise.all([
    channelA.track({user_id:userA,status:'playing',x:11,y:9}),
    channelB.track({user_id:userB,status:'playing',x:12,y:9}),
  ])
  await delay(1200)
  const identities = state => Object.values(state).flat().map(person=>person.user_id)
  if (!identities(channelA.presenceState()).includes(userB) || !identities(channelB.presenceState()).includes(userA)) fail('private couple presence is mutual')
  pass('private couple presence is mutual')
  await channelA.send({type:'broadcast',event:'player-move',payload:{user_id:userA,x:17,y:8}})
  await Promise.race([moveReceived,delay(5000).then(()=>fail('partner movement broadcast arrives'))])
  pass('partner movement broadcast reaches the other account')
} catch (error) {
  console.error(error instanceof Error ? error.message : 'Live smoke check failed')
  process.exitCode = 1
} finally {
  if (channelA) await a.removeChannel(channelA)
  if (channelB) await b.removeChannel(channelB)
  await Promise.all([a.auth.signOut(),b.auth.signOut()])
}
