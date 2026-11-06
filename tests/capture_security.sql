-- Development verification only: synthetic Storage metadata, no actual media upload.
-- All fixtures roll back. Run through the development SQL inspection tool.
begin;
insert into auth.users(id,email,raw_user_meta_data) values
 ('ca000000-0000-4000-8000-000000000001','capture-a@example.invalid','{"username":"capture_test_a"}'),
 ('ca000000-0000-4000-8000-000000000002','capture-b@example.invalid','{"username":"capture_test_b"}');
-- Emulate Storage API deletion only for rolled-back synthetic metadata.
select set_config('storage.allow_delete_query','true',true);
set local role authenticated;
select set_config('request.jwt.claim.sub','ca000000-0000-4000-8000-000000000001',true);
insert into public.incidents(id,device_started_at) values ('cb000000-0000-4000-8000-000000000001','2026-10-31T00:00:00Z');
select public.reserve_segment('cb000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000001',0,100,'video/mp4','2026-10-31T00:00:00Z','2026-10-31T00:00:01Z');
-- Identical retry is idempotent.
select public.reserve_segment('cb000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000001',0,100,'video/mp4','2026-10-31T00:00:00Z','2026-10-31T00:00:01Z');
do $$
begin
 if (select reserved_bytes from public.storage_usage) <> 100 then raise exception 'Retry consumed quota twice'; end if;
 begin
   update public.incident_segments set server_received_at = now();
   raise exception 'Receipt forgery succeeded';
 exception when insufficient_privilege then null;
 end;
 begin
   update public.storage_accounts set allowance_bytes = 999999999;
   raise exception 'Quota forgery succeeded';
 exception when insufficient_privilege then null;
 end;
 begin
   insert into storage.objects(bucket_id,name,metadata) values ('incident-media','ca000000-0000-4000-8000-000000000001/cb000000-0000-4000-8000-000000000001/cc000000-0000-4000-8000-000000000001','{"size":101,"mimetype":"video/mp4"}');
   raise exception 'Size mismatch accepted';
 exception when raise_exception then
   if sqlerrm <> 'Media does not match reserved size/type' then raise; end if;
 end;
end $$;
insert into storage.objects(bucket_id,name,metadata) values ('incident-media','ca000000-0000-4000-8000-000000000001/cb000000-0000-4000-8000-000000000001/cc000000-0000-4000-8000-000000000001','{"size":100,"mimetype":"video/mp4"}');
-- A closed capture missing index 1 must stay partial.
select public.close_capture('cb000000-0000-4000-8000-000000000001','2026-10-31T00:00:02Z',2,'stopped');
do $$
begin
 if (select upload_state from public.incident_upload_status) <> 'partially_uploaded' then raise exception 'Missing segment marked complete'; end if;
 if (select confirmed_bytes from public.storage_usage) <> 100 then raise exception 'Receipt not recorded'; end if;
 delete from storage.objects where bucket_id = 'incident-media';
 if not exists (select 1 from storage.objects where bucket_id = 'incident-media') then raise exception 'Original deletion permitted without confirmation'; end if;
end $$;
select set_config('request.jwt.claim.sub','ca000000-0000-4000-8000-000000000002',true);
do $$
begin
 if exists (select 1 from public.incidents) or exists (select 1 from public.incident_segments) or exists (select 1 from storage.objects where bucket_id = 'incident-media') then raise exception 'Cross-owner read allowed'; end if;
 begin
   perform public.reserve_segment('cb000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000002',1,100,'video/mp4','2026-10-31T00:00:01Z','2026-10-31T00:00:02Z');
   raise exception 'Cross-owner write allowed';
 exception when raise_exception then
   if sqlerrm <> 'Incident unavailable' then raise; end if;
 end;
end $$;
select set_config('request.jwt.claim.sub','ca000000-0000-4000-8000-000000000001',true);
select public.reserve_segment('cb000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000002',1,100,'video/mp4','2026-10-31T00:00:01Z','2026-10-31T00:00:02Z');
insert into storage.objects(bucket_id,name,metadata) values ('incident-media','ca000000-0000-4000-8000-000000000001/cb000000-0000-4000-8000-000000000001/cc000000-0000-4000-8000-000000000002','{"size":100,"mimetype":"video/mp4"}');
do $$
begin
 if (select upload_state from public.incident_upload_status) <> 'cloud_confirmed' then raise exception 'Complete capture not confirmed'; end if;
end $$;
select public.request_incident_deletion('cb000000-0000-4000-8000-000000000001');
delete from storage.objects where bucket_id = 'incident-media' and name like 'ca000000-0000-4000-8000-000000000001/cb000000-0000-4000-8000-000000000001/%';
select public.complete_incident_deletion('cb000000-0000-4000-8000-000000000001');
do $$
begin
 if exists (select 1 from public.incidents) then raise exception 'Incident cleanup failed'; end if;
 if (select reserved_bytes from public.storage_usage) <> 0 then raise exception 'Quota not released'; end if;
end $$;
set local role anon;
do $$
begin
 begin
   perform 1 from public.incidents;
   raise exception 'Anonymous access allowed';
 exception when insufficient_privilege then null;
 end;
end $$;
rollback;
