-- Development only; every fixture rolls back. Requires postgres inspection role.
begin;
create function pg_temp.assert_true(ok boolean,label text) returns void language plpgsql as $$ begin if ok is distinct from true then raise exception 'Assertion failed: %',label; end if; end $$;
create function pg_temp.denied(stmt text,expected text) returns void language plpgsql as $$ begin
 begin execute stmt; exception when others then
  if sqlerrm like '%'||expected||'%' then return; end if;
  raise exception 'Expected %, got %',expected,sqlerrm;
 end; raise exception 'Unexpected authorization/success: %',stmt;
end $$;
insert into auth.users(id,email,raw_user_meta_data) values
 ('da000000-0000-4000-8000-000000000001','cast-a@example.invalid','{"username":"cast_test_a"}'),
 ('da000000-0000-4000-8000-000000000002','cast-b@example.invalid','{"username":"cast_test_b"}');
set local role authenticated;
select set_config('request.jwt.claim.sub','da000000-0000-4000-8000-000000000001',true);
select pg_temp.assert_true((public.cast_control('presets_get')->>'revision')::int=0,'initial revision');
-- Explicit import restores edited core identities, normalizes numbers and preserves legacy names.
select public.cast_control('presets_import',jsonb_build_object('request_id','df000000-0000-4000-8000-000000000001','base_revision',0,
 'presets',jsonb_set(public.cast_control('presets_get')->'presets','{0,name}','"Legacy renamed core"') || '[{"id":"dd000000-0000-4000-8000-000000000001","name":"Legacy long name","description":"old","artwork":"traffic-stop","socialPlatforms":["x","facebook"],"liveView":true,"sendLocation":true,"recipients":[{"name":"Test","phone":"+1 (415) 555-0123"}]}]'::jsonb,
 'favorite_ids',jsonb_build_array('dd000000-0000-4000-8000-000000000001')));
select pg_temp.assert_true((public.cast_control('presets_get')->>'revision')::int=1,'import revision');
select pg_temp.assert_true(public.cast_control('presets_get')->'presets'->0->>'name'='Traffic Stop','legacy core restored');
select pg_temp.assert_true((public.cast_control('presets_get')->'presets'->4->'recipients'->0->>'phone')='+14155550123','normalized recipient');
select pg_temp.assert_true(public.cast_control('presets_import','{"request_id":"df000000-0000-4000-8000-000000000002","base_revision":0}') ->>'error'='revision_conflict','no overwrite by stale device');
select public.cast_control('presets_save',jsonb_build_object('request_id','df000000-0000-4000-8000-000000000003','base_revision',1,'presets',public.cast_control('presets_get')->'presets','favorite_ids','[]'::jsonb));
select pg_temp.denied($q$select public.cast_control('presets_save',jsonb_build_object('request_id','df000000-0000-4000-8000-000000000004','base_revision',2,'presets',jsonb_set(public.cast_control('presets_get')->'presets','{0,name}','"Changed"'),'favorite_ids','[]'::jsonb))$q$,'core_identity_immutable');
select pg_temp.denied($q$select public.cast_control('presets_save',jsonb_build_object('request_id','df000000-0000-4000-8000-000000000004','base_revision',2,'presets',public.cast_control('presets_get')->'presets','favorite_ids','["traffic-stop","police-encounter","stranger-encounter","altercation","dd000000-0000-4000-8000-000000000001"]'::jsonb))$q$,'invalid_favorites');
select pg_temp.assert_true(not exists(select 1 from public.active_casts),'save does not activate sharing');
select public.cast_control('start','{"request_id":"df000000-0000-4000-8000-000000000010","incident_id":"db000000-0000-4000-8000-000000000001","preset_id":"dd000000-0000-4000-8000-000000000001","preset_revision":2,"device_started_at":"2026-11-03T00:00:00Z","consent":{"video":true,"location":true,"sms":true,"platforms":["x","facebook"]}}');
select public.cast_control('start','{"request_id":"df000000-0000-4000-8000-000000000010","incident_id":"db000000-0000-4000-8000-000000000001","preset_id":"dd000000-0000-4000-8000-000000000001","preset_revision":2,"device_started_at":"2026-11-03T00:00:00Z","consent":{"video":true,"location":true,"sms":true,"platforms":["x","facebook"]}}');
select pg_temp.assert_true((select count(*)=1 from public.active_casts),'idempotent start before segment zero');
select pg_temp.assert_true((select count(*)=1 and bool_and(payload='{"video":true,"location":true}'::jsonb) from public.cast_jobs where kind='sms'),'one combined SMS intent');
select pg_temp.assert_true(not exists(select 1 from public.notifications),'no fake sent or queued notification');
select pg_temp.assert_true((select bool_and(state='unavailable' and provider_confirmed_at is null) from public.broadcast_sessions),'no fake live');
select pg_temp.denied($q$update public.active_casts set consent='{}'$q$,'permission denied');
select pg_temp.denied($q$select public.cast_control('end','{"request_id":"df000000-0000-4000-8000-000000000010","incident_id":"db000000-0000-4000-8000-000000000001"}')$q$,'idempotency_conflict');
-- Independent location authorization, preserving the device timestamp.
select pg_temp.denied($q$select public.cast_control('location','{"request_id":"df000000-0000-4000-8000-000000000020","incident_id":"db000000-0000-4000-8000-000000000001","sample_id":"dc000000-0000-4000-8000-000000000001","device_recorded_at":"2026-11-03T00:00:01Z","latitude":40,"longitude":-70,"accuracy_m":80,"share_with_recipients":true}')$q$,'record_location_not_authorized');
update public.capture_preferences set record_location=true where owner_id=auth.uid();
select public.cast_control('location','{"request_id":"df000000-0000-4000-8000-000000000020","incident_id":"db000000-0000-4000-8000-000000000001","sample_id":"dc000000-0000-4000-8000-000000000001","device_recorded_at":"2026-11-03T00:00:01Z","latitude":40,"longitude":-70,"accuracy_m":80,"share_with_recipients":true}');
select public.cast_control('grant',jsonb_build_object('request_id','df000000-0000-4000-8000-000000000030','incident_id','db000000-0000-4000-8000-000000000001','grant_id','de000000-0000-4000-8000-000000000001','recipient_phone','+14155550123','include_location',true,'include_video',true,'expires_at',now()+interval '1 hour','token_hash',repeat('a',64)));
select public.cast_control('grant',jsonb_build_object('request_id','df000000-0000-4000-8000-000000000031','incident_id','db000000-0000-4000-8000-000000000001','grant_id','de000000-0000-4000-8000-000000000002','recipient_phone','+14155550123','include_location',false,'include_video',true,'expires_at',now()+interval '1 hour','token_hash',repeat('b',64)));
select pg_temp.denied($q$select public.cast_viewer(repeat('a',64),'heartbeat')$q$,'permission denied');
set local role service_role;
select public.cast_viewer(repeat('a',64),'heartbeat');
select public.cast_viewer(repeat('a',64),'heartbeat');
select pg_temp.assert_true(public.cast_viewer(repeat('a',64),'location')->>'stale'='true','old fix stays stale');
select pg_temp.denied($q$select public.cast_viewer(repeat('b',64),'location')$q$,'scope_denied');
select pg_temp.denied($q$select public.cast_viewer(repeat('c',64),'heartbeat')$q$,'access_denied');
select public.cast_viewer(repeat('a',64),'message','{"message_id":"d1000000-0000-4000-8000-000000000001","body":"First"}');
select public.cast_viewer(repeat('a',64),'message','{"message_id":"d1000000-0000-4000-8000-000000000001","body":"First"}');
select public.cast_viewer(repeat('a',64),'message','{"message_id":"d1000000-0000-4000-8000-000000000002","body":"Second"}');
set local role authenticated;
select pg_temp.assert_true(public.cast_control('status','{"incident_id":"db000000-0000-4000-8000-000000000001"}')->>'camcast_viewer_count'='1','deduplicated presence');
select pg_temp.assert_true(public.cast_control('feed','{"incident_id":"db000000-0000-4000-8000-000000000001"}')->'events'='[]'::jsonb,'pending not delivered');
reset role;
update mycamcast_private.cast_presence set last_seen_at=now()-interval '46 seconds';
set local role authenticated;
select pg_temp.assert_true(public.cast_control('status','{"incident_id":"db000000-0000-4000-8000-000000000001"}')->>'camcast_viewer_count'='0','stale presence expires');
-- Approve out of creation order; cursor order follows delivery, never skips late moderation.
select public.cast_control('moderate','{"request_id":"df000000-0000-4000-8000-000000000040","incident_id":"db000000-0000-4000-8000-000000000001","message_id":"d1000000-0000-4000-8000-000000000002","decision":"approved"}');
select public.cast_control('moderate','{"request_id":"df000000-0000-4000-8000-000000000041","incident_id":"db000000-0000-4000-8000-000000000001","message_id":"d1000000-0000-4000-8000-000000000001","decision":"approved"}');
select pg_temp.assert_true(public.cast_control('feed','{"incident_id":"db000000-0000-4000-8000-000000000001","after":"1","limit":1}')->'events'->0->>'body'='First','late approval replay');
select public.cast_control('moderate','{"request_id":"df000000-0000-4000-8000-000000000042","incident_id":"db000000-0000-4000-8000-000000000001","message_id":"d1000000-0000-4000-8000-000000000001","decision":"removed"}');
select pg_temp.assert_true(public.cast_control('feed','{"incident_id":"db000000-0000-4000-8000-000000000001","after":"2"}')->'events'->0->>'kind'='removed','removal tombstone');
select public.cast_control('revoke','{"request_id":"df000000-0000-4000-8000-000000000050","incident_id":"db000000-0000-4000-8000-000000000001","grant_id":"de000000-0000-4000-8000-000000000001"}');
set local role service_role;
select pg_temp.denied($q$select public.cast_viewer(repeat('a',64),'location')$q$,'access_denied');
update public.cast_viewer_grants set expires_at=created_at+interval '1 microsecond' where id='de000000-0000-4000-8000-000000000002';
select pg_temp.denied($q$select public.cast_viewer(repeat('b',64),'heartbeat')$q$,'access_denied');
-- Simulate trusted provider confirmation, then failed end; end must retain live evidence.
update public.broadcast_sessions set state='live',provider_confirmed_at=now() where platform='x';
set local role authenticated;
select public.cast_control('end','{"request_id":"df000000-0000-4000-8000-000000000060","incident_id":"db000000-0000-4000-8000-000000000001"}');
select public.cast_control('end','{"request_id":"df000000-0000-4000-8000-000000000060","incident_id":"db000000-0000-4000-8000-000000000001"}');
select pg_temp.assert_true((select state='live' and ended_at is null from public.broadcast_sessions where platform='x'),'unconfirmed end may still be live');
select pg_temp.assert_true((select count(*)=2 from public.cast_jobs where kind='broadcast_end'),'deduplicated end intents');
-- End control neither closes native capture nor blocks final queued uploads.
select public.close_capture('db000000-0000-4000-8000-000000000001','2026-11-03T00:00:10Z',1,'stopped');
select public.reserve_segment('db000000-0000-4000-8000-000000000001','d2000000-0000-4000-8000-000000000001',0,100,'video/mp4','2026-11-03T00:00:00Z','2026-11-03T00:00:10Z');
-- A separate session without sharing consent cannot share location despite device collection.
select public.cast_control('start','{"request_id":"df000000-0000-4000-8000-000000000070","incident_id":"db000000-0000-4000-8000-000000000002","preset_id":"traffic-stop","preset_revision":2,"device_started_at":"2026-11-03T00:00:00Z","consent":{"video":false,"location":false,"sms":false,"platforms":[]}}');
select pg_temp.denied($q$select public.cast_control('location','{"request_id":"df000000-0000-4000-8000-000000000071","incident_id":"db000000-0000-4000-8000-000000000002","sample_id":"dc000000-0000-4000-8000-000000000003","device_recorded_at":"2026-11-03T00:00:01Z","latitude":40,"longitude":-70,"accuracy_m":80,"share_with_recipients":true}')$q$,'location_sharing_not_authorized');
select set_config('request.jwt.claim.sub','da000000-0000-4000-8000-000000000002',true);
select pg_temp.assert_true(not exists(select 1 from public.active_casts),'cross owner read denied');
select pg_temp.denied($q$select public.cast_control('status','{"incident_id":"db000000-0000-4000-8000-000000000001"}')$q$,'cast_unavailable');
insert into public.destination_connections(platform,enabled) values('x',true);
select pg_temp.denied($q$update public.destination_connections set state='connected'$q$,'permission denied');
set local role anon;
select pg_temp.denied($q$select * from public.cast_viewer_grants$q$,'permission denied');
select pg_temp.denied($q$select public.cast_control('presets_get')$q$,'permission denied');
select pg_temp.denied($q$select public.cast_viewer(repeat('a',64),'heartbeat')$q$,'permission denied');
reset role;
rollback;
