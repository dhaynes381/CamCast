-- Authoritative account handles; UUIDs and existing RLS remain the ownership boundary.
alter table public.profiles add column username text;
alter table public.incidents add column creator_username text;

create function mycamcast_private.username_allowed(value text)
returns boolean language sql immutable set search_path = '' as $$
 select coalesce(value ~ '^[a-z][a-z0-9_]{2,23}$' and value not in
 ('admin','administrator','camcast','camcaster','mycamcast','mycamcaster',
  'support','help','system','moderator','official','root','supabase','draftbit'), false)
$$;
revoke all on function mycamcast_private.username_allowed(text) from public,anon,authenticated;
-- Pure validation is also evaluated by the CHECK constraint on owner profile edits.
grant execute on function mycamcast_private.username_allowed(text) to authenticated;

-- Invalid, reserved or ambiguous legacy metadata stays unclaimed. Never invent a name.
with candidates as (
 select id, lower(btrim(raw_user_meta_data->>'username')) as username from auth.users
), unique_candidates as (
 select username from candidates where mycamcast_private.username_allowed(username)
 group by username having count(*) = 1
)
update public.profiles p set username=c.username
from candidates c join unique_candidates u using(username) where p.id=c.id;

alter table public.profiles add constraint profiles_username_valid
 check (username is null or mycamcast_private.username_allowed(username));
alter table public.profiles add constraint profiles_username_unique unique(username);

-- No username column write grants: the signup trigger and one-time claim own writes.
create function mycamcast_private.protect_username()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
 if old.username is not null and new.username is distinct from old.username then
  raise exception 'username_immutable' using errcode='23514';
 end if;
 return new;
end $$;
revoke all on function mycamcast_private.protect_username() from public,anon,authenticated;
create trigger protect_username before update of username on public.profiles
 for each row execute function mycamcast_private.protect_username();

create or replace function mycamcast_private.initialize_account()
returns trigger language plpgsql security definer set search_path = '' as $$
declare chosen text := lower(btrim(new.raw_user_meta_data->>'username'));
begin
 if not mycamcast_private.username_allowed(chosen) then
  raise exception 'username_invalid_or_reserved' using errcode='23514';
 end if;
 insert into public.profiles(id,username) values(new.id,chosen);
 insert into public.capture_preferences(owner_id) values(new.id);
 insert into public.storage_accounts(owner_id) values(new.id);
 return new;
end $$;
revoke all on function mycamcast_private.initialize_account() from public,anon,authenticated;

-- SECURITY DEFINER is needed only to set the caller's protected column. No owner ID
-- parameter, no paid-plan writes, row lock for retries, unique constraint for races.
create function public.claim_username(p_username text)
returns text language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); chosen text := lower(btrim(p_username)); prior text;
begin
 if u is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if not mycamcast_private.username_allowed(chosen) then
  raise exception 'username_invalid_or_reserved' using errcode='23514';
 end if;
 select username into prior from public.profiles where id=u for update;
 if not found then raise exception 'account_not_initialized'; end if;
 if prior=chosen then return prior; end if;
 if prior is not null then raise exception 'username_already_claimed' using errcode='23514'; end if;
 update public.profiles set username=chosen where id=u;
 return chosen;
end $$;
revoke all on function public.claim_username(text) from public,anon,authenticated;
grant execute on function public.claim_username(text) to authenticated;

create function mycamcast_private.snapshot_creator_username()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
 if tg_op='INSERT' then
  -- Always derive from the authoritative owner, including service-side inserts.
  select username into new.creator_username from public.profiles where id=new.owner_id;
 elsif new.creator_username is distinct from old.creator_username then
  raise exception 'creator_username_immutable' using errcode='23514';
 end if;
 return new;
end $$;
revoke all on function mycamcast_private.snapshot_creator_username() from public,anon,authenticated;
create trigger snapshot_creator_username before insert or update on public.incidents
 for each row execute function mycamcast_private.snapshot_creator_username();
-- Existing incidents keep NULL: current metadata cannot establish past attribution.
