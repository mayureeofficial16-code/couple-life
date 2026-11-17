-- Couple Life production migration preflight for migrations 007-011.
-- Run in Supabase SQL Editor using an administrator account.
-- READ ONLY: one WITH/SELECT statement only. Dynamic SQL strings below are SELECTs.
-- No temporary objects, writes, migration changes, or production modifications occur.
-- The final result is one table with one row per inspected object/check.

with
expected_columns(migration,table_name,column_name,expected_type,expected_not_null) as (
  values
    ('007','game_rooms','player_a','uuid',false),
    ('007','game_rooms','player_b','uuid',false),
    ('007','game_rooms','invite_code_hash','text',false),
    ('007','game_rooms','invite_expires_at','timestamptz',false),
    ('007','game_rooms','revision','int8',true),
    ('007','game_rooms','winner_id','uuid',false),
    ('007','game_rooms','started_at','timestamptz',false),
    ('007','game_rooms','finished_at','timestamptz',false),
    ('007','game_room_private','room_id','uuid',true),
    ('007','game_room_private','memory_deck','jsonb',true),
    ('007','game_room_private','word_answer','text',true),
    ('007','game_room_private','created_at','timestamptz',true),
    ('008','advertising_inquiries','user_id','uuid',false),
    ('008','advertising_inquiries','reviewed_at','timestamptz',false),
    ('008','advertising_inquiries','reviewed_by','uuid',false),
    ('008','ad_campaigns','creative_path','text',false),
    ('008','ad_campaigns','creative_alt','text',false),
    ('008','ad_campaigns','booked_duration_days','int4',false),
    ('008','ad_campaigns','quoted_price_myr','int4',false),
    ('008','ad_campaigns','booked_by','uuid',false),
    ('008','ad_clicks','id','uuid',true),
    ('008','ad_clicks','user_id','uuid',true),
    ('008','ad_clicks','campaign_id','uuid',true),
    ('008','ad_clicks','session_id','uuid',true),
    ('008','ad_clicks','clicked_at','timestamptz',true),
    ('008','ad_campaign_admin_audit','id','uuid',true),
    ('008','ad_campaign_admin_audit','campaign_id','uuid',true),
    ('008','ad_campaign_admin_audit','actor_id','uuid',false),
    ('008','ad_campaign_admin_audit','old_status','text',false),
    ('008','ad_campaign_admin_audit','new_status','text',true),
    ('008','ad_campaign_admin_audit','occurred_at','timestamptz',true),
    ('006 dependency','posts','media_path','text',false),
    ('006 dependency','posts','media_type','text',false),
    ('009','pets','accessories','jsonb',true),
    ('009','home_room_catalog','room_key','text',true),
    ('009','home_room_catalog','display_name','text',true),
    ('009','home_room_catalog','coin_price','int4',true),
    ('009','home_room_catalog','sort_order','int4',true),
    ('009','home_room_catalog','active','bool',true),
    ('009','couple_home_rooms','couple_id','uuid',true),
    ('009','couple_home_rooms','room_key','text',true),
    ('009','couple_home_rooms','purchased_by','uuid',true),
    ('009','couple_home_rooms','unlocked_at','timestamptz',true)
),
column_results as (
  select case e.migration when '006 dependency' then 1 when '007' then 1 when '008' then 1 else 1 end as check_number,
         e.migration,'Column'::text as category,
         format('public.%s.%s',e.table_name,e.column_name) as object_name,
         case when a.column_name is null and e.migration='006 dependency' then 'UNEXPECTED MISSING'
              when a.column_name is null then 'EXPECTED MISSING'
              when a.udt_name<>e.expected_type then 'CONFLICT'
              when e.expected_not_null and a.is_nullable<>'NO' then 'CONFLICT'
              when e.migration<>'006 dependency' then 'REVIEW REQUIRED'
              else 'OK' end::text as status,
         jsonb_build_object('expected_type',e.expected_type,'actual_type',a.udt_name,
                            'expected_not_null',e.expected_not_null,'actual_nullable',a.is_nullable,
                            'default',a.column_default) as details
  from expected_columns e
  left join information_schema.columns a
    on a.table_schema='public' and a.table_name=e.table_name and a.column_name=e.column_name
),
expected_functions(migration,signature,expected_before,expected_after,object_state,expected_security_definer) as (
  values
    ('007','public.game_line_winner(integer[],integer,integer,integer)',null,'integer','new',false),
    ('007','public.create_game_room(text)',null,'TABLE(room_id uuid, game text, invite_code text, invite_expires_at timestamp with time zone)','new',true),
    ('007','public.join_game_room(text)',null,'jsonb','new',true),
    ('007','public.leave_game_room(uuid,bigint)',null,'jsonb','new',true),
    ('007','public.submit_game_action(uuid,bigint,jsonb)',null,'jsonb','new',true),
    ('008','public.submit_advertising_inquiry(text,text,text,text,text)',null,'uuid','new',true),
    ('008','public.audit_ad_campaign_status_change()',null,'trigger','new',true),
    ('008','public.admin_create_ad_campaign(text,text,smallint,text,text,text,timestamp with time zone,integer,text,text)',null,'uuid','new',true),
    ('008','public.admin_set_ad_campaign_status(uuid,text)',null,'boolean','new',true),
    ('008','public.admin_mark_ad_inquiry_reviewed(uuid)',null,'boolean','new',true),
    ('008/011','public.record_ad_click(uuid)','boolean','boolean','replace',true),
    ('009','public.adopt_pet(text,text,uuid)','jsonb','jsonb','replace',true),
    ('009','public.equip_pet_accessory(uuid,text)',null,'jsonb','new',true),
    ('009','public.purchase_home_room(text,uuid)',null,'jsonb','new',true),
    ('011','public.complete_ad_view(uuid)','bigint','jsonb','replace',true),
    ('006 dependency','public.start_ad_view(uuid)','uuid','uuid','required',true),
    ('003 dependency','public.ad_campaign_is_active(uuid)','boolean','boolean','required',true),
    ('003 dependency','public.purchase_item(text,text,uuid)','jsonb','jsonb','required',true),
    ('001 dependency','public.is_couple_member(uuid)','boolean','boolean','required',true),
    ('003 dependency','public.is_platform_admin()','boolean','boolean','required',true),
    ('001 dependency','extensions.gen_random_bytes(integer)','bytea','bytea','required',false),
    ('001 dependency','extensions.digest(bytea,text)','bytea','bytea','required',false),
    ('006 dependency','storage.foldername(text)','text[]','text[]','required',false)
),
function_results as (
  select 2 as check_number,e.migration,'Function'::text as category,e.signature as object_name,
         case when p.oid is null and e.object_state in ('required','replace') then 'UNEXPECTED MISSING'
              when p.oid is null then 'EXPECTED MISSING'
              when e.object_state='new' then 'CONFLICT'
              when e.expected_before is not null and pg_get_function_result(p.oid)<>e.expected_before then 'CONFLICT'
              when e.expected_security_definer is not null and p.prosecdef is distinct from e.expected_security_definer then 'CONFLICT'
              else 'OK' end::text as status,
         jsonb_build_object('expected_current_return',e.expected_before,'expected_after_migration',e.expected_after,
                            'actual_return',case when p.oid is not null then pg_get_function_result(p.oid) end,
                            'security_definer',p.prosecdef,'settings',p.proconfig,
                            'anon_can_execute',case when p.oid is not null and exists(select 1 from pg_roles where rolname='anon') then has_function_privilege('anon',p.oid,'EXECUTE') end,
                            'authenticated_can_execute',case when p.oid is not null and exists(select 1 from pg_roles where rolname='authenticated') then has_function_privilege('authenticated',p.oid,'EXECUTE') end) as details
  from expected_functions e
  left join pg_proc p on p.oid=to_regprocedure(e.signature)
),
expected_tables(migration,schema_name,table_name) as (
  values
    ('001','public','game_rooms'),('007','public','game_room_private'),
    ('003','public','advertising_inquiries'),('003','public','ad_campaigns'),
    ('008','public','ad_clicks'),('008','public','ad_campaign_admin_audit'),
    ('001','public','pets'),('003','public','item_catalog'),
    ('009','public','home_room_catalog'),('009','public','couple_home_rooms'),
    ('001','public','posts'),('001','public','couples'),('001','public','couple_members'),
    ('003','public','wallets'),('003','public','wallet_transactions'),
    ('003','public','diamond_wallets'),('003','public','diamond_transactions'),
    ('003','public','ad_view_sessions'),('003','public','ad_reward_claims'),
    ('003','public','advertisement_events'),('003','public','ad_packages'),
    ('003','public','billboard_slots'),('003','public','advertisers'),
    ('Supabase','storage','objects'),('Supabase','storage','buckets')
),
table_results as (
  select 3 as check_number,e.migration,'Table and RLS'::text as category,
         format('%s.%s',e.schema_name,e.table_name) as object_name,
         case when c.oid is null and e.migration in ('007','008','009','010','011') then 'EXPECTED MISSING'
              when c.oid is null then 'UNEXPECTED MISSING'
              when e.migration in ('007','008','009','010','011') then 'REVIEW REQUIRED'
              else 'OK' end::text as status,
         jsonb_build_object('exists',c.oid is not null,'rls_enabled',c.relrowsecurity,
                            'force_rls',c.relforcerowsecurity) as details
  from expected_tables e
  left join pg_namespace n on n.nspname=e.schema_name
  left join pg_class c on c.relnamespace=n.oid and c.relname=e.table_name
),
privilege_results as (
  select 4 as check_number,'001-009'::text as migration,'Table privileges'::text as category,
         format('%I.%I',n.nspname,c.relname) as object_name,'REVIEW REQUIRED'::text as status,
         jsonb_build_object('rls_enabled',c.relrowsecurity,
           'anon_select',has_table_privilege('anon',c.oid,'SELECT'),'anon_insert',has_table_privilege('anon',c.oid,'INSERT'),
           'anon_update',has_table_privilege('anon',c.oid,'UPDATE'),'anon_delete',has_table_privilege('anon',c.oid,'DELETE'),
           'authenticated_select',has_table_privilege('authenticated',c.oid,'SELECT'),
           'authenticated_insert',has_table_privilege('authenticated',c.oid,'INSERT'),
           'authenticated_update',has_table_privilege('authenticated',c.oid,'UPDATE'),
           'authenticated_delete',has_table_privilege('authenticated',c.oid,'DELETE')) as details
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where (n.nspname='public' and c.relname=any(array[
    'game_rooms','game_room_private','ad_campaigns','advertising_inquiries','ad_clicks',
    'ad_campaign_admin_audit','pets','item_catalog','home_room_catalog','couple_home_rooms','posts'
  ])) or (n.nspname='storage' and c.relname='objects')
),
expected_indexes(migration,table_name,index_name) as (
  values
    ('007','game_rooms','game_room_invite_hash_unique'),
    ('007','game_rooms','game_rooms_couple_updated'),
    ('008','advertising_inquiries','advertising_inquiries_user_created'),
    ('008','ad_clicks','ad_clicks_campaign_clicked'),
    ('006 dependency','posts','posts_couple_timeline')
),
index_results as (
  select 5 as check_number,e.migration,'Index'::text as category,
         format('public.%s.%s',e.table_name,e.index_name) as object_name,
         case when i.indexname is null and e.migration='006 dependency' then 'UNEXPECTED MISSING'
              when i.indexname is null then 'EXPECTED MISSING'
              else 'REVIEW REQUIRED' end::text as status,
         jsonb_build_object('definition',i.indexdef,'note','Compare an existing same-name index with the migration definition; IF NOT EXISTS does not repair a mismatched index.') as details
  from expected_indexes e
  left join pg_indexes i on i.schemaname='public' and i.tablename=e.table_name and i.indexname=e.index_name
  union all
  select 5,'existing','Index',format('%I.%I',schemaname,indexname),'REVIEW REQUIRED',jsonb_build_object('table',tablename,'definition',indexdef)
  from pg_indexes where schemaname='public' and tablename=any(array[
    'game_rooms','advertising_inquiries','ad_clicks','ad_campaigns','ad_campaign_admin_audit',
    'pets','home_room_catalog','couple_home_rooms','posts'
  ]) and indexname not in (select index_name from expected_indexes)
),
trigger_results as (
  select 6 as check_number,'008'::text as migration,'Trigger'::text as category,
         'public.ad_campaigns.ad_campaign_status_audit'::text as object_name,
         case when t.oid is null then 'EXPECTED MISSING' else 'REVIEW REQUIRED' end::text as status,
         jsonb_build_object('definition',pg_get_triggerdef(t.oid,true),'note','Compare function and event with migration 008.') as details
  from (select to_regclass('public.ad_campaigns') as campaign_table) b
  left join pg_trigger t on t.tgrelid=b.campaign_table and t.tgname='ad_campaign_status_audit' and not t.tgisinternal
  union all
  select 6,'existing','Trigger',format('%I.%I.%I',n.nspname,c.relname,t.tgname),'REVIEW REQUIRED',
         jsonb_build_object('definition',pg_get_triggerdef(t.oid,true),'enabled',t.tgenabled)
  from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
  where not t.tgisinternal and n.nspname='public'
    and c.relname=any(array['game_rooms','ad_campaigns','advertising_inquiries','pets','home_room_catalog','couple_home_rooms','posts'])
    and t.tgname<>'ad_campaign_status_audit'
),
expected_policies(migration,schema_name,table_name,policy_name) as (
  values
    ('006 dependency','public','posts','members read couple posts'),
    ('006 dependency','public','posts','authors create couple posts'),
    ('006 dependency','public','posts','authors update own couple posts'),
    ('006 dependency','public','posts','authors delete own couple posts'),
    ('006 dependency','public','comments','members read post comments'),
    ('006 dependency','public','comments','authors create post comments'),
    ('006 dependency','public','comments','authors update own comments'),
    ('006 dependency','public','comments','authors delete own comments'),
    ('006 dependency','public','reactions','members read post reactions'),
    ('006 dependency','public','reactions','users create own reactions'),
    ('006 dependency','public','reactions','users update own reactions'),
    ('006 dependency','public','reactions','users delete own reactions'),
    ('006 dependency','storage','objects','couple members read shared media'),
    ('006 dependency','storage','objects','couple members upload own media path'),
    ('006 dependency','storage','objects','owners update own couple media'),
    ('006 dependency','storage','objects','owners delete own couple media'),
    ('006 dependency','storage','objects','restrict couple media reads'),
    ('006 dependency','storage','objects','restrict couple media inserts'),
    ('006 dependency','storage','objects','restrict couple media updates'),
    ('006 dependency','storage','objects','restrict couple media deletes'),
    ('003 dependency','public','ad_campaigns','read active campaigns'),
    ('003 dependency','public','ad_campaigns','admin manages campaign rows'),
    ('003 dependency','public','advertising_inquiries','admin reads ad inquiries'),
    ('008','public','ad_clicks','admin reads ad clicks'),
    ('008','public','ad_clicks','user reads own ad clicks'),
    ('008','public','ad_campaign_admin_audit','platform admins read campaign audit'),
    ('008','storage','objects','public read ad creatives'),
    ('008','storage','objects','admins upload ad creatives'),
    ('008','storage','objects','admins update ad creatives'),
    ('008','storage','objects','admins delete ad creatives'),
    ('008','storage','objects','ad creatives admin-only insert guard'),
    ('008','storage','objects','ad creatives admin-only update guard'),
    ('008','storage','objects','ad creatives admin-only delete guard'),
    ('009','public','home_room_catalog','read active home room catalog'),
    ('009','public','home_room_catalog','admin manages home room catalog'),
    ('009','public','couple_home_rooms','members read home rooms')
),
policy_results as (
  select 7 as check_number,e.migration,'RLS policy'::text as category,
         format('%s.%s.%s',e.schema_name,e.table_name,e.policy_name) as object_name,
         case when p.policyname is null and e.migration in ('006 dependency','003 dependency') then 'UNEXPECTED MISSING'
              when p.policyname is null then 'EXPECTED MISSING'
              else 'REVIEW REQUIRED' end::text as status,
         jsonb_build_object('command',p.cmd,'permissive',p.permissive,'roles',p.roles,
                            'using',p.qual,'with_check',p.with_check) as details
  from expected_policies e
  left join pg_policies p on p.schemaname=e.schema_name and p.tablename=e.table_name and p.policyname=e.policy_name
  union all
  select 7,'additional','RLS policy',format('%s.%s.%s',p.schemaname,p.tablename,p.policyname),
         'REVIEW REQUIRED',jsonb_build_object('command',p.cmd,'permissive',p.permissive,'roles',p.roles,'using',p.qual,'with_check',p.with_check)
  from pg_policies p
  where ((p.schemaname='public' and p.tablename=any(array[
           'game_rooms','game_room_private','ad_campaigns','advertising_inquiries','ad_clicks',
           'ad_campaign_admin_audit','pets','item_catalog','home_room_catalog','couple_home_rooms','posts','comments','reactions'
         ])) or (p.schemaname='storage' and p.tablename='objects'))
    and not exists(select 1 from expected_policies e where e.schema_name=p.schemaname and e.table_name=p.tablename and e.policy_name=p.policyname)
),
bucket_xml as (
  select case when to_regclass('storage.buckets') is null then null::xml
              else query_to_xml(format(
                'select id,name,public,file_size_limit,array_to_string(allowed_mime_types,chr(44)) as allowed_mime_types,created_at,updated_at from storage.buckets where id=%L',
                'advertising-creatives'),false,false,'') end as xml_value
),
bucket_result as (
  select 8 as check_number,'008'::text as migration,'Storage bucket'::text as category,
         'advertising-creatives'::text as object_name,
         case when to_regclass('storage.buckets') is null then 'UNEXPECTED MISSING'
              when array_length(xpath('/table/row',xml_value),1) is null then 'EXPECTED MISSING'
              when (xpath('/table/row/public/text()',xml_value))[1]::text<>'true'
                or (xpath('/table/row/file_size_limit/text()',xml_value))[1]::text<>'5242880'
                or (xpath('/table/row/allowed_mime_types/text()',xml_value))[1]::text<>'image/jpeg,image/png,image/webp' then 'CONFLICT'
              else 'OK' end::text as status,
         jsonb_build_object('configuration_xml',xml_value,'expected_public',true,'expected_file_size_limit',5242880,
                            'expected_mime_types',array['image/jpeg','image/png','image/webp']) as details
  from bucket_xml
),
storage_policy_results as (
  select 9 as check_number,'008 and existing Storage policies'::text as migration,'Storage policy'::text as category,
         format('%s.%s.%s',p.schemaname,p.tablename,p.policyname) as object_name,
         'REVIEW REQUIRED'::text as status,
         jsonb_build_object('command',p.cmd,'permissive',p.permissive,'roles',p.roles,'using',p.qual,'with_check',p.with_check) as details
  from pg_policies p where p.schemaname='storage' and p.tablename='objects'
),
expected_item_seeds(id) as (values ('pet-bird'),('pet-bow'),('pet-toy'),('pet-bed')),
item_seed_xml as (
  select e.id,
         case when to_regclass('public.item_catalog') is null then null::xml
              else query_to_xml(format('select id,name,category,coin_price,diamond_price,ownership_scope,stackable,active,metadata from public.item_catalog where id=%L',e.id),false,false,'') end as xml_value
  from expected_item_seeds e
),
item_seed_results as (
  select 10 as check_number,'009'::text as migration,'Catalog seed overwrite'::text as category,
         format('item_catalog.%s',id) as object_name,
         case when to_regclass('public.item_catalog') is null then 'UNEXPECTED MISSING'
              when array_length(xpath('/table/row',xml_value),1)>0 then 'CONFLICT'
              else 'EXPECTED MISSING' end::text as status,
         jsonb_build_object('existing_row_xml',xml_value,'migration_upsert_will_overwrite_if_present',true) as details
  from item_seed_xml
),
expected_room_seeds(room_key) as (values ('garden-room'),('reading-room')),
room_seed_xml as (
  select e.room_key,
         case when to_regclass('public.home_room_catalog') is null then null::xml
              else query_to_xml(format('select room_key,display_name,coin_price,sort_order,active from public.home_room_catalog where room_key=%L',e.room_key),false,false,'') end as xml_value
  from expected_room_seeds e
),
room_seed_results as (
  select 11 as check_number,'009'::text as migration,'Home-room seed overwrite'::text as category,
         format('home_room_catalog.%s',room_key) as object_name,
         case when to_regclass('public.home_room_catalog') is null then 'EXPECTED MISSING'
              when array_length(xpath('/table/row',xml_value),1)>0 then 'CONFLICT'
              else 'EXPECTED MISSING' end::text as status,
         jsonb_build_object('existing_row_xml',xml_value,'migration_upsert_will_overwrite_if_present',true) as details
  from room_seed_xml
),
expected_media_constraints(constraint_name,migration) as (
  values ('posts_media_pair_valid','006 dependency'),('posts_media_pair_strict','010')
),
media_constraint_results as (
  select 12 as check_number,e.migration,'Media constraint'::text as category,
         format('public.posts.%s',e.constraint_name) as object_name,
         case when to_regclass('public.posts') is null then 'UNEXPECTED MISSING'
              when c.oid is null and e.migration='006 dependency' then 'UNEXPECTED MISSING'
              when c.oid is null then 'EXPECTED MISSING'
              when pg_get_constraintdef(c.oid,true) not ilike '%media_path%'
                or pg_get_constraintdef(c.oid,true) not ilike '%media_type%' then 'CONFLICT'
              else 'REVIEW REQUIRED' end::text as status,
         jsonb_build_object('definition',pg_get_constraintdef(c.oid,true),'validated',c.convalidated,
                            'note','Migration 010 intentionally adds a second check equivalent to migration 006; compare definitions.') as details
  from expected_media_constraints e
  left join pg_constraint c on c.conrelid=to_regclass('public.posts') and c.conname=e.constraint_name
),
other_constraint_results as (
  select 13 as check_number,'008/009'::text as migration,'Constraint'::text as category,
         format('public.%s.%s',t.relname,c.conname) as object_name,
         'REVIEW REQUIRED'::text as status,
         jsonb_build_object('type',c.contype,'validated',c.convalidated,'definition',pg_get_constraintdef(c.oid,true)) as details
  from pg_constraint c join pg_class t on t.oid=c.conrelid join pg_namespace n on n.oid=t.relnamespace
  where n.nspname='public' and (
    (t.relname='ad_campaigns' and c.conname like 'ad_campaign_%') or
    (t.relname='pets' and c.conname='pets_accessories_array') or
    (t.relname='game_rooms' and c.conname like 'game_room_%')
  )
),
realtime_results as (
  select 14 as check_number,'001/002/009'::text as migration,'Realtime publication'::text as category,
         format('supabase_realtime.public.%s',e.table_name) as object_name,
         case when r.tablename is not null then 'OK'
              when e.migration='009' then 'EXPECTED MISSING'
              else 'UNEXPECTED MISSING' end::text as status,
         jsonb_build_object('published',r.tablename is not null) as details
  from (values ('game_rooms','001/002'),('couple_home_rooms','009')) e(table_name,migration)
  left join pg_publication_tables r on r.pubname='supabase_realtime' and r.schemaname='public' and r.tablename=e.table_name
),
prerequisite_results as (
  select 15 as check_number,'Supabase/PostgreSQL'::text as migration,'Prerequisite'::text as category,
         'pgcrypto'::text as object_name,
         case when not exists(select 1 from pg_extension where extname='pgcrypto') then 'UNEXPECTED MISSING'
              when (select n.nspname from pg_extension e join pg_namespace n on n.oid=e.extnamespace where e.extname='pgcrypto')<>'extensions' then 'CONFLICT'
              else 'OK' end::text as status,
         jsonb_build_object('installed',exists(select 1 from pg_extension where extname='pgcrypto'),
           'schema',(select n.nspname from pg_extension e join pg_namespace n on n.oid=e.extnamespace where e.extname='pgcrypto'),
           'required_schema','extensions') as details
  union all
  select 15,'Supabase/PostgreSQL','Prerequisite','supabase_realtime',
         case when exists(select 1 from pg_publication where pubname='supabase_realtime') then 'OK' else 'UNEXPECTED MISSING' end,
         jsonb_build_object('exists',exists(select 1 from pg_publication where pubname='supabase_realtime'))
  union all
  select 15,'Supabase/PostgreSQL','Prerequisite','storage schema',
         case when exists(select 1 from pg_namespace where nspname='storage') then 'OK' else 'UNEXPECTED MISSING' end,
         jsonb_build_object('exists',exists(select 1 from pg_namespace where nspname='storage'))
),
function_dependency_results as (
  select 16 as check_number,'011'::text as migration,'Function dependency'::text as category,
         'public.complete_ad_view(uuid)'::text as object_name,
         case when to_regprocedure('public.complete_ad_view(uuid)') is null then 'UNEXPECTED MISSING'
              when coalesce(d.dependency_count,0)>0 then 'CONFLICT'
              else 'OK' end::text as status,
         jsonb_build_object('dependent_object_count',coalesce(d.dependency_count,0),
                            'dependent_objects',coalesce(d.dependent_objects,''),
                            'note','Migration 011 drops and recreates this function to change its return type.') as details
  from (select 1) seed
  left join lateral (
    select count(*) as dependency_count,
           string_agg(pg_describe_object(x.classid,x.objid,x.objsubid),'; ') as dependent_objects
    from pg_depend x
    where x.refclassid='pg_proc'::regclass
      and x.refobjid=to_regprocedure('public.complete_ad_view(uuid)')::oid
  ) d on true
),
media_data_xml as (
  select case
    when to_regclass('public.posts') is null then null::xml
    when (select count(*) from information_schema.columns where table_schema='public' and table_name='posts' and column_name in ('media_path','media_type'))<2 then null::xml
    else query_to_xml(
      'select count(*) as invalid_media_pair_rows from public.posts where not ((media_path is null and media_type is null) or (media_path is not null and media_type is not null and media_type in (''image'',''video'')))',
      false,false,'')
  end as xml_value
),
media_data_result as (
  select 17 as check_number,'006/010'::text as migration,'Legacy media data'::text as category,
         'public.posts media path/type pairs'::text as object_name,
         case when to_regclass('public.posts') is null then 'UNEXPECTED MISSING'
              when (select count(*) from information_schema.columns where table_schema='public' and table_name='posts' and column_name in ('media_path','media_type'))<2 then 'UNEXPECTED MISSING'
              when (xpath('/table/row/invalid_media_pair_rows/text()',xml_value))[1]::text::bigint>0 then 'CONFLICT'
              else 'OK' end::text as status,
         jsonb_build_object('invalid_legacy_rows',(xpath('/table/row/invalid_media_pair_rows/text()',xml_value))[1]::text,
                            'note','NOT VALID avoids scanning old rows during migration but violating rows can fail when later updated.') as details
  from media_data_xml
),
audit_results as (
  select * from column_results
  union all select * from function_results
  union all select * from table_results
  union all select * from privilege_results
  union all select * from index_results
  union all select * from trigger_results
  union all select * from policy_results
  union all select * from bucket_result
  union all select * from storage_policy_results
  union all select * from item_seed_results
  union all select * from room_seed_results
  union all select * from media_constraint_results
  union all select * from other_constraint_results
  union all select * from realtime_results
  union all select * from prerequisite_results
  union all select * from function_dependency_results
  union all select * from media_data_result
)
select check_number,migration,category,object_name,status,details::text as details
from audit_results
order by check_number,migration,category,object_name;
