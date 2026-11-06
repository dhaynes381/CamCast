-- Private, recoverable capture foundation. All provider integrations remain unavailable.
create schema if not exists mycamcast_private;
revoke all on schema mycamcast_private from public;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text check (length(display_name) <= 160),
  created_at timestamptz not null default now()
);
create table public.capture_preferences (
  owner_id uuid primary key references auth.users(id) on delete cascade,
  capture_mode text not null default 'private' check (capture_mode in ('private','broadcast')),
  notify_contacts boolean not null default false,
  record_location boolean not null default false,
  share_location boolean not null default false,
  notify_partners boolean not null default false,
  notify_agencies boolean not null default false,
  selected_destinations text[] not null default '{}',
  check (not share_location or record_location)
);
create table public.storage_plans (
  code text primary key,
  name text not null,
  allowance_bytes bigint not null check (allowance_bytes >= 0),
  price_amount numeric check (price_amount >= 0),
  currency text,
  available boolean not null default false
);
insert into public.storage_plans(code,name,allowance_bytes,available)
values ('free','Free',500000000,true);
create table public.storage_accounts (
  owner_id uuid primary key references auth.users(id) on delete cascade,
  allowance_bytes bigint not null default 500000000 check (allowance_bytes >= 0),
  plan_code text not null default 'free' references public.storage_plans(code)
);
create table public.incidents (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  device_started_at timestamptz not null,
  device_ended_at timestamptz,
  server_created_at timestamptz not null default now(),
  server_closed_at timestamptz,
  device_timezone text not null default 'UTC',
  is_test boolean not null default false,
  title text check (length(title) <= 300),
  notes text check (length(notes) <= 20000),
  expected_segment_count integer check (expected_segment_count between 1 and 100000),
  termination text check (termination in ('stopped','interrupted')),
  deletion_requested_at timestamptz,
  unique (id,owner_id),
  check (device_ended_at is null or device_ended_at >= device_started_at)
);
create index incidents_owner_started on public.incidents(owner_id,device_started_at desc);
create table public.incident_segments (
  id uuid primary key,
  incident_id uuid not null,
  owner_id uuid not null,
  segment_index integer not null check (segment_index between 0 and 99999),
  byte_size bigint not null check (byte_size between 1 and 20971520),
  content_type text not null check (content_type in ('video/mp4','video/quicktime','video/webm')),
  device_started_at timestamptz not null,
  device_ended_at timestamptz not null,
  -- Client declaration only; no claim of server-side checksum verification.
  client_sha256 text check (client_sha256 ~ '^[a-f0-9]{64}$'),
  object_path text not null unique,
  reserved_at timestamptz not null default now(),
  server_received_at timestamptz,
  unique (incident_id,segment_index),
  foreign key (incident_id,owner_id) references public.incidents(id,owner_id) on delete cascade,
  check (device_ended_at >= device_started_at)
);
create index incident_segments_owner on public.incident_segments(owner_id);
create table public.incident_locations (
  id uuid primary key default gen_random_uuid(),
  incident_id uuid not null,
  owner_id uuid not null default auth.uid(),
  device_recorded_at timestamptz not null,
  server_received_at timestamptz not null default now(),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  accuracy_m double precision check (accuracy_m >= 0 and accuracy_m < 'Infinity'::float8),
  foreign key (incident_id,owner_id) references public.incidents(id,owner_id) on delete cascade
);
create index incident_locations_incident on public.incident_locations(incident_id);
create table public.incident_events (
  id uuid primary key default gen_random_uuid(),
  incident_id uuid not null,
  owner_id uuid not null default auth.uid(),
  source text not null default 'device' check (source in ('device','server')),
  kind text not null check (kind in ('interruption','reconnection','upload_failed','low_storage','permission_denied','capture_resumed','segment_received','segment_removed','capture_closed','deletion_requested')),
  device_at timestamptz,
  server_received_at timestamptz not null default now(),
  details jsonb not null default '{}' check (jsonb_typeof(details) = 'object' and octet_length(details::text) <= 8192),
  foreign key (incident_id,owner_id) references public.incidents(id,owner_id) on delete cascade
);
create index incident_events_incident on public.incident_events(incident_id,server_received_at);
create table public.trusted_contacts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (length(name) between 1 and 160),
  email text check (length(email) <= 320),
  phone text check (length(phone) <= 40),
  notify_on_start boolean not null default true,
  created_at timestamptz not null default now(),
  check (email is not null or phone is not null)
);
create table public.destination_connections (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  platform text not null check (platform in ('youtube','facebook','tiktok','twitch','other')),
  enabled boolean not null default false,
  state text not null default 'unavailable' check (state in ('not_connected','connected','reauthorization_required','ineligible','unavailable')),
  account_label text,
  unique (owner_id,platform)
  -- OAuth tokens must live in a future server-only credential store, never here.
);
create table public.broadcast_sessions (
  id uuid primary key default gen_random_uuid(),
  incident_id uuid not null,
  owner_id uuid not null,
  platform text not null,
  state text not null default 'unavailable' check (state in ('unavailable','connecting','live','disconnected','ended','failed')),
  provider_confirmed_at timestamptz,
  ended_at timestamptz,
  error_code text,
  foreign key (incident_id,owner_id) references public.incidents(id,owner_id) on delete cascade,
  check (state <> 'live' or provider_confirmed_at is not null)
);
create index broadcast_sessions_incident on public.broadcast_sessions(incident_id);
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  incident_id uuid not null,
  owner_id uuid not null,
  idempotency_key text not null unique,
  channel text not null check (channel in ('email','sms','push','partner')),
  recipient_label text not null,
  state text not null default 'queued' check (state in ('queued','sent','delivered','failed')),
  queued_at timestamptz not null default now(),
  sent_at timestamptz,
  delivered_at timestamptz,
  error_code text,
  foreign key (incident_id,owner_id) references public.incidents(id,owner_id) on delete cascade,
  check (state not in ('sent','delivered') or sent_at is not null),
  check (state <> 'delivered' or delivered_at is not null)
);
create index notifications_incident on public.notifications(incident_id);
create table public.partner_organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  website text,
  organization_type text not null check (organization_type in ('civil_rights','legal_aid','oversight','agency','other')),
  service_area text,
  approved boolean not null default false,
  verified_notification_channel boolean not null default false
);
create table public.partner_interest (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  organization_name text not null,
  website text,
  contact_name text not null,
  contact_role text not null,
  email text not null,
  phone text,
  mission text not null,
  geographic_service_area text not null,
  desired_participation text[] not null,
  monitoring_availability text not null,
  capacity text not null,
  privacy_access_practices text not null,
  conflicts_of_interest text not null,
  willing_to_test boolean not null,
  submitted_at timestamptz not null default now()
);
create table public.incident_access_grants (
  id uuid primary key default gen_random_uuid(),
  incident_id uuid not null,
  owner_id uuid not null,
  recipient_user_id uuid references auth.users(id) on delete cascade,
  partner_id uuid references public.partner_organizations(id),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  include_location boolean not null default false,
  created_at timestamptz not null default now(),
  foreign key (incident_id,owner_id) references public.incidents(id,owner_id) on delete cascade,
  check (expires_at > created_at)
  -- Future viewer service issues hashed, scoped bearer links. No anonymous access yet.
);
create index incident_access_grants_incident on public.incident_access_grants(incident_id);
create table public.purchases (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  provider text not null,
  provider_transaction_id text not null unique,
  state text not null check (state in ('pending','confirmed','refunded','failed')),
  amount numeric check (amount >= 0),
  currency text,
  created_at timestamptz not null default now()
);
create table public.entitlements (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('export','storage')),
  incident_id uuid,
  purchase_id uuid references public.purchases(id),
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (incident_id,owner_id) references public.incidents(id,owner_id) on delete cascade
);
create table public.usage_events (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  incident_id uuid,
  category text not null check (category in ('storage','processing','playback','distribution','notification','shared_access')),
  quantity numeric not null check (quantity >= 0),
  unit text not null,
  occurred_at timestamptz not null default now(),
  foreign key (incident_id,owner_id) references public.incidents(id,owner_id) on delete cascade
);

-- Explicit grants and RLS: authenticated owners only; provider/receipt/billing records read-only.
do $$
declare t text;
begin
  foreach t in array array['profiles','capture_preferences','storage_plans','storage_accounts','incidents','incident_segments','incident_locations','incident_events','trusted_contacts','destination_connections','broadcast_sessions','notifications','partner_organizations','partner_interest','incident_access_grants','purchases','entitlements','usage_events'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant all on public.%I to service_role', t);
    if t not in ('profiles','storage_plans','partner_organizations') then
      execute format('create policy owner_read on public.%I for select to authenticated using (owner_id = (select auth.uid()))', t);
    end if;
  end loop;
end $$;
create policy profile_owner on public.profiles for all to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy available_plans on public.storage_plans for select to authenticated using (available);
create policy approved_partners on public.partner_organizations for select to authenticated using (approved);
grant insert(id,display_name), update(display_name) on public.profiles to authenticated;
grant insert, update, delete on public.capture_preferences, public.trusted_contacts to authenticated;
create policy preferences_owner on public.capture_preferences for all to authenticated using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy contacts_owner on public.trusted_contacts for all to authenticated using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
grant insert(id,owner_id,device_started_at,device_timezone,is_test,title,notes), update(title,notes) on public.incidents to authenticated;
create policy incident_insert on public.incidents for insert to authenticated with check (owner_id = (select auth.uid()));
create policy incident_edit on public.incidents for update to authenticated using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
grant insert(id,incident_id,owner_id,device_recorded_at,latitude,longitude,accuracy_m) on public.incident_locations to authenticated;
create policy location_insert on public.incident_locations for insert to authenticated with check (owner_id = (select auth.uid()) and exists (select 1 from public.capture_preferences p where p.owner_id = (select auth.uid()) and p.record_location));
grant insert(id,incident_id,owner_id,kind,device_at,details) on public.incident_events to authenticated;
create policy device_event_insert on public.incident_events for insert to authenticated with check (owner_id = (select auth.uid()) and source = 'device' and kind in ('interruption','reconnection','upload_failed','low_storage','permission_denied','capture_resumed'));
grant insert(id,owner_id,platform,enabled), update(enabled), delete on public.destination_connections to authenticated;
create policy destination_insert on public.destination_connections for insert to authenticated with check (owner_id = (select auth.uid()) and state = 'unavailable');
create policy destination_edit on public.destination_connections for update to authenticated using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy destination_delete on public.destination_connections for delete to authenticated using (owner_id = (select auth.uid()));
grant insert(organization_name,website,contact_name,contact_role,email,phone,mission,geographic_service_area,desired_participation,monitoring_availability,capacity,privacy_access_practices,conflicts_of_interest,willing_to_test) on public.partner_interest to authenticated;
create policy interest_insert on public.partner_interest for insert to authenticated with check (owner_id = (select auth.uid()));

-- Definer functions have fixed empty search paths and check auth.uid explicitly.
-- Reservation serializes on the account row; clients cannot raise quotas or forge receipts.
create function public.reserve_segment(p_incident_id uuid, p_segment_id uuid, p_segment_index integer, p_byte_size bigint, p_content_type text, p_started_at timestamptz, p_ended_at timestamptz, p_sha256 text default null)
returns public.incident_segments language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); q bigint; used bigint; s public.incident_segments; i public.incidents;
begin
  if u is null then raise exception 'Authentication required'; end if;
  insert into public.storage_accounts(owner_id) values (u) on conflict do nothing;
  select allowance_bytes into q from public.storage_accounts where owner_id = u for update;
  select * into i from public.incidents where id = p_incident_id and owner_id = u for update;
  if not found or i.deletion_requested_at is not null then raise exception 'Incident unavailable'; end if;
  select * into s from public.incident_segments where id = p_segment_id;
  if found then
    if s.owner_id <> u or s.incident_id <> p_incident_id or s.segment_index <> p_segment_index or s.byte_size <> p_byte_size or s.content_type <> p_content_type or s.device_started_at <> p_started_at or s.device_ended_at <> p_ended_at or s.client_sha256 is distinct from p_sha256 then
      raise exception 'Segment retry must match original manifest';
    end if;
    return s;
  end if;
  if i.expected_segment_count is not null and p_segment_index >= i.expected_segment_count then raise exception 'Segment outside closed capture'; end if;
  select coalesce(sum(byte_size),0) into used from public.incident_segments where owner_id = u;
  if p_byte_size > q - used then raise exception 'Cloud allowance exhausted; retain footage locally'; end if;
  insert into public.incident_segments(id,incident_id,owner_id,segment_index,byte_size,content_type,device_started_at,device_ended_at,client_sha256,object_path)
  values (p_segment_id,p_incident_id,u,p_segment_index,p_byte_size,p_content_type,p_started_at,p_ended_at,p_sha256,u::text || '/' || p_incident_id::text || '/' || p_segment_id::text) returning * into s;
  return s;
end $$;
create function public.close_capture(p_incident_id uuid, p_ended_at timestamptz, p_expected_segment_count integer, p_termination text default 'stopped')
returns void language plpgsql security definer set search_path = '' as $$
declare i public.incidents;
begin
  select * into i from public.incidents where id = p_incident_id and owner_id = auth.uid() for update;
  if not found then raise exception 'Incident unavailable'; end if;
  if i.server_closed_at is not null then
    if i.device_ended_at is distinct from p_ended_at or i.expected_segment_count is distinct from p_expected_segment_count or i.termination is distinct from p_termination then raise exception 'Capture already closed'; end if;
    return;
  end if;
  if p_ended_at is null or p_expected_segment_count is null or p_termination is null then raise exception 'Closure fields required'; end if;
  if exists (select 1 from public.incident_segments where incident_id = i.id and segment_index >= p_expected_segment_count) then raise exception 'Expected count excludes existing segments'; end if;
  update public.incidents set device_ended_at = p_ended_at, expected_segment_count = p_expected_segment_count, termination = p_termination, server_closed_at = now() where id = i.id;
  insert into public.incident_events(incident_id,owner_id,source,kind) values (i.id,i.owner_id,'server','capture_closed');
end $$;
create function public.request_incident_deletion(p_incident_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.incidents set deletion_requested_at = now() where id = p_incident_id and owner_id = auth.uid() and deletion_requested_at is null;
  if found then
    insert into public.incident_events(incident_id,owner_id,source,kind) values (p_incident_id,auth.uid(),'server','deletion_requested');
    update public.incident_access_grants set revoked_at = now() where incident_id = p_incident_id and revoked_at is null;
  end if;
end $$;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('incident-media','incident-media',false,20971520,array['video/mp4','video/quicktime','video/webm']);
create policy capture_media_insert on storage.objects for insert to authenticated
with check (bucket_id = 'incident-media' and exists (
 select 1 from public.incident_segments s join public.incidents i on i.id = s.incident_id
 where s.object_path = name and s.owner_id = (select auth.uid()) and s.server_received_at is null and i.deletion_requested_at is null
));
create policy capture_media_read on storage.objects for select to authenticated
using (bucket_id = 'incident-media' and exists (
 select 1 from public.incident_segments s join public.incidents i on i.id = s.incident_id
 where s.object_path = name and s.owner_id = (select auth.uid()) and s.server_received_at is not null and i.deletion_requested_at is null
));
create policy capture_media_delete on storage.objects for delete to authenticated
using (bucket_id = 'incident-media' and exists (
 select 1 from public.incident_segments s join public.incidents i on i.id = s.incident_id
 where s.object_path = name and s.owner_id = (select auth.uid()) and i.deletion_requested_at is not null
));
-- Storage standard uploads only. Originals cannot be overwritten (no UPDATE policy).
-- Storage metadata size is server-produced; receipt and byte validation are atomic with insertion.
create function mycamcast_private.confirm_media()
returns trigger language plpgsql security definer set search_path = '' as $$
declare s public.incident_segments;
begin
  if new.bucket_id <> 'incident-media' then return new; end if;
  select * into s from public.incident_segments where object_path = new.name for update;
  if not found then raise exception 'Segment must be reserved before uploading'; end if;
  if (new.metadata->>'size')::bigint is distinct from s.byte_size or new.metadata->>'mimetype' is distinct from s.content_type then raise exception 'Media does not match reserved size/type'; end if;
  if s.server_received_at is not null then raise exception 'Original media already confirmed'; end if;
  update public.incident_segments set server_received_at = now() where id = s.id;
  insert into public.incident_events(incident_id,owner_id,source,kind,details) values (s.incident_id,s.owner_id,'server','segment_received',jsonb_build_object('segment_id',s.id,'bytes',s.byte_size));
  return new;
end $$;
create trigger confirm_incident_media after insert on storage.objects for each row execute function mycamcast_private.confirm_media();
create function mycamcast_private.remove_media_receipt()
returns trigger language plpgsql security definer set search_path = '' as $$
declare s public.incident_segments;
begin
  if old.bucket_id <> 'incident-media' then return old; end if;
  select * into s from public.incident_segments where object_path = old.name;
  if found then
    insert into public.incident_events(incident_id,owner_id,source,kind,details) values (s.incident_id,s.owner_id,'server','segment_removed',jsonb_build_object('segment_id',s.id));
    delete from public.incident_segments where id = s.id;
  end if;
  return old;
end $$;
create trigger remove_incident_media_receipt after delete on storage.objects for each row execute function mycamcast_private.remove_media_receipt();

create view public.storage_usage with (security_invoker = true) as
select a.owner_id,a.plan_code,a.allowance_bytes,
  coalesce(sum(s.byte_size) filter (where s.server_received_at is not null),0)::bigint as confirmed_bytes,
  coalesce(sum(s.byte_size),0)::bigint as reserved_bytes,
  greatest(a.allowance_bytes - coalesce(sum(s.byte_size),0),0)::bigint as remaining_bytes
from public.storage_accounts a left join public.incident_segments s on s.owner_id = a.owner_id
group by a.owner_id,a.plan_code,a.allowance_bytes;
create view public.incident_upload_status with (security_invoker = true) as
select i.id as incident_id,i.owner_id,i.expected_segment_count,
 count(s.id)::integer as reserved_segments,
 count(s.server_received_at)::integer as confirmed_segments,
 coalesce(sum(s.byte_size) filter (where s.server_received_at is not null),0)::bigint as confirmed_bytes,
 case when i.deletion_requested_at is not null then 'deletion_requested'
 when i.server_closed_at is null then 'capturing_or_unfinished'
 when count(s.server_received_at) = i.expected_segment_count and i.termination = 'stopped' then 'cloud_confirmed'
 when count(s.server_received_at) = i.expected_segment_count then 'interrupted_cloud_confirmed'
 when count(s.server_received_at) > 0 then 'partially_uploaded'
 else 'pending_upload' end as upload_state
from public.incidents i left join public.incident_segments s on s.incident_id = i.id group by i.id;
revoke all on public.storage_usage,public.incident_upload_status from anon,authenticated;
grant select on public.storage_usage,public.incident_upload_status to authenticated,service_role;
revoke all on function public.reserve_segment(uuid,uuid,integer,bigint,text,timestamptz,timestamptz,text),public.close_capture(uuid,timestamptz,integer,text),public.request_incident_deletion(uuid) from public,anon;
grant execute on function public.reserve_segment(uuid,uuid,integer,bigint,text,timestamptz,timestamptz,text),public.close_capture(uuid,timestamptz,integer,text),public.request_incident_deletion(uuid) to authenticated;
revoke all on all functions in schema mycamcast_private from public,anon,authenticated;

-- Initialize onboarding rows and quota even before the first upload.
create function mycamcast_private.initialize_account()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(id) values (new.id) on conflict do nothing;
  insert into public.capture_preferences(owner_id) values (new.id) on conflict do nothing;
  insert into public.storage_accounts(owner_id) values (new.id) on conflict do nothing;
  return new;
end $$;
revoke all on function mycamcast_private.initialize_account() from public,anon,authenticated;
create trigger initialize_mycamcast_account after insert on auth.users for each row execute function mycamcast_private.initialize_account();
insert into public.profiles(id) select id from auth.users on conflict do nothing;
insert into public.capture_preferences(owner_id) select id from auth.users on conflict do nothing;
insert into public.storage_accounts(owner_id) select id from auth.users on conflict do nothing;

-- Explicit cancellation releases abandoned reservations without deleting any uploaded media.
create function public.release_pending_segment(p_segment_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare s public.incident_segments;
begin
  select * into s from public.incident_segments where id = p_segment_id and owner_id = auth.uid() for update;
  if not found then return; end if;
  if s.server_received_at is not null or exists (select 1 from storage.objects where bucket_id = 'incident-media' and name = s.object_path) then raise exception 'Cannot release uploaded media'; end if;
  delete from public.incident_segments where id = s.id;
end $$;
-- Call only after deleting actual objects with the Storage API (never SQL-delete objects).
create function public.complete_incident_deletion(p_incident_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare i public.incidents;
begin
  select * into i from public.incidents where id = p_incident_id and owner_id = auth.uid() for update;
  if not found then return; end if;
  if i.deletion_requested_at is null then raise exception 'Deletion confirmation required'; end if;
  if exists (select 1 from storage.objects where bucket_id = 'incident-media' and name like i.owner_id::text || '/' || i.id::text || '/%') then raise exception 'Delete media using Storage API first'; end if;
  delete from public.incidents where id = i.id;
end $$;
revoke all on function public.release_pending_segment(uuid),public.complete_incident_deletion(uuid) from public,anon;
grant execute on function public.release_pending_segment(uuid),public.complete_incident_deletion(uuid) to authenticated;
