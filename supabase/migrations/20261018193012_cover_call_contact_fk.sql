-- Cover the complete contact/connection foreign key, including deletes/checks.
create index calls_contact_connection on public.calls(workspace_id,contact_id,hubspot_connection_id);
drop index public.calls_contact;
alter table private.sync_jobs add constraint lease_state_consistent check (
 (state='leased' and lease_token is not null and lease_until is not null) or
 (state<>'leased' and lease_token is null and lease_until is null)
);

create or replace function public.claim_sync_batch(w uuid,conn uuid)
returns setof private.sync_jobs language plpgsql security invoker set search_path='' as $$
declare cfg private.sync_settings; eligible_count integer; oldest timestamptz;
begin
 -- Serialize each connection: rate gates and batch eligibility are consistent.
 select * into cfg from private.sync_settings where workspace_id=w and connection_id=conn for update skip locked;
 if not found or not cfg.enabled or cfg.blocked_until>now() then return; end if;
 if not exists(select 1 from public.provider_connections where workspace_id=w and id=conn
 and provider='hubspot' and connected) then return; end if;
 -- A worker may have sent a create before losing its lease. Never blindly recreate.
 update private.sync_jobs set state=case when activity_id is null then 'ambiguous' when attempts>=8 then 'failed' else 'ready' end,
 lease_token=null,lease_until=null,last_error_code='lease_expired'
 where workspace_id=w and connection_id=conn and state='leased' and lease_until<=now();
 if exists(select 1 from private.sync_jobs where workspace_id=w and connection_id=conn and state='leased') then return; end if;
 select count(*),min(ready_since) into eligible_count,oldest from private.sync_jobs
 where workspace_id=w and connection_id=conn and state='ready' and available_at<=now();
 if eligible_count=0 or (eligible_count<cfg.batch_size and oldest>now()-make_interval(secs=>cfg.max_wait_seconds)) then return; end if;
 return query with selected as (
 select id from private.sync_jobs where workspace_id=w and connection_id=conn
 and state='ready' and available_at<=now() order by ready_since,id limit cfg.batch_size for update skip locked
 ) update private.sync_jobs j set state='leased',lease_token=gen_random_uuid(),lease_until=now()+interval '90 seconds',
 claimed_version=desired_version,attempts=attempts+1
 from selected where j.id=selected.id returning j.*;
end $$;


create or replace function public.finish_sync_job(job uuid,token uuid,result text,remote_id text default null,
 retry_after_seconds integer default 30) returns boolean
language plpgsql security invoker set search_path='' as $$
declare j private.sync_jobs;
begin
 if result is null or token is null or retry_after_seconds is null or result not in ('ok','retry','ambiguous','failed') or retry_after_seconds not between 1 and 86400 then
 raise exception 'invalid_result' using errcode='22023'; end if;
 select * into j from private.sync_jobs where id=job;
 if not found then return false; end if;
 -- Use the same settings-before-jobs lock order as claim_sync_batch.
 perform 1 from private.sync_settings where workspace_id=j.workspace_id and connection_id=j.connection_id for update;
 select * into j from private.sync_jobs where id=job for update;
 if not found or j.state<>'leased' or j.lease_token<>token or j.lease_until<=now() then return false; end if;
 if result='ok' and coalesce(j.activity_id,remote_id) is null then raise exception 'missing_activity_id'; end if;
 if j.activity_id is not null and remote_id is not null and j.activity_id<>remote_id then raise exception 'activity_mapping_conflict'; end if;
 update private.sync_jobs set
 activity_id=coalesce(j.activity_id,remote_id),
 state=case when result='ok' then case when desired_version>claimed_version then 'ready' else 'sent' end
 when result='ambiguous' then 'ambiguous' when result='failed' or attempts>=8 then 'failed' else 'ready' end,
 ready_since=case when result='ok' then now() else ready_since end,
 available_at=now()+make_interval(secs=>case when result='retry' then
 greatest(retry_after_seconds,least(3600,power(2,least(j.attempts,10))::integer)) else 0 end),
 lease_token=null,lease_until=null,last_error_code=case when result='ok' then null else result end
 where id=job;
 if result='retry' then update private.sync_settings set blocked_until=greatest(blocked_until,now()+make_interval(secs=>retry_after_seconds))
 where workspace_id=j.workspace_id and connection_id=j.connection_id; end if;
 return true;
end $$;

