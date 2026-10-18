
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated, service_role;

create table public.workspaces (
 id uuid primary key default gen_random_uuid(),
 name text not null check (length(name) between 1 and 120),
 created_at timestamptz not null default now()
);
create table public.workspace_members (
 workspace_id uuid not null references public.workspaces(id),
 user_id uuid not null references auth.users(id) on delete restrict,
 role text not null check (role in ('admin','rep')),
 enabled boolean not null default false,
 created_at timestamptz not null default now(),
 primary key(workspace_id,user_id)
);
create index membership_user on public.workspace_members(user_id,workspace_id) where enabled;
-- Narrow lookup avoids recursive membership RLS. Authorization comes from live rows.
create function private.member_role(w uuid) returns text
language sql stable security definer set search_path = '' as $$
 select role from public.workspace_members
 where workspace_id=w and user_id=(select auth.uid()) and enabled
 and (select auth.uid()) is not null
$$;
revoke all on function private.member_role(uuid) from public, anon;
grant execute on function private.member_role(uuid) to authenticated;

create table public.provider_connections (
 workspace_id uuid not null references public.workspaces(id),
 id uuid not null default gen_random_uuid(),
 provider text not null check(provider in ('twilio','hubspot')),
 external_account_id text not null,
 connected boolean not null default false,
 generation integer not null default 1 check(generation>0),
 created_at timestamptz not null default now(),
 primary key(workspace_id,id),
 unique(workspace_id,provider)
);
-- No tokens here. Provider onboarding and encrypted credentials are a later slice.
create table public.contacts (
 workspace_id uuid not null,
 id uuid not null default gen_random_uuid(),
 connection_id uuid not null,
 hubspot_contact_id text not null,
 first_name text, last_name text, email text, phone text,
 matched_at timestamptz not null default now(),
 primary key(workspace_id,id),
 foreign key(workspace_id,connection_id) references public.provider_connections(workspace_id,id),
 unique(workspace_id,connection_id,hubspot_contact_id)
);
create index contacts_phone on public.contacts(workspace_id,phone);
create table public.calls (
 workspace_id uuid not null references public.workspaces(id),
 id uuid not null default gen_random_uuid(),
 rep_user_id uuid not null,
 contact_id uuid,
 hubspot_connection_id uuid,
 direction text not null check(direction in ('inbound','outbound')),
 technical_status text not null default 'queued' check(technical_status in
 ('queued','initiated','ringing','in-progress','completed','busy','failed','no-answer','canceled')),
 occurred_at timestamptz not null default now(),
 duration_seconds integer check(duration_seconds>=0),
 notes text not null default '' check(length(notes)<=10000),
 outcome text check(outcome in ('connected','left_message','not_interested','follow_up','wrong_number')),
 version integer not null default 1 check(version>0),
 primary key(workspace_id,id),
 foreign key(workspace_id,rep_user_id) references public.workspace_members(workspace_id,user_id),
 foreign key(workspace_id,contact_id) references public.contacts(workspace_id,id),
 foreign key(workspace_id,hubspot_connection_id) references public.provider_connections(workspace_id,id)
);
create index calls_rep_recent on public.calls(workspace_id,rep_user_id,occurred_at desc);
create index calls_contact on public.calls(workspace_id,contact_id);
create index calls_connection on public.calls(workspace_id,hubspot_connection_id);

create table private.sync_settings (
 workspace_id uuid not null,
 connection_id uuid not null,
 enabled boolean not null default false,
 batch_size integer not null default 50 check(batch_size between 1 and 100),
 max_wait_seconds integer not null default 900 check(max_wait_seconds between 1 and 1800),
 blocked_until timestamptz not null default '-infinity',
 primary key(workspace_id,connection_id),
 foreign key(workspace_id,connection_id) references public.provider_connections(workspace_id,id)
);
create table private.sync_jobs (
 id uuid primary key default gen_random_uuid(),
 workspace_id uuid not null,
 connection_id uuid not null,
 call_id uuid not null,
 desired_version integer not null check(desired_version>0),
 claimed_version integer,
 state text not null default 'ready' check(state in ('ready','leased','sent','ambiguous','failed')),
 ready_since timestamptz not null default now(),
 available_at timestamptz not null default now(),
 lease_token uuid, lease_until timestamptz,
 attempts integer not null default 0,
 activity_id text,
 last_error_code text,
 foreign key(workspace_id,connection_id) references private.sync_settings(workspace_id,connection_id),
 foreign key(workspace_id,call_id) references public.calls(workspace_id,id),
 unique(workspace_id,connection_id,call_id)
);
create unique index sync_activity_mapping on private.sync_jobs(workspace_id,connection_id,activity_id)
 where activity_id is not null;
create index jobs_ready on private.sync_jobs(workspace_id,connection_id,available_at,ready_since) where state='ready';
create index jobs_call on private.sync_jobs(workspace_id,call_id);
create table private.call_legs (
 workspace_id uuid not null,
 connection_id uuid not null,
 provider_call_sid text not null,
 call_id uuid not null,
 last_sequence bigint not null default -1,
 technical_status text not null default 'queued',
 authoritative boolean not null default false,
 primary key(workspace_id,connection_id,provider_call_sid),
 foreign key(workspace_id,connection_id) references public.provider_connections(workspace_id,id),
 foreign key(workspace_id,call_id) references public.calls(workspace_id,id)
);
create index legs_call on private.call_legs(workspace_id,call_id);
create unique index one_authoritative_leg on private.call_legs(workspace_id,call_id) where authoritative;

create function private.enqueue_call(w uuid,c uuid) returns void
language sql security invoker set search_path='' as $$
 insert into private.sync_jobs(workspace_id,connection_id,call_id,desired_version)
 select workspace_id,hubspot_connection_id,id,version from public.calls
 where workspace_id=w and id=c and hubspot_connection_id is not null and contact_id is not null
 on conflict(workspace_id,connection_id,call_id) do update set
 desired_version=excluded.desired_version,
 state=case when private.sync_jobs.state='sent' then 'ready' else private.sync_jobs.state end,
 ready_since=case when private.sync_jobs.state='sent' then now() else private.sync_jobs.ready_since end,
 available_at=case when private.sync_jobs.state='sent' then now() else private.sync_jobs.available_at end
$$;

create function private.edit_call(w uuid,c uuid,expected_version integer,new_notes text,new_outcome text)
returns public.calls language plpgsql security definer set search_path='' as $$
declare row_call public.calls; actor_role text;
begin
 actor_role:=private.member_role(w);
 if auth.uid() is null or actor_role is null then
  raise exception 'forbidden' using errcode='42501';
 end if;
 select * into row_call from public.calls where workspace_id=w and id=c for update;
 if not found or (actor_role<>'admin' and row_call.rep_user_id<>auth.uid()) then
  raise exception 'forbidden' using errcode='42501';
 end if;
 if expected_version is null or row_call.version<>expected_version then raise exception 'version_conflict' using errcode='40001'; end if;
 update public.calls set notes=new_notes,outcome=new_outcome,version=version+1
 where workspace_id=w and id=c returning * into row_call;
 perform private.enqueue_call(w,c);
 return row_call;
end $$;
create function public.edit_call(w uuid,c uuid,expected_version integer,new_notes text,new_outcome text)
returns public.calls language sql security invoker set search_path='' as $$
 select private.edit_call(w,c,expected_version,new_notes,new_outcome)
$$;
revoke all on function private.edit_call(uuid,uuid,integer,text,text) from public,anon;
revoke all on function public.edit_call(uuid,uuid,integer,text,text) from public,anon;
grant execute on function private.edit_call(uuid,uuid,integer,text,text) to authenticated;
grant execute on function public.edit_call(uuid,uuid,integer,text,text) to authenticated;

-- Service-only event reducer. An HTTP adapter must verify Twilio signatures BEFORE calling.
-- leg registration is internal: no accepting caller-supplied tenant/call mappings.
create function public.accept_call_event(w uuid,conn uuid,sid text,seq bigint,
 next_status text,seconds integer default null) returns boolean
language plpgsql security invoker set search_path='' as $$
declare leg private.call_legs; current_call public.calls;
begin
 if seq is null or next_status is null or seq<0 or next_status not in ('queued','initiated','ringing','in-progress','completed','busy','failed','no-answer','canceled')
 or seconds<0 then raise exception 'invalid_event' using errcode='22023'; end if;
 select * into leg from private.call_legs where workspace_id=w and connection_id=conn
 and provider_call_sid=sid for update;
 if not found then raise exception 'unknown_leg' using errcode='22023'; end if;
 if not exists(select 1 from public.provider_connections where workspace_id=w and id=conn
 and provider='twilio' and connected) then raise exception 'provider_disconnected' using errcode='42501'; end if;
 if seq<=leg.last_sequence then return false; end if;
 update private.call_legs set last_sequence=seq,technical_status=next_status
 where workspace_id=w and connection_id=conn and provider_call_sid=sid;
 if not leg.authoritative then return true; end if;
 select * into current_call from public.calls where workspace_id=w and id=leg.call_id for update;
 -- Terminal logical status never regresses. Voice leg precedence must be selected
 -- explicitly by the future webhook adapter; parent-leg completion is not call success.
 if current_call.technical_status in ('completed','busy','failed','no-answer','canceled') then return true; end if;
 if next_status in ('queued','initiated','ringing','in-progress') and
 array_position(array['queued','initiated','ringing','in-progress'],next_status) <
 array_position(array['queued','initiated','ringing','in-progress'],current_call.technical_status) then return true; end if;
 update public.calls set technical_status=next_status,duration_seconds=coalesce(seconds,duration_seconds),version=version+1
 where workspace_id=w and id=leg.call_id;
 perform private.enqueue_call(w,leg.call_id);
 return true;
end $$;

create function public.claim_sync_batch(w uuid,conn uuid)
returns setof private.sync_jobs language plpgsql security invoker set search_path='' as $$
declare cfg private.sync_settings; eligible_count integer; oldest timestamptz;
begin
 -- Serialize each connection: rate gates and batch eligibility are consistent.
 select * into cfg from private.sync_settings where workspace_id=w and connection_id=conn for update skip locked;
 if not found or not cfg.enabled or cfg.blocked_until>now() then return; end if;
 if not exists(select 1 from public.provider_connections where workspace_id=w and id=conn
 and provider='hubspot' and connected) then return; end if;
 -- A worker may have sent a create before losing its lease. Never blindly recreate.
 update private.sync_jobs set state=case when activity_id is null then 'ambiguous' else 'ready' end,
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

create function public.finish_sync_job(job uuid,token uuid,result text,remote_id text default null,
 retry_after_seconds integer default 30) returns boolean
language plpgsql security invoker set search_path='' as $$
declare j private.sync_jobs;
begin
 if result is null or token is null or retry_after_seconds is null or result not in ('ok','retry','ambiguous','failed') or retry_after_seconds not between 1 and 86400 then
 raise exception 'invalid_result' using errcode='22023'; end if;
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

alter table public.workspaces enable row level security;
alter table public.workspace_members enable row level security;
alter table public.provider_connections enable row level security;
alter table public.contacts enable row level security;
alter table public.calls enable row level security;
alter table private.sync_settings enable row level security;
alter table private.sync_jobs enable row level security;
alter table private.call_legs enable row level security;

revoke all on public.workspaces,public.workspace_members,public.provider_connections,public.contacts,public.calls from anon,authenticated;
grant select on public.workspaces,public.workspace_members,public.provider_connections,public.contacts,public.calls to authenticated;
grant all on public.workspaces,public.workspace_members,public.provider_connections,public.contacts,public.calls to service_role;
grant all on all tables in schema private to service_role;
create policy workspace_read on public.workspaces for select to authenticated using(private.member_role(id) is not null);
create policy members_read on public.workspace_members for select to authenticated
 using(private.member_role(workspace_id)='admin' or (user_id=(select auth.uid()) and private.member_role(workspace_id) is not null));
create policy connections_read on public.provider_connections for select to authenticated using(private.member_role(workspace_id) is not null);
create policy contacts_read on public.contacts for select to authenticated using(private.member_role(workspace_id) is not null);
create policy calls_read on public.calls for select to authenticated
 using(private.member_role(workspace_id)='admin' or (rep_user_id=(select auth.uid()) and private.member_role(workspace_id)='rep'));

revoke all on function private.enqueue_call(uuid,uuid) from public,anon,authenticated;
grant execute on function private.enqueue_call(uuid,uuid) to service_role;
revoke all on function public.accept_call_event(uuid,uuid,text,bigint,text,integer) from public,anon,authenticated;
revoke all on function public.claim_sync_batch(uuid,uuid) from public,anon,authenticated;
revoke all on function public.finish_sync_job(uuid,uuid,text,text,integer) from public,anon,authenticated;
grant execute on function public.accept_call_event(uuid,uuid,text,bigint,text,integer) to service_role;
grant execute on function public.claim_sync_batch(uuid,uuid) to service_role;
grant execute on function public.finish_sync_job(uuid,uuid,text,text,integer) to service_role;

-- Enforce CRM contact/connection consistency structurally.
alter table public.contacts add constraint contact_connection_key unique(workspace_id,id,connection_id);
alter table public.calls add constraint call_contact_connection foreign key(workspace_id,contact_id,hubspot_connection_id)
 references public.contacts(workspace_id,id,connection_id);
alter table public.calls add constraint call_contact_requires_connection check(contact_id is null or hubspot_connection_id is not null);

create function private.set_member(w uuid,u uuid,new_role text,new_enabled boolean) returns void
language plpgsql security definer set search_path='' as $$
begin
 -- Serialize membership mutations, including concurrent attempts to remove last admin.
 perform 1 from public.workspaces where id=w for update;
 if auth.uid() is null or private.member_role(w) is distinct from 'admin' then
 raise exception 'forbidden' using errcode='42501'; end if;
 if new_role is null or new_role not in ('admin','rep') or new_enabled is null then
 raise exception 'invalid_member' using errcode='22023'; end if;
 if exists(select 1 from public.workspace_members where workspace_id=w and user_id=u and role='admin' and enabled)
 and (new_role<>'admin' or not new_enabled)
 and not exists(select 1 from public.workspace_members where workspace_id=w and user_id<>u and role='admin' and enabled) then
 raise exception 'last_admin' using errcode='23514'; end if;
 insert into public.workspace_members(workspace_id,user_id,role,enabled) values(w,u,new_role,new_enabled)
 on conflict(workspace_id,user_id) do update set role=excluded.role,enabled=excluded.enabled;
end $$;
create function public.set_member(w uuid,u uuid,new_role text,new_enabled boolean) returns void
language sql security invoker set search_path='' as $$
 select private.set_member(w,u,new_role,new_enabled)
$$;
revoke all on function private.set_member(uuid,uuid,text,boolean) from public,anon;
revoke all on function public.set_member(uuid,uuid,text,boolean) from public,anon;
grant execute on function private.set_member(uuid,uuid,text,boolean) to authenticated;
grant execute on function public.set_member(uuid,uuid,text,boolean) to authenticated;

create function private.call_sync_status(w uuid,c uuid)
returns table(state text,desired_version integer,activity_id text,last_error_code text)
language plpgsql security definer set search_path='' as $$
declare actor_role text;
begin
 actor_role:=private.member_role(w);
 if auth.uid() is null or actor_role is null or not exists(
 select 1 from public.calls where workspace_id=w and id=c and (actor_role='admin' or rep_user_id=auth.uid())
 ) then raise exception 'forbidden' using errcode='42501'; end if;
 return query select j.state,j.desired_version,j.activity_id,j.last_error_code from private.sync_jobs j
 where j.workspace_id=w and j.call_id=c;
end $$;
create function public.call_sync_status(w uuid,c uuid)
returns table(state text,desired_version integer,activity_id text,last_error_code text)
language sql security invoker set search_path='' as $$
 select * from private.call_sync_status(w,c)
$$;
revoke all on function private.call_sync_status(uuid,uuid) from public,anon;
revoke all on function public.call_sync_status(uuid,uuid) from public,anon;
grant execute on function private.call_sync_status(uuid,uuid) to authenticated;
grant execute on function public.call_sync_status(uuid,uuid) to authenticated;
