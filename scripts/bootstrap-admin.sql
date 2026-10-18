-- Run as a trusted operator in the Supabase SQL editor after creating the Auth user.
-- Replace the placeholder with YOUR administrator's UUID from Authentication > Users.
-- Do not put provider credentials in this file or the SQL editor.
with workspace as (
 insert into public.workspaces(name) values ('Calling development') returning id
), membership as (
 insert into public.workspace_members(workspace_id,user_id,role,enabled)
 select id,'REPLACE_WITH_AUTH_USER_UUID'::uuid,'admin',true from workspace
 returning workspace_id
)
select workspace_id from membership;
