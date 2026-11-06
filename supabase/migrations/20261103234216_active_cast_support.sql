-- Additive Active Cast controls. Original media, receipts, quotas and closure are untouched.
alter table public.destination_connections drop constraint destination_connections_platform_check;
alter table public.destination_connections add constraint destination_connections_platform_check
 check (platform in ('youtube','facebook','tiktok','twitch','x','other'));

create table public.cast_preset_libraries (
 owner_id uuid primary key references auth.users(id) on delete cascade,
 revision bigint not null default 0,
 presets jsonb not null default '[]',
 favorite_ids text[] not null default '{}',
 updated_at timestamptz not null default now(),
 check (jsonb_typeof(presets) = 'array' and jsonb_array_length(presets) <= 100),
 check (cardinality(favorite_ids) <= 4)
);
create table mycamcast_private.cast_requests (
 owner_id uuid not null references auth.users(id) on delete cascade,
 request_id uuid not null,
 action text not null,
 payload jsonb not null,
 response jsonb not null,
 created_at timestamptz not null default now(),
 primary key(owner_id,request_id)
);
create table public.active_casts (
 incident_id uuid primary key,
 owner_id uuid not null,
 preset_snapshot jsonb not null,
 consent jsonb not null,
 started_at timestamptz not null default now(),
 stop_requested_at timestamptz,
 event_cursor bigint not null default 0,
 foreign key(incident_id,owner_id) references public.incidents(id,owner_id) on delete cascade
);
-- No raw bearer token, OAuth token or storage URL is persisted or returned to owners here.
create table public.cast_viewer_grants (
 id uuid primary key,
 incident_id uuid not null references public.active_casts(incident_id) on delete cascade,
 owner_id uuid not null references auth.users(id) on delete cascade,
 recipient_phone text not null,
 include_video boolean not null,
 include_location boolean not null,
 expires_at timestamptz not null,
 revoked_at timestamptz,
 blocked_at timestamptz,
 created_at timestamptz not null default now(),
 check (include_video or include_location),
 check (expires_at > created_at and expires_at <= created_at + interval '24 hours')
);
create table mycamcast_private.cast_tokens (
 grant_id uuid primary key references public.cast_viewer_grants(id) on delete cascade,
 token_hash text unique not null check (token_hash ~ '^[a-f0-9]{64}$')
);
create table mycamcast_private.cast_presence (
 grant_id uuid primary key references public.cast_viewer_grants(id) on delete cascade,
 last_seen_at timestamptz not null
);
create table public.cast_access_audit (
 id bigint generated always as identity primary key,
 grant_id uuid not null references public.cast_viewer_grants(id) on delete cascade,
 incident_id uuid not null references public.active_casts(incident_id) on delete cascade,
 owner_id uuid not null references auth.users(id) on delete cascade,
 action text not null,
 occurred_at timestamptz not null default now()
);
create table public.cast_location_samples (
 id uuid primary key,
 incident_id uuid not null,
 owner_id uuid not null,
 device_recorded_at timestamptz not null,
 received_at timestamptz not null default now(),
 latitude double precision not null check(latitude between -90 and 90),
 longitude double precision not null check(longitude between -180 and 180),
 accuracy_m double precision not null check(accuracy_m >= 0 and accuracy_m < 'Infinity'::float8),
 share_with_recipients boolean not null,
 foreign key(incident_id,owner_id) references public.incidents(id,owner_id) on delete cascade
);
create index cast_location_latest on public.cast_location_samples(incident_id,device_recorded_at desc);
create table public.cast_messages (
 id uuid primary key,
 incident_id uuid not null references public.active_casts(incident_id) on delete cascade,
 owner_id uuid not null references auth.users(id) on delete cascade,
 grant_id uuid not null references public.cast_viewer_grants(id) on delete cascade,
 body text not null check(char_length(body) between 1 and 500),
 moderation text not null default 'pending' check(moderation in ('pending','approved','rejected','removed')),
 sender_label text not null default 'Guest',
 verified_user_id uuid, -- never inferred from a phone number or bearer token
 created_at timestamptz not null default now()
);
create index cast_messages_rate on public.cast_messages(grant_id,created_at);
create table public.cast_message_events (
 incident_id uuid not null references public.active_casts(incident_id) on delete cascade,
 owner_id uuid not null references auth.users(id) on delete cascade,
 seq bigint not null,
 message_id uuid not null references public.cast_messages(id) on delete cascade,
 kind text not null check(kind in ('approved','removed')),
 occurred_at timestamptz not null default now(),
 primary key(incident_id,seq)
);
-- Independent operation records. 'unavailable' is NOT queued, sent, live or ended.
create table public.cast_jobs (
 id uuid primary key default gen_random_uuid(),
 incident_id uuid not null references public.active_casts(incident_id) on delete cascade,
 owner_id uuid not null references auth.users(id) on delete cascade,
 kind text not null check(kind in ('sms','broadcast_start','broadcast_end')),
 target text not null,
 payload jsonb not null,
 state text not null default 'unavailable' check(state in ('unavailable','queued','working','ambiguous','retry','confirmed','failed')),
 error_code text,
 attempts integer not null default 0,
 next_attempt_at timestamptz,
 provider_id text,
 provider_confirmed_at timestamptz,
 unique(incident_id,kind,target),
 check(state <> 'confirmed' or provider_confirmed_at is not null)
);
create index cast_jobs_due on public.cast_jobs(state,next_attempt_at);
create index cast_jobs_owner on public.cast_jobs(owner_id);
create index cast_grants_incident on public.cast_viewer_grants(incident_id);
create index cast_messages_incident on public.cast_messages(incident_id,created_at);
create index cast_audit_incident on public.cast_access_audit(incident_id,occurred_at);
create index cast_audit_grant_action on public.cast_access_audit(grant_id,action,occurred_at desc);

do $$ declare t text; begin
 foreach t in array array['cast_preset_libraries','active_casts','cast_viewer_grants','cast_access_audit','cast_location_samples','cast_messages','cast_message_events','cast_jobs'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated',t);
  execute format('grant select on public.%I to authenticated',t);
  execute format('grant all on public.%I to service_role',t);
  execute format('create policy owner_read on public.%I for select to authenticated using(owner_id = (select auth.uid()))',t);
 end loop;
end $$;
revoke all on mycamcast_private.cast_requests,mycamcast_private.cast_tokens,mycamcast_private.cast_presence from public,anon,authenticated;

create function mycamcast_private.core_presets() returns jsonb language sql immutable set search_path = '' as $$
 select jsonb_agg(jsonb_build_object('id',id,'name',name,'description',description,'artwork',id,'builtin',true,'socialPlatforms','[]'::jsonb,'liveView',false,'sendLocation',false,'recipients','[]'::jsonb) order by ord)
 from (values
 (1,'traffic-stop','Traffic Stop','Keep a private record of a traffic stop.'),
 (2,'police-encounter','Police Encounter','Document an encounter with a police officer.'),
 (3,'stranger-encounter','Stranger Encounter','Keep a record of an unfamiliar encounter.'),
 (4,'altercation','Altercation','Document an altercation and preserve your account.')
 ) as c(ord,id,name,description);
$$;

-- Fixed search path and explicit owner checks are required despite SECURITY DEFINER.
create function mycamcast_private.cast_control(p_action text,p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 u uuid := auth.uid(); lib public.cast_preset_libraries; req uuid; prior mycamcast_private.cast_requests;
 result jsonb; item jsonb; core jsonb; normalized jsonb := '[]'; contacts jsonb; r jsonb;
 ids text[] := '{}'; fav text[]; phone text; phones text[]; preset jsonb; iid uuid;
 i public.incidents; c public.active_casts; g public.cast_viewer_grants; m public.cast_messages;
 consent jsonb; platforms text[]; platform text; cur bigint; gid uuid; ts timestamptz;
begin
 if u is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_input is null or jsonb_typeof(p_input) <> 'object' or octet_length(p_input::text) > 131072 then raise exception 'invalid_input'; end if;
 -- One owner lock also serializes first registration, favorites, imports and idempotency.
 perform 1 from public.profiles where id=u for update;
 insert into public.cast_preset_libraries(owner_id,presets,favorite_ids)
 values(u,mycamcast_private.core_presets(),array['traffic-stop','police-encounter','stranger-encounter','altercation']) on conflict do nothing;
 select * into lib from public.cast_preset_libraries where owner_id=u;
 if p_action='presets_get' then return to_jsonb(lib); end if;
 if p_action in ('presets_save','presets_import','start','end','grant','location','revoke','block','moderate') then
  req := (p_input->>'request_id')::uuid;
  if req is null then raise exception 'request_id_required'; end if;
  select * into prior from mycamcast_private.cast_requests where owner_id=u and request_id=req;
  if found then
   if prior.action <> p_action or prior.payload <> p_input then raise exception 'idempotency_conflict' using errcode='22023'; end if;
   return prior.response;
  end if;
 end if;
 if p_action in ('presets_save','presets_import') then
  if (p_input->>'base_revision')::bigint is distinct from lib.revision or (p_action='presets_import' and lib.revision<>0) then
   return jsonb_build_object('error','revision_conflict','current',to_jsonb(lib));
  end if;
  if jsonb_typeof(p_input->'presets') is distinct from 'array' or jsonb_array_length(p_input->'presets') not between 4 and 100 then raise exception 'invalid_presets'; end if;
  for item in select value from jsonb_array_elements(p_input->'presets') loop
   if jsonb_typeof(item) <> 'object' or item->>'id' is null or (item->>'id')=any(ids) then raise exception 'invalid_preset_id'; end if;
   ids := array_append(ids,item->>'id');
   select value into core from jsonb_array_elements(mycamcast_private.core_presets()) where value->>'id'=item->>'id';
   if core is not null then
    -- Explicit legacy import restores canonical identities. Normal saves reject edits.
    if p_action='presets_save' and (item->>'name' is distinct from core->>'name' or item->>'description' is distinct from core->>'description' or item->>'artwork' is distinct from core->>'artwork' or item->'builtin' is distinct from 'true'::jsonb) then raise exception 'core_identity_immutable'; end if;
   else
    if (item->>'id') !~ '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$' then raise exception 'custom_id_must_be_uuid'; end if;
    if jsonb_typeof(item->'name') is distinct from 'string' or char_length(btrim(item->>'name')) not between 1 and (case when p_action='presets_import' then 64 when exists(select 1 from jsonb_array_elements(lib.presets) old where old->>'id'=item->>'id' and old->>'name'=btrim(item->>'name') and old->>'description'=coalesce(item->>'description','') and old->'legacy_name'='true'::jsonb) then 64 else 12 end) then raise exception 'custom_name_length'; end if;
    core := jsonb_build_object('id',item->>'id','name',btrim(item->>'name'),'description',coalesce(item->>'description',''),'artwork','text','builtin',false,'legacy_name',char_length(btrim(item->>'name'))>12);
   end if;
   if char_length(coalesce(item->>'description',''))>240 then raise exception 'description_length'; end if;
   if jsonb_typeof(coalesce(item->'socialPlatforms','[]')) <> 'array' then raise exception 'invalid_platforms'; end if;
   select coalesce(array_agg(distinct value),'{}') into platforms from jsonb_array_elements_text(coalesce(item->'socialPlatforms','[]'));
   if not platforms <@ array['facebook','tiktok','youtube','x','twitch'] then raise exception 'invalid_platform'; end if;
   if jsonb_typeof(coalesce(item->'liveView','false')) <> 'boolean' or jsonb_typeof(coalesce(item->'sendLocation','false')) <> 'boolean' then raise exception 'invalid_sharing_flags'; end if;
   contacts := '[]'; phones := '{}';
   if jsonb_typeof(coalesce(item->'recipients','[]')) <> 'array' or jsonb_array_length(coalesce(item->'recipients','[]'))>20 then raise exception 'invalid_recipients'; end if;
   for r in select value from jsonb_array_elements(coalesce(item->'recipients','[]')) loop
    phone := regexp_replace(btrim(r->>'phone'),'[[:space:]().-]','','g');
    if phone is null or phone !~ '^\+[1-9][0-9]{6,14}$' or phone=any(phones) or char_length(coalesce(r->>'name',''))>80 then raise exception 'invalid_or_duplicate_recipient'; end if;
    phones := array_append(phones,phone);
    contacts := contacts || jsonb_build_array(jsonb_build_object('name',btrim(coalesce(r->>'name','')),'phone',phone));
   end loop;
   if (coalesce((item->>'liveView')::boolean,false) or coalesce((item->>'sendLocation')::boolean,false)) and contacts='[]'::jsonb then raise exception 'recipients_required'; end if;
   normalized := normalized || jsonb_build_array(core || jsonb_build_object('socialPlatforms',to_jsonb(platforms),'liveView',coalesce((item->>'liveView')::boolean,false),'sendLocation',coalesce((item->>'sendLocation')::boolean,false),'recipients',contacts));
  end loop;
  if not array['traffic-stop','police-encounter','stranger-encounter','altercation'] <@ ids then raise exception 'core_presets_required'; end if;
  if jsonb_typeof(p_input->'favorite_ids') is distinct from 'array' then raise exception 'favorite_ids_required'; end if;
  select coalesce(array_agg(value order by ord),'{}') into fav from jsonb_array_elements_text(p_input->'favorite_ids') with ordinality as f(value,ord);
  if cardinality(fav)>4 or not fav <@ ids or cardinality(fav)<>(select count(distinct x) from unnest(fav) x) then raise exception 'invalid_favorites'; end if;
  update public.cast_preset_libraries set presets=normalized,favorite_ids=fav,revision=revision+1,updated_at=now() where owner_id=u returning to_jsonb(cast_preset_libraries.*) into result;
 elsif p_action='start' then
  iid := (p_input->>'incident_id')::uuid;
  select * into preset from jsonb_array_elements(lib.presets) where value->>'id'=p_input->>'preset_id';
  if preset is null or (p_input->>'preset_revision')::bigint is distinct from lib.revision then raise exception 'preset_revision_conflict'; end if;
  consent := p_input->'consent';
  if jsonb_typeof(consent) is distinct from 'object' or jsonb_typeof(consent->'video') is distinct from 'boolean' or jsonb_typeof(consent->'location') is distinct from 'boolean' or jsonb_typeof(consent->'sms') is distinct from 'boolean' or jsonb_typeof(consent->'platforms') is distinct from 'array' then raise exception 'explicit_consent_required'; end if;
  select coalesce(array_agg(distinct value),'{}') into platforms from jsonb_array_elements_text(consent->'platforms');
  if not platforms <@ array(select jsonb_array_elements_text(preset->'socialPlatforms')) or ((consent->>'video')::boolean and not (preset->>'liveView')::boolean) or ((consent->>'location')::boolean and not (preset->>'sendLocation')::boolean) then raise exception 'consent_exceeds_preset'; end if;
  if (select count(*) from public.active_casts where owner_id=u and started_at>now()-interval '1 hour')>=60 then raise exception 'start_rate_limit'; end if;
  -- May register before segment zero or adopt an existing native-capture incident.
  insert into public.incidents(id,owner_id,device_started_at,device_timezone,title,is_test)
   values(iid,u,(p_input->>'device_started_at')::timestamptz,coalesce(p_input->>'device_timezone','UTC'),preset->>'name',coalesce((p_input->>'is_test')::boolean,false)) on conflict(id) do nothing;
  select * into i from public.incidents where id=iid and owner_id=u for update;
  if not found or i.deletion_requested_at is not null or i.server_closed_at is not null then raise exception 'incident_unavailable'; end if;
  if i.device_started_at is distinct from (p_input->>'device_started_at')::timestamptz or i.device_timezone is distinct from coalesce(p_input->>'device_timezone','UTC') or i.is_test is distinct from coalesce((p_input->>'is_test')::boolean,false) then raise exception 'incident_registration_conflict'; end if;
  if exists(select 1 from public.active_casts where incident_id=iid) then raise exception 'cast_already_registered_use_original_request'; end if;
  insert into public.active_casts(incident_id,owner_id,preset_snapshot,consent) values(iid,u,preset,consent);
  foreach platform in array platforms loop
   insert into public.broadcast_sessions(incident_id,owner_id,platform,state,error_code) values(iid,u,platform,'unavailable',platform||'_oauth_eligibility_and_ingest_not_configured');
   insert into public.cast_jobs(incident_id,owner_id,kind,target,payload,error_code) values(iid,u,'broadcast_start',platform,'{}',platform||'_oauth_eligibility_and_ingest_not_configured');
  end loop;
  if (consent->>'sms')::boolean and ((consent->>'video')::boolean or (consent->>'location')::boolean) then
   for r in select value from jsonb_array_elements(preset->'recipients') loop
    insert into public.cast_jobs(incident_id,owner_id,kind,target,payload,error_code)
    values(iid,u,'sms',r->>'phone',jsonb_build_object('video',(consent->>'video')::boolean,'location',(consent->>'location')::boolean),'sms_provider_sender_recipient_consent_and_viewer_host_not_configured');
   end loop;
  end if;
  result := jsonb_build_object('incident_id',iid,'control_state','registered','capture_state','device_managed','live_view','ingest_transcode_distribution_not_configured','sms','not_configured');
 elsif p_action in ('status','feed','end','grant','revoke','block','location','moderate') then
  iid := (p_input->>'incident_id')::uuid;
  select * into c from public.active_casts where incident_id=iid and owner_id=u for no key update;
  if not found then raise exception 'cast_unavailable' using errcode='42501'; end if;
  select * into i from public.incidents where id=iid;
  if p_action='end' then
   update public.active_casts set stop_requested_at=coalesce(stop_requested_at,now()) where incident_id=iid;
   update public.cast_viewer_grants set revoked_at=coalesce(revoked_at,now()) where incident_id=iid;
   -- Provider state is retained: a failed end can leave a confirmed broadcast live.
   insert into public.cast_jobs(incident_id,owner_id,kind,target,payload,error_code)
   select iid,u,'broadcast_end',bs.platform,'{}',case when bs.state='live' then 'provider_end_unconfirmed_may_still_be_live' else 'provider_adapter_not_configured' end
   from public.broadcast_sessions bs where bs.incident_id=iid on conflict(incident_id,kind,target) do nothing;
   result := jsonb_build_object('incident_id',iid,'control_state','stop_requested','provider_end_confirmed',false,'upload_closure','unchanged');
  elsif p_action='status' then
   result := to_jsonb(c) || jsonb_build_object('camcast_viewer_count',(select count(*) from mycamcast_private.cast_presence p join public.cast_viewer_grants v on v.id=p.grant_id where v.incident_id=iid and p.last_seen_at>clock_timestamp()-interval '45 seconds' and v.revoked_at is null and v.blocked_at is null and v.expires_at>clock_timestamp() and i.deletion_requested_at is null),'external_viewer_counts','{}'::jsonb,'live_view','ingest_transcode_distribution_not_configured','jobs',coalesce((select jsonb_agg(to_jsonb(j)) from public.cast_jobs j where j.incident_id=iid),'[]'::jsonb));
  elsif p_action='feed' then
   cur := coalesce((p_input->>'after')::bigint,0);
   if cur<0 then raise exception 'invalid_cursor'; end if;
   select jsonb_build_object('events',coalesce(jsonb_agg((to_jsonb(e)-'seq') || jsonb_build_object('cursor',e.seq::text) order by seq),'[]'),'next_cursor',coalesce(max(seq),cur)::text,'head_cursor',c.event_cursor::text) into result from (
    select e.seq,e.message_id,e.kind,e.occurred_at,
     case when msg.moderation='approved' and e.kind='approved' then msg.body else null end as body,msg.sender_label,msg.verified_user_id
    from public.cast_message_events e join public.cast_messages msg on msg.id=e.message_id where e.incident_id=iid and e.seq>cur order by e.seq limit least(greatest(coalesce((p_input->>'limit')::integer,50),1),100)
   ) e;
  elsif p_action='grant' then
   if c.stop_requested_at is not null or i.deletion_requested_at is not null then raise exception 'cast_stopped'; end if;
   phone := p_input->>'recipient_phone';
   if not exists(select 1 from jsonb_array_elements(c.preset_snapshot->'recipients') recipient where recipient->>'phone'=phone) then raise exception 'recipient_not_in_snapshot'; end if;
   if coalesce((p_input->>'include_video')::boolean,false) and not (c.consent->>'video')::boolean or coalesce((p_input->>'include_location')::boolean,false) and not (c.consent->>'location')::boolean then raise exception 'scope_not_consented'; end if;
   if (select count(*) from public.cast_viewer_grants where incident_id=iid)>=100 then raise exception 'grant_limit'; end if;
   gid := (p_input->>'grant_id')::uuid;
   insert into public.cast_viewer_grants(id,incident_id,owner_id,recipient_phone,include_video,include_location,expires_at)
   values(gid,iid,u,phone,coalesce((p_input->>'include_video')::boolean,false),coalesce((p_input->>'include_location')::boolean,false),(p_input->>'expires_at')::timestamptz) returning * into g;
   insert into mycamcast_private.cast_tokens values(gid,p_input->>'token_hash');
   result := to_jsonb(g);
  elsif p_action in ('revoke','block') then
   update public.cast_viewer_grants set revoked_at=coalesce(revoked_at,now()),blocked_at=case when p_action='block' then coalesce(blocked_at,now()) else blocked_at end where id=(p_input->>'grant_id')::uuid and incident_id=iid returning * into g;
   if not found then raise exception 'grant_unavailable'; end if;
   result := to_jsonb(g);
  elsif p_action='location' then
   if c.stop_requested_at is not null or i.deletion_requested_at is not null then raise exception 'cast_stopped'; end if;
   if not exists(select 1 from public.capture_preferences where owner_id=u and record_location) then raise exception 'record_location_not_authorized'; end if;
   if jsonb_typeof(p_input->'share_with_recipients') is distinct from 'boolean' or ((p_input->>'share_with_recipients')::boolean and not (c.consent->>'location')::boolean) then raise exception 'location_sharing_not_authorized'; end if;
   ts := (p_input->>'device_recorded_at')::timestamptz;
   if ts>clock_timestamp()+interval '30 seconds' or ts<i.device_started_at-interval '24 hours' then raise exception 'invalid_location_timestamp'; end if;
   insert into public.cast_location_samples(id,incident_id,owner_id,device_recorded_at,latitude,longitude,accuracy_m,share_with_recipients)
   values((p_input->>'sample_id')::uuid,iid,u,ts,(p_input->>'latitude')::float8,(p_input->>'longitude')::float8,(p_input->>'accuracy_m')::float8,(p_input->>'share_with_recipients')::boolean);
   result := jsonb_build_object('sample_id',p_input->>'sample_id','accepted',true);
  elsif p_action='moderate' then
   select * into m from public.cast_messages where id=(p_input->>'message_id')::uuid and incident_id=iid for update;
   if not found then raise exception 'message_unavailable'; end if;
   if p_input->>'decision' not in ('approved','rejected','removed') or p_input->>'decision' is null then raise exception 'invalid_decision'; end if;
   if m.moderation='pending' and p_input->>'decision' in ('approved','rejected') or m.moderation='approved' and p_input->>'decision'='removed' then
    if p_input->>'decision'='approved' and not exists(select 1 from public.cast_viewer_grants where id=m.grant_id and revoked_at is null and blocked_at is null and expires_at>clock_timestamp()) then raise exception 'sender_no_longer_authorized'; end if;
    update public.cast_messages set moderation=p_input->>'decision' where id=m.id;
    if p_input->>'decision'<>'rejected' then
     update public.active_casts set event_cursor=event_cursor+1 where incident_id=iid returning event_cursor into cur;
     insert into public.cast_message_events(incident_id,owner_id,seq,message_id,kind) values(iid,u,cur,m.id,p_input->>'decision');
    end if;
   elsif m.moderation<>p_input->>'decision' then raise exception 'invalid_moderation_transition'; end if;
   result := jsonb_build_object('message_id',m.id,'moderation',p_input->>'decision');
  end if;
 else raise exception 'unknown_action';
 end if;
 if req is not null then
  insert into mycamcast_private.cast_requests(owner_id,request_id,action,payload,response) values(u,req,p_action,p_input,result);
 end if;
 return result;
end $$;

create function public.cast_control(p_action text,p_input jsonb default '{}') returns jsonb
language sql security invoker set search_path = '' as $$ select mycamcast_private.cast_control(p_action,p_input); $$;
revoke all on function mycamcast_private.core_presets(),mycamcast_private.cast_control(text,jsonb),public.cast_control(text,jsonb) from public,anon,authenticated;
grant execute on function mycamcast_private.cast_control(text,jsonb),public.cast_control(text,jsonb) to authenticated;

-- Only the Edge service role can call this. Every call rechecks grant and incident.
create function public.cast_viewer(p_token_hash text,p_action text,p_input jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare g public.cast_viewer_grants; c public.active_casts; m public.cast_messages; result jsonb; sample public.cast_location_samples;
begin
 if p_input is null or jsonb_typeof(p_input)<>'object' or octet_length(p_input::text)>4096 then raise exception 'invalid_input'; end if;
 select v.* into g from public.cast_viewer_grants v join mycamcast_private.cast_tokens t on t.grant_id=v.id where t.token_hash=p_token_hash;
 if not found or g.revoked_at is not null or g.blocked_at is not null or g.expires_at<=clock_timestamp() then raise exception 'access_denied' using errcode='42501'; end if;
 -- Match owner lock order (cast then grant); serializes message caps and stop.
 select * into c from public.active_casts where incident_id=g.incident_id for no key update;
 select * into g from public.cast_viewer_grants vg where vg.id=g.id for update;
 if g.revoked_at is not null or g.blocked_at is not null or g.expires_at<=clock_timestamp() then raise exception 'access_denied' using errcode='42501'; end if;
 if c.stop_requested_at is not null or exists(select 1 from public.incidents where id=g.incident_id and deletion_requested_at is not null) then raise exception 'access_denied' using errcode='42501'; end if;
 if p_action='heartbeat' then
  insert into mycamcast_private.cast_presence values(g.id,clock_timestamp()) on conflict(grant_id) do update set last_seen_at=excluded.last_seen_at where cast_presence.last_seen_at<clock_timestamp()-interval '10 seconds';
  result := jsonb_build_object('expires_at',g.expires_at,'heartbeat_seconds',15,'identity_verified',false,'video_state',case when g.include_video then 'ingest_transcode_distribution_not_configured' else 'not_authorized' end,'location_authorized',g.include_location);
 elsif p_action='location' then
  if not g.include_location then raise exception 'scope_denied' using errcode='42501'; end if;
  select * into sample from public.cast_location_samples where incident_id=g.incident_id and share_with_recipients order by device_recorded_at desc,id limit 1;
  result := case when sample.id is null then jsonb_build_object('state','no_shared_fix') else jsonb_build_object('state','approximate_fix','latitude',sample.latitude,'longitude',sample.longitude,'accuracy_m',sample.accuracy_m,'device_recorded_at',sample.device_recorded_at,'received_at',sample.received_at,'age_seconds',greatest(0,extract(epoch from clock_timestamp()-sample.device_recorded_at)),'stale',sample.device_recorded_at<clock_timestamp()-interval '60 seconds') end;
 elsif p_action='message' then
  select * into m from public.cast_messages where id=(p_input->>'message_id')::uuid;
  if found then
   if m.grant_id<>g.id or m.body is distinct from btrim(p_input->>'body') then raise exception 'idempotency_conflict'; end if;
   return jsonb_build_object('message_id',m.id,'moderation',m.moderation);
  end if;
  if (select count(*) from public.cast_messages where grant_id=g.id and created_at>clock_timestamp()-interval '1 minute')>=5 or (select count(*) from public.cast_messages where incident_id=g.incident_id)>=10000 then raise exception 'message_rate_limit'; end if;
  insert into public.cast_messages(id,incident_id,owner_id,grant_id,body) values((p_input->>'message_id')::uuid,g.incident_id,g.owner_id,g.id,btrim(p_input->>'body')) returning * into m;
  result := jsonb_build_object('message_id',m.id,'moderation','pending');
 else raise exception 'unknown_action';
 end if;
 -- Bound audit writes to once per grant/action/10 seconds; no tokens, IPs or URLs.
 if not exists(select 1 from public.cast_access_audit where grant_id=g.id and action=p_action and occurred_at>clock_timestamp()-interval '10 seconds') then
  insert into public.cast_access_audit(grant_id,incident_id,owner_id,action) values(g.id,g.incident_id,g.owner_id,p_action);
 end if;
 return result;
end $$;
revoke all on function public.cast_viewer(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.cast_viewer(text,text,jsonb) to service_role;
