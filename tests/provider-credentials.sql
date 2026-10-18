
begin;
insert into auth.users(id,aud,role,email) values
('61000000-0000-0000-0000-000000000001','authenticated','authenticated','provider-admin@example.invalid'),
('61000000-0000-0000-0000-000000000002','authenticated','authenticated','provider-rep@example.invalid'),
('61000000-0000-0000-0000-000000000003','authenticated','authenticated','other-admin@example.invalid');
insert into public.workspaces(id,name) values
('62000000-0000-0000-0000-000000000001','Synthetic provider A'),
('62000000-0000-0000-0000-000000000002','Synthetic provider B');
insert into public.workspace_members(workspace_id,user_id,role,enabled) values
('62000000-0000-0000-0000-000000000001','61000000-0000-0000-0000-000000000001','admin',true),
('62000000-0000-0000-0000-000000000001','61000000-0000-0000-0000-000000000002','rep',true),
('62000000-0000-0000-0000-000000000002','61000000-0000-0000-0000-000000000003','admin',true);
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"61000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
do $$ begin
 begin
 perform public.stage_provider_credentials('62000000-0000-0000-0000-000000000001','hubspot','123',
 '{"access_token":"synthetic-private-token-1"}',0);
 raise exception 'rep stored secrets'; exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claims','{"sub":"61000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
do $$ declare result jsonb; begin
 result:=public.stage_provider_credentials('62000000-0000-0000-0000-000000000001','hubspot','123',
 '{"access_token":"synthetic-private-token-1"}',0);
 if result ? 'credentials' or result ? 'access_token' then raise exception 'secret returned'; end if;
 if exists(select 1 from public.provider_connections where connected) then raise exception 'staging bypassed validation'; end if;
 begin
 perform public.stage_provider_credentials('62000000-0000-0000-0000-000000000001','hubspot','123',
 '{"access_token":"synthetic-private-token-2"}',0);
 raise exception 'stale rotation'; exception when sqlstate 'PT409' then null; end;
 begin
 perform public.stage_provider_credentials('62000000-0000-0000-0000-000000000001','hubspot','456',
 '{"access_token":"synthetic-private-token-2"}',1);
 raise exception 'account substitution'; exception when sqlstate 'PT409' then null; end;
 begin
 perform public.stage_provider_credentials('62000000-0000-0000-0000-000000000002','hubspot','456',
 '{"access_token":"synthetic-private-token-2"}',0);
 raise exception 'cross tenant storage'; exception when insufficient_privilege then null; end;
 begin
 perform 1 from vault.decrypted_secrets;
 raise exception 'admin read plaintext'; exception when insufficient_privilege then null; end;
 begin
 perform 1 from private.provider_credentials;
 raise exception 'admin read credential refs'; exception when insufficient_privilege then null; end;
 begin
 perform public.approve_provider_credentials('62000000-0000-0000-0000-000000000001',
 (result->>'connection_id')::uuid,1,'123','61000000-0000-0000-0000-000000000001');
 raise exception 'admin bypassed validation approval'; exception when insufficient_privilege then null; end;
 perform public.stage_provider_credentials('62000000-0000-0000-0000-000000000001','hubspot','123',
 '{"access_token":"synthetic-private-token-2"}',1);
end $$;
reset role;
do $$ begin
 if (select count(*) from private.provider_credentials where workspace_id='62000000-0000-0000-0000-000000000001')<>1 then raise exception 'rotation duplicated credential records'; end if;
 if not exists(select 1 from private.provider_credentials c join vault.decrypted_secrets v on v.id=c.secret_id
 where c.workspace_id='62000000-0000-0000-0000-000000000001'
 and v.decrypted_secret::jsonb->>'access_token'='synthetic-private-token-2'
 and v.secret<>v.decrypted_secret) then raise exception 'encrypted rotation verification failed'; end if;
end $$;
set local role service_role;
do $$ declare c uuid; begin
 select id into c from public.provider_connections where workspace_id='62000000-0000-0000-0000-000000000001' and provider='hubspot';
 if public.approve_provider_credentials('62000000-0000-0000-0000-000000000001',c,1,'123','61000000-0000-0000-0000-000000000001') then raise exception 'stale approval'; end if;
 if public.approve_provider_credentials('62000000-0000-0000-0000-000000000001',c,2,'123','61000000-0000-0000-0000-000000000002') then raise exception 'rep approval'; end if;
 if public.approve_provider_credentials('62000000-0000-0000-0000-000000000001',c,2,'456','61000000-0000-0000-0000-000000000001') then raise exception 'wrong account approval'; end if;
 if not public.approve_provider_credentials('62000000-0000-0000-0000-000000000001',c,2,'123','61000000-0000-0000-0000-000000000001') then raise exception 'valid approval failed'; end if;
end $$;
reset role;
select set_config('request.jwt.claims','{"sub":"61000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select public.disconnect_provider('62000000-0000-0000-0000-000000000001','hubspot',2);
reset role;
do $$ begin
 if exists(select 1 from private.provider_credentials where workspace_id='62000000-0000-0000-0000-000000000001') then raise exception 'credential retained after disconnect'; end if;
 if exists(select 1 from vault.secrets where name like 'calling/62000000-0000-0000-0000-000000000001/%') then raise exception 'vault secret retained'; end if;
 if exists(select 1 from public.provider_connections where workspace_id='62000000-0000-0000-0000-000000000001' and (connected or generation<>3)) then raise exception 'disconnect generation failed'; end if;
 update public.workspace_members set enabled=false where user_id='61000000-0000-0000-0000-000000000001';
end $$;
set local role authenticated;
do $$ begin
 begin
 perform public.stage_provider_credentials('62000000-0000-0000-0000-000000000001','hubspot','123',
 '{"access_token":"synthetic-private-token-3"}',3);
 raise exception 'disabled admin stored secrets'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'PASS: encrypted Vault storage/rotation, admin/rep/disabled/tenant access, redaction, generation fencing, external account binding, validation bypass denial and secret deletion' as result;
rollback;
