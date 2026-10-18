
create extension if not exists supabase_vault with schema vault;
alter table public.provider_connections add column validated_at timestamptz;
create table private.provider_credentials (
 workspace_id uuid not null,
 connection_id uuid not null,
 secret_id uuid not null unique references vault.secrets(id) on delete restrict,
 primary key(workspace_id,connection_id),
 foreign key(workspace_id,connection_id) references public.provider_connections(workspace_id,id)
);
alter table private.provider_credentials enable row level security;
revoke all on private.provider_credentials from public,anon,authenticated;
grant select on private.provider_credentials to service_role;
-- No application role receives access to Vault's plaintext view.
revoke all on vault.decrypted_secrets from public,anon,authenticated;
revoke all on vault.secrets from public,anon,authenticated;

create function private.stage_provider_credentials(w uuid,p text,external_id text,credentials jsonb,expected_generation integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare conn public.provider_connections; sid uuid;
begin
 perform 1 from public.workspaces where id=w for update;
 if auth.uid() is null or private.member_role(w) is distinct from 'admin' then
 raise exception 'forbidden' using errcode='42501'; end if;
 if p is null or p not in ('hubspot','twilio') or external_id is null or length(external_id) not between 1 and 128
 or expected_generation is null or expected_generation<0 or jsonb_typeof(credentials) is distinct from 'object'
 or octet_length(credentials::text)>8192 then raise exception 'invalid_credentials' using errcode='22023'; end if;
 if p='hubspot' then
  if not (credentials ? 'access_token') or (select count(*) from jsonb_object_keys(credentials))<>1
  or jsonb_typeof(credentials->'access_token') is distinct from 'string'
  or length(credentials->>'access_token') not between 10 and 4096 or external_id !~ '^[0-9]+$' then
  raise exception 'invalid_credentials' using errcode='22023'; end if;
 else
  if credentials->>'account_sid' is distinct from external_id or external_id !~ '^AC[0-9a-fA-F]{32}$'
  or coalesce(credentials->>'api_key_sid','') !~ '^SK[0-9a-fA-F]{32}$'
  or jsonb_typeof(credentials->'api_key_secret') is distinct from 'string'
  or length(credentials->>'api_key_secret') not between 16 and 256
  or exists(select 1 from jsonb_object_keys(credentials) k where k not in ('account_sid','api_key_sid','api_key_secret','auth_token'))
  or (credentials ? 'auth_token' and (jsonb_typeof(credentials->'auth_token') is distinct from 'string' or length(credentials->>'auth_token') not between 16 and 256))
  then raise exception 'invalid_credentials' using errcode='22023'; end if;
 end if;
 select * into conn from public.provider_connections where workspace_id=w and provider=p for update;
 if found then
  if conn.generation<>expected_generation then raise exception 'generation_conflict' using errcode='PT409'; end if;
  if conn.external_account_id<>external_id then raise exception 'account_change_requires_new_workspace' using errcode='PT409'; end if;
  update public.provider_connections set connected=false,generation=generation+1,validated_at=null
  where workspace_id=w and id=conn.id returning * into conn;
 else
  if expected_generation<>0 then raise exception 'generation_conflict' using errcode='PT409'; end if;
  insert into public.provider_connections(workspace_id,provider,external_account_id,connected)
  values(w,p,external_id,false) returning * into conn;
 end if;
 select secret_id into sid from private.provider_credentials where workspace_id=w and connection_id=conn.id;
 if sid is null then
  sid:=vault.create_secret(credentials::text,'calling/'||w::text||'/'||conn.id::text,'Provider credentials');
  insert into private.provider_credentials values(w,conn.id,sid);
 else
  perform vault.update_secret(sid,credentials::text);
 end if;
 -- Fence workers before replacing credentials; preserve uncertain creates for reconciliation.
 update private.sync_settings set enabled=false where workspace_id=w and connection_id=conn.id;
 update private.sync_jobs set state=case when activity_id is null then 'ambiguous' else 'ready' end,
 lease_token=null,lease_until=null,last_error_code='credentials_changed'
 where workspace_id=w and connection_id=conn.id and state='leased';
 return jsonb_build_object('connection_id',conn.id,'generation',conn.generation);
end $$;
create function public.stage_provider_credentials(w uuid,p text,external_id text,credentials jsonb,expected_generation integer)
returns jsonb language sql security invoker set search_path='' as $$
 select private.stage_provider_credentials(w,p,external_id,credentials,expected_generation)
$$;
revoke all on function private.stage_provider_credentials(uuid,text,text,jsonb,integer) from public,anon,service_role;
revoke all on function public.stage_provider_credentials(uuid,text,text,jsonb,integer) from public,anon,service_role;
grant execute on function private.stage_provider_credentials(uuid,text,text,jsonb,integer) to authenticated;
grant execute on function public.stage_provider_credentials(uuid,text,text,jsonb,integer) to authenticated;

-- Only the trusted Edge adapter can mark its provider-verified generation as connected.
-- Direct calls to staging cannot bypass external validation.
create function public.approve_provider_credentials(w uuid,c uuid,g integer,external_id text,actor uuid)
returns boolean language plpgsql security invoker set search_path='' as $$
begin
 perform 1 from public.workspaces where id=w for update;
 if actor is null or not exists(select 1 from public.workspace_members
 where workspace_id=w and user_id=actor and enabled and role='admin') then return false; end if;
 update public.provider_connections set connected=true,validated_at=now()
 where workspace_id=w and id=c and generation=g and external_account_id=external_id
 and exists(select 1 from private.provider_credentials pc where pc.workspace_id=w and pc.connection_id=c);
 return found;
end $$;
revoke all on function public.approve_provider_credentials(uuid,uuid,integer,text,uuid) from public,anon,authenticated;
grant execute on function public.approve_provider_credentials(uuid,uuid,integer,text,uuid) to service_role;

create function private.disconnect_provider(w uuid,p text,expected_generation integer) returns void
language plpgsql security definer set search_path='' as $$
declare conn public.provider_connections; sid uuid;
begin
 perform 1 from public.workspaces where id=w for update;
 if auth.uid() is null or private.member_role(w) is distinct from 'admin' then raise exception 'forbidden' using errcode='42501'; end if;
 select * into conn from public.provider_connections where workspace_id=w and provider=p for update;
 if not found then return; end if;
 if expected_generation is null or conn.generation<>expected_generation then raise exception 'generation_conflict' using errcode='PT409'; end if;
 update public.provider_connections set connected=false,generation=generation+1,validated_at=null where workspace_id=w and id=conn.id;
 update private.sync_settings set enabled=false where workspace_id=w and connection_id=conn.id;
 update private.sync_jobs set state=case when activity_id is null then 'ambiguous' else 'ready' end,
 lease_token=null,lease_until=null,last_error_code='provider_disconnected'
 where workspace_id=w and connection_id=conn.id and state='leased';
 delete from private.provider_credentials where workspace_id=w and connection_id=conn.id returning secret_id into sid;
 if sid is not null then delete from vault.secrets where id=sid; end if;
end $$;
create function public.disconnect_provider(w uuid,p text,expected_generation integer) returns void
language sql security invoker set search_path='' as $$
 select private.disconnect_provider(w,p,expected_generation)
$$;
revoke all on function private.disconnect_provider(uuid,text,integer) from public,anon,service_role;
revoke all on function public.disconnect_provider(uuid,text,integer) from public,anon,service_role;
grant execute on function private.disconnect_provider(uuid,text,integer) to authenticated;
grant execute on function public.disconnect_provider(uuid,text,integer) to authenticated;
