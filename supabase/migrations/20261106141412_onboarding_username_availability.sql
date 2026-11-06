-- Anonymous signup may learn only whether a public handle can be requested.
-- No email, user ID, confirmation status, profile fields or account writes.
create function public.username_available(p_username text)
returns boolean language sql stable security definer set search_path = '' as $$
 select mycamcast_private.username_allowed(lower(btrim(p_username)))
   and not exists (
     select 1 from public.profiles where username=lower(btrim(p_username))
   )
$$;
revoke all on function public.username_available(text) from public,anon,authenticated;
grant execute on function public.username_available(text) to anon,authenticated;
comment on function public.username_available(text) is
 'Advisory signup check only. A true result does not reserve a handle; the unique constraint arbitrates concurrent signups.';
