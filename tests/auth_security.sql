-- Isolated development only; synthetic fixtures always roll back.
begin;
create function pg_temp.auth_assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Assertion failed: %',label; end if; end $$;
create function pg_temp.auth_denied(stmt text,expected text) returns void language plpgsql as $$
begin
 begin execute stmt; exception when others then
  if sqlerrm like '%'||expected||'%' then return; end if;
  raise exception 'Expected %, got %',expected,sqlerrm;
 end;
 raise exception 'Unexpected success: %',stmt;
end $$;
insert into auth.users(id,email,raw_user_meta_data) values
 ('ea000000-0000-4000-8000-000000000001','auth-a@example.invalid','{"username":"  Auth_Test_A  ","plan_code":"paid","allowance_bytes":9999999999}'),
 ('ea000000-0000-4000-8000-000000000002','auth-b@example.invalid','{"username":"auth_test_b"}');
select pg_temp.auth_assert((select username='auth_test_a' from public.profiles where id='ea000000-0000-4000-8000-000000000001'),'normalization');
select pg_temp.auth_assert((select plan_code='free' and allowance_bytes=500000000 from public.storage_accounts where owner_id='ea000000-0000-4000-8000-000000000001'),'metadata cannot grant paid storage');
select pg_temp.auth_assert((select count(*)=2 from public.capture_preferences where owner_id in ('ea000000-0000-4000-8000-000000000001','ea000000-0000-4000-8000-000000000002')),'account preferences initialized');
select pg_temp.auth_denied($q$insert into auth.users(id,raw_user_meta_data) values ('ea000000-0000-4000-8000-000000000003','{"username":"AUTH_TEST_A"}')$q$,'profiles_username_unique');
select pg_temp.auth_denied($q$insert into auth.users(id,raw_user_meta_data) values ('ea000000-0000-4000-8000-000000000003','{"username":"Admin"}')$q$,'username_invalid_or_reserved');
select pg_temp.auth_denied($q$insert into auth.users(id,raw_user_meta_data) values ('ea000000-0000-4000-8000-000000000003','{"username":"a-b"}')$q$,'username_invalid_or_reserved');
select pg_temp.auth_denied($q$insert into auth.users(id) values ('ea000000-0000-4000-8000-000000000003')$q$,'username_invalid_or_reserved');
select pg_temp.auth_assert(not exists(select 1 from auth.users where id='ea000000-0000-4000-8000-000000000003'),'failed signup is atomic');

-- Emulate a pre-migration profile without touching real accounts.
alter table public.profiles disable trigger protect_username;
update public.profiles set username=null where id='ea000000-0000-4000-8000-000000000002';
alter table public.profiles enable trigger protect_username;
set local role authenticated;
select set_config('request.jwt.claim.sub','ea000000-0000-4000-8000-000000000002',true);
insert into public.incidents(id,device_started_at) values('eb000000-0000-4000-8000-000000000001',now());
select pg_temp.auth_assert((select creator_username is null from public.incidents where id='eb000000-0000-4000-8000-000000000001'),'legacy attribution stays unknown');
select pg_temp.auth_denied($q$select public.claim_username('auth_test_a')$q$,'profiles_username_unique');
select pg_temp.auth_assert(public.claim_username('  Auth_Test_B  ')='auth_test_b','legacy claim');
select pg_temp.auth_assert(public.claim_username('auth_test_b')='auth_test_b','claim retry');
select pg_temp.auth_denied($q$select public.claim_username('new_username')$q$,'username_already_claimed');
insert into public.incidents(id,device_started_at) values('eb000000-0000-4000-8000-000000000002',now());
select pg_temp.auth_assert((select creator_username='auth_test_b' from public.incidents where id='eb000000-0000-4000-8000-000000000002'),'server creator snapshot');
select pg_temp.auth_assert((select creator_username is null from public.incidents where id='eb000000-0000-4000-8000-000000000001'),'claim never relabels old footage');
update public.profiles set display_name='Editable name';
select pg_temp.auth_denied($q$update public.profiles set username='forged'$q$,'permission denied');
select pg_temp.auth_denied($q$update public.incidents set creator_username='forged'$q$,'permission denied');
select pg_temp.auth_denied($q$update public.storage_accounts set allowance_bytes=9999999999$q$,'permission denied');
select pg_temp.auth_assert((select count(*)=1 from public.profiles),'profile RLS');
select pg_temp.auth_assert((select count(*)=0 from public.incidents where owner_id='ea000000-0000-4000-8000-000000000001'),'incident RLS');
reset role;
-- Changing user-editable metadata cannot rename the authoritative profile or footage.
update auth.users set raw_user_meta_data='{"username":"forged"}' where id='ea000000-0000-4000-8000-000000000002';
select pg_temp.auth_assert((select username='auth_test_b' from public.profiles where id='ea000000-0000-4000-8000-000000000002'),'metadata is not authoritative');
select pg_temp.auth_denied($q$update public.incidents set creator_username='forged' where id='eb000000-0000-4000-8000-000000000002'$q$,'creator_username_immutable');
select pg_temp.auth_denied($q$update public.profiles set username='forged' where id='ea000000-0000-4000-8000-000000000002'$q$,'username_immutable');
set local role anon;
select pg_temp.auth_assert(public.username_available('new_test_handle'),'anonymous valid handle');
select pg_temp.auth_assert(not public.username_available(' AUTH_TEST_A '),'anonymous taken handle normalized');
select pg_temp.auth_assert(not public.username_available('Admin'),'reserved handle unavailable');
select pg_temp.auth_assert(not public.username_available(null),'missing handle unavailable');
select pg_temp.auth_assert(not public.username_available('a-b'),'invalid handle unavailable');
select pg_temp.auth_denied($q$select public.claim_username('anonymous_name')$q$,'permission denied');
select pg_temp.auth_denied($q$select * from public.profiles$q$,'permission denied');
reset role;
select set_config('request.jwt.claim.sub','',true);
select pg_temp.auth_denied($q$select public.claim_username('missing_session')$q$,'authentication_required');
rollback;
