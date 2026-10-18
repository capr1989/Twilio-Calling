
import {test} from "node:test";
import assert from "node:assert/strict";
import {createHandler} from "../supabase/functions/_shared/api.mjs";
const user="10000000-0000-0000-0000-000000000002";
const workspace="20000000-0000-0000-0000-000000000001";
const call="50000000-0000-0000-0000-000000000001";
function setup(responses,origin="chrome-extension://synthetic") {
 const requests=[];
 const handler=createHandler({url:"https://example.supabase.co",publishableKey:"sb_publishable_synthetic",allowedOrigins:[origin],
 fetcher:async(url,options)=>{
  requests.push({url,options});
  assert.equal(options.headers.apikey,"sb_publishable_synthetic");
  assert.equal(options.headers.Authorization,"Bearer synthetic-user-token");
  if (!responses.length) throw new Error("Unexpected request");
  const next=responses.shift();
  if (next instanceof Error) throw next;
  return Response.json(next.body,{status:next.status || 200});
 }});
 return {handler,requests};
}
function request(path,method="GET",body) {
 return new Request("https://example.supabase.co/functions/v1/api"+path,{method,
 headers:{Authorization:"Bearer synthetic-user-token",Origin:"chrome-extension://synthetic","Content-Type":"application/json"},
 body:body===undefined?undefined:JSON.stringify(body)});
}
test("CORS rejects unknown origins before touching Auth",async()=>{
 const {handler,requests}=setup([]);
 const res=await handler(new Request("https://example/api/me",{headers:{Origin:"https://evil.invalid"}}));
 assert.equal(res.status,403); assert.equal(requests.length,0);
 assert.equal(res.headers.get("Access-Control-Allow-Origin"),null);
});
test("preflight is allowed without authentication for approved origin",async()=>{
 const {handler,requests}=setup([]);
 const res=await handler(new Request("https://example/api/me",{method:"OPTIONS",headers:{Origin:"chrome-extension://synthetic"}}));
 assert.equal(res.status,204); assert.equal(requests.length,0);
});
test("missing and rejected tokens never reach database",async()=>{
 const first=setup([]);
 assert.equal((await first.handler(new Request("https://example/api/me"))).status,401);
 const {handler,requests}=setup([{status:401,body:{message:"secret upstream"}}]);
 assert.equal((await handler(request("/me"))).status,401); assert.equal(requests.length,1);
});
test("me returns current RLS scoped memberships; no user metadata authorization",async()=>{
 const {handler,requests}=setup([{body:{id:user,user_metadata:{role:"admin"}}},{body:[]}]);
 const res=await handler(request("/me"));
 assert.deepEqual(await res.json(),{user_id:user,memberships:[]});
 assert.match(requests[1].url,new RegExp("user_id=eq."+user));
 assert.equal(res.headers.get("Cache-Control"),"no-store");
});
test("disabled membership stops scoped reads",async()=>{
 const {handler,requests}=setup([{body:{id:user}},{body:[]}]);
 assert.equal((await handler(request("/workspaces/"+workspace+"/calls"))).status,403);
 assert.equal(requests.length,2);
});
test("rep cannot mutate members even with fake admin user_metadata",async()=>{
 const {handler,requests}=setup([{body:{id:user,user_metadata:{role:"admin"}}},{body:[{role:"rep"}]}]);
 assert.equal((await handler(request("/workspaces/"+workspace+"/members/"+user,"PUT",{role:"admin",enabled:true}))).status,403);
 assert.equal(requests.length,2);
});
test("stale version maps to 409 and is never automatically retried",async()=>{
 const {handler,requests}=setup([{body:{id:user}},{body:[{role:"rep"}]},{status:500,body:{code:"40001",message:"version_conflict"}}]);
 const res=await handler(request("/workspaces/"+workspace+"/calls/"+call,"PATCH",{version:1,notes:"synthetic",outcome:null}));
 assert.equal(res.status,409);
 assert.deepEqual(await res.json(),{error:"version_conflict"});
 assert.equal(requests.length,3);
 assert.equal(JSON.parse(requests[2].options.body).expected_version,1);
});
test("call edits reject unknown fields and invalid outcomes",async()=>{
 for (const body of [{version:1,notes:"x",outcome:"made_up"},{version:1,notes:"x",outcome:null,workspace_id:"attacker"}]) {
 const {handler,requests}=setup([{body:{id:user}},{body:[{role:"rep"}]}]);
 assert.equal((await handler(request("/workspaces/"+workspace+"/calls/"+call,"PATCH",body))).status,422);
 assert.equal(requests.length,2);
 }
});
test("database failures redact upstream content",async()=>{
 const {handler}=setup([{body:{id:user}},{status:500,body:{message:"private detail",code:"internal"}}]);
 const res=await handler(request("/workspaces/"+workspace+"/calls"));
 assert.equal(res.status,503); assert.deepEqual(await res.json(),{error:"backend_unavailable"});
});
test("successful read retains user bearer, workspace filter and 50 call bound",async()=>{
 const {handler,requests}=setup([{body:{id:user}},{body:[{role:"rep"}]},{body:[{id:call}]}]);
 const res=await handler(request("/workspaces/"+workspace+"/calls"));
 assert.deepEqual(await res.json(),{items:[{id:call}]});
 assert.match(requests[2].url,/limit=50/); assert.ok(requests[2].url.includes("workspace_id=eq."+workspace));
});
test("network failure does not expose internal error code",async()=>{
 const {handler}=setup([Object.assign(new Error("private detail"),{code:"ECONNRESET"})]);
 const res=await handler(request("/me"));
 assert.equal(res.status,503); assert.deepEqual(await res.json(),{error:"backend_unavailable"});
});
test("oversize request is rejected before a database mutation",async()=>{
 const {handler,requests}=setup([{body:{id:user}},{body:[{role:"rep"}]}]);
 const res=await handler(request("/workspaces/"+workspace+"/calls/"+call,"PATCH",{version:1,notes:"x".repeat(70000),outcome:null}));
 assert.equal(res.status,413); assert.equal(requests.length,2);
});
