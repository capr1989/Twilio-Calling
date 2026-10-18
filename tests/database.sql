
begin;
insert into auth.users(id,aud,role,email) values
 ('10000000-0000-0000-0000-000000000001','authenticated','authenticated','admin-a@example.invalid'),
 ('10000000-0000-0000-0000-000000000002','authenticated','authenticated','rep-a@example.invalid'),
 ('10000000-0000-0000-0000-000000000003','authenticated','authenticated','admin-b@example.invalid');
insert into public.workspaces(id,name) values
 ('20000000-0000-0000-0000-000000000001','Synthetic A'),('20000000-0000-0000-0000-000000000002','Synthetic B');
insert into public.workspace_members(workspace_id,user_id,role,enabled) values
 ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','admin',true),
 ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','rep',true),
 ('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000003','admin',true);
insert into public.provider_connections(workspace_id,id,provider,external_account_id,connected) values
 ('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001','hubspot','synthetic-portal-a',true),
 ('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002','twilio','synthetic-account-a',true),
 ('20000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000003','hubspot','synthetic-portal-b',true);
insert into private.sync_settings(workspace_id,connection_id,enabled,batch_size,max_wait_seconds)
 values('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001',true,2,900);
insert into public.contacts(workspace_id,id,connection_id,hubspot_contact_id) values
 ('20000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001','synthetic-contact-a'),
 ('20000000-0000-0000-0000-000000000002','40000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000003','synthetic-contact-b');
insert into public.calls(workspace_id,id,rep_user_id,contact_id,hubspot_connection_id,direction) values
 ('20000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','40000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001','outbound'),
 ('20000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001','inbound');
insert into private.call_legs(workspace_id,connection_id,provider_call_sid,call_id,authoritative) values
 ('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002','synthetic-parent','50000000-0000-0000-0000-000000000001',false),
 ('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002','synthetic-child','50000000-0000-0000-0000-000000000001',true);
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
do $$ begin
 if (select count(*) from public.workspaces)<>1 then raise exception 'tenant leak'; end if;
 if (select count(*) from public.contacts)<>1 then raise exception 'contact tenant leak'; end if;
 if (select count(*) from public.calls)<>1 then raise exception 'rep can see another rep call'; end if;
 if (select count(*) from public.workspace_members)<>1 then raise exception 'rep can enumerate peers'; end if;
 begin
  insert into public.workspaces(name) values('unauthorized');
  raise exception 'direct writes allowed';
 exception when insufficient_privilege then null; end;
 begin
  perform public.set_member('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','admin',true);
  raise exception 'rep escalation allowed';
 exception when insufficient_privilege then null; end;
 begin
  perform public.claim_sync_batch('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001');
  raise exception 'rep can claim';
 exception when insufficient_privilege then null; end;
 perform public.edit_call('20000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001',1,'Synthetic note','follow_up');
 begin
  perform public.edit_call('20000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001',1,'stale','connected');
  raise exception 'stale write accepted';
 exception when serialization_failure then null; end;
 begin
  perform public.edit_call('20000000-0000-0000-0000-000000000002','50000000-0000-0000-0000-000000000001',2,'wrong workspace',null);
  raise exception 'cross workspace edit accepted';
 exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claims','{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
do $$ begin
 if (select count(*) from public.calls)<>2 then raise exception 'admin visibility'; end if;
 begin
  perform public.set_member('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','rep',true);
  raise exception 'removed last admin';
 exception when check_violation then null; end;
 perform public.set_member('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','rep',false);
end $$;
select set_config('request.jwt.claims','{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
do $$ begin
 if exists(select 1 from public.workspaces) or exists(select 1 from public.calls) then raise exception 'disabled access'; end if;
 begin
  perform public.edit_call('20000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001',2,'disabled',null);
  raise exception 'disabled edit'; exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
 if (select count(*) from private.sync_jobs)<>1 then raise exception 'missing transactional outbox'; end if;
 begin
  update public.calls set contact_id='40000000-0000-0000-0000-000000000002'
  where id='50000000-0000-0000-0000-000000000001';
  raise exception 'cross workspace FK allowed'; exception when foreign_key_violation then null; end;
end $$;
set local role service_role;
do $$ begin
 perform public.accept_call_event('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002','synthetic-parent',0,'completed',1);
 if (select technical_status from public.calls where id='50000000-0000-0000-0000-000000000001')<>'queued' then raise exception 'parent overrode logical call'; end if;
 perform public.accept_call_event('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002','synthetic-child',2,'in-progress',null);
 if public.accept_call_event('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002','synthetic-child',1,'ringing',null) then raise exception 'out of order accepted'; end if;
 if public.accept_call_event('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002','synthetic-child',2,'in-progress',null) then raise exception 'duplicate accepted'; end if;
 perform public.accept_call_event('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002','synthetic-child',3,'completed',42);
 perform public.accept_call_event('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002','synthetic-child',4,'ringing',null);
 if (select technical_status from public.calls where id='50000000-0000-0000-0000-000000000001')<>'completed' then raise exception 'terminal regression'; end if;
 if exists(select 1 from public.claim_sync_batch('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001')) then raise exception 'flushed before size or time'; end if;
 update private.sync_jobs set ready_since=now()-interval '16 minutes';
end $$;
do $$ declare j private.sync_jobs; begin
 select * into j from public.claim_sync_batch('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001');
 if j.id is null then raise exception 'max wait flush failed'; end if;
 if exists(select 1 from public.claim_sync_batch('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001')) then raise exception 'double claim'; end if;
 begin
  perform public.finish_sync_job(j.id,null,'ok','activity-a',30);
  raise exception 'null token accepted'; exception when invalid_parameter_value then null; end;
 if public.finish_sync_job(j.id,gen_random_uuid(),'ok','activity-a',30) then raise exception 'wrong token accepted'; end if;
 -- Simulate note change while HTTP request for claimed version is in flight.
 update private.sync_jobs set desired_version=desired_version+1 where id=j.id;
 if not public.finish_sync_job(j.id,j.lease_token,'ok','activity-a',30) then raise exception 'completion rejected'; end if;
 if (select state from private.sync_jobs where id=j.id)<>'ready' then raise exception 'new version lost'; end if;
 -- Add independent item so batch size triggers immediately.
 perform private.enqueue_call('20000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000002');
end $$;
do $$ declare jobs private.sync_jobs[]; j private.sync_jobs; n integer:=0; begin
 for j in select * from public.claim_sync_batch('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001') loop
 n:=n+1;
 if j.activity_id is not null then
  perform public.finish_sync_job(j.id,j.lease_token,'ok',j.activity_id,30);
 else
  perform public.finish_sync_job(j.id,j.lease_token,'ambiguous',null,30);
 end if;
 end loop;
 if n<>2 then raise exception 'size flush failed'; end if;
 if (select count(*) from private.sync_jobs where state='sent')<>1 then raise exception 'partial success lost'; end if;
 if (select count(*) from private.sync_jobs where state='ambiguous')<>1 then raise exception 'ambiguous create retried'; end if;
 -- Lost response for create: expired lease is quarantined, never blindly recreated.
 update private.sync_jobs set state='leased',lease_token=gen_random_uuid(),lease_until=now()-interval '1 second'
 where activity_id is null;
 perform public.claim_sync_batch('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001');
 if exists(select 1 from private.sync_jobs where activity_id is null and state<>'ambiguous') then raise exception 'lost response duplicate risk'; end if;
 update public.provider_connections set connected=false where provider='twilio';
 begin
  perform public.accept_call_event('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002','synthetic-child',5,'completed',42);
  raise exception 'disconnected provider accepted'; exception when insufficient_privilege then null; end;
 update public.provider_connections set connected=false where provider='hubspot';
 if exists(select 1 from public.claim_sync_batch('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001')) then raise exception 'disconnected sync claimed'; end if;
end $$;
reset role;
set local role anon;
do $$ begin
 begin
 perform 1 from public.calls;
 raise exception 'anon read'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'PASS: tenant/role/disabled access, edit CAS + atomic queue, scoped FK, last admin, multi-leg and event ordering, flush rules, lease fencing, partial results, ambiguous create and disconnected providers' as result;
rollback;
