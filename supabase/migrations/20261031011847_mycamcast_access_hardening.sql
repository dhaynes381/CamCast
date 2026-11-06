-- Owner SELECT must also work during the confirmed deletion workflow: Storage
-- reads object records before removing files. This never broadens access to others.
alter policy capture_media_read on storage.objects using (
 bucket_id = 'incident-media' and exists (
   select 1 from public.incident_segments s
   where s.object_path = name and s.owner_id = (select auth.uid()) and s.server_received_at is not null
 )
);

-- Keep privileged implementations outside the exposed API schemas.
-- Public invoker wrappers retain the frontend RPC contract; every helper still
-- verifies auth.uid(), and authenticated has EXECUTE only on these five helpers.
alter function public.reserve_segment(uuid,uuid,integer,bigint,text,timestamptz,timestamptz,text) set schema mycamcast_private;
alter function public.close_capture(uuid,timestamptz,integer,text) set schema mycamcast_private;
alter function public.request_incident_deletion(uuid) set schema mycamcast_private;
alter function public.release_pending_segment(uuid) set schema mycamcast_private;
alter function public.complete_incident_deletion(uuid) set schema mycamcast_private;
grant usage on schema mycamcast_private to authenticated;
create function public.reserve_segment(p_incident_id uuid,p_segment_id uuid,p_segment_index integer,p_byte_size bigint,p_content_type text,p_started_at timestamptz,p_ended_at timestamptz,p_sha256 text default null)
returns public.incident_segments language sql security invoker set search_path = '' as $$
 select mycamcast_private.reserve_segment(p_incident_id,p_segment_id,p_segment_index,p_byte_size,p_content_type,p_started_at,p_ended_at,p_sha256);
$$;
create function public.close_capture(p_incident_id uuid,p_ended_at timestamptz,p_expected_segment_count integer,p_termination text default 'stopped')
returns void language sql security invoker set search_path = '' as $$
 select mycamcast_private.close_capture(p_incident_id,p_ended_at,p_expected_segment_count,p_termination);
$$;
create function public.request_incident_deletion(p_incident_id uuid)
returns void language sql security invoker set search_path = '' as $$
 select mycamcast_private.request_incident_deletion(p_incident_id);
$$;
create function public.release_pending_segment(p_segment_id uuid)
returns void language sql security invoker set search_path = '' as $$
 select mycamcast_private.release_pending_segment(p_segment_id);
$$;
create function public.complete_incident_deletion(p_incident_id uuid)
returns void language sql security invoker set search_path = '' as $$
 select mycamcast_private.complete_incident_deletion(p_incident_id);
$$;
revoke all on function public.reserve_segment(uuid,uuid,integer,bigint,text,timestamptz,timestamptz,text),public.close_capture(uuid,timestamptz,integer,text),public.request_incident_deletion(uuid),public.release_pending_segment(uuid),public.complete_incident_deletion(uuid) from public,anon;
grant execute on function public.reserve_segment(uuid,uuid,integer,bigint,text,timestamptz,timestamptz,text),public.close_capture(uuid,timestamptz,integer,text),public.request_incident_deletion(uuid),public.release_pending_segment(uuid),public.complete_incident_deletion(uuid) to authenticated;
