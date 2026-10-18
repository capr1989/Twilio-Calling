
import {test} from "node:test";
import assert from "node:assert/strict";
import {validateCredentials,createProviderHandler} from "../supabase/functions/_shared/providers.mjs";
const w="62000000-0000-0000-0000-000000000001",u="61000000-0000-0000-0000-000000000001";
const twilio={account_sid:"AC"+"a".repeat(32),api_key_sid:"SK"+"b".repeat(32),api_key_secret:"c".repeat(32)};
const hubspot={access_token:"pat-synthetic-private-token"};
function mock(responses){
 const requests=[];
 const fetcher=async(url,opts)=>{requests.push({url,opts});if(!responses.length)throw Error("unexpected request");
 const item=responses.shift();if(item instanceof Error)throw item;return Response.json(item.body,{status:item.status||200});};
 return {fetcher,requests};
}
function setup(responses){const m=mock(responses);return {...m,handler:createProviderHandler({url:"https://example.supabase.co",
 publishableKey:"publishable-synthetic",serviceKey:"server-secret-synthetic",fetcher:m.fetcher})};}
function req(method="PUT",body={expected_generation:0,credentials:hubspot},extraHeaders={}){
 return new Request("https://example.supabase.co/functions/v1/providers/workspaces/"+w+"/hubspot",
 {method,headers:{Authorization:"Bearer user-token","Content-Type":"application/json",...extraHeaders},
 body:method==="GET"?undefined:JSON.stringify(body)});
}
test("HubSpot token identity check uses fixed official POST, imports no contacts",async()=>{
 const m=mock([{body:{hubId:123,scopes:["crm.objects.contacts.read"]}}]);
 const result=await validateCredentials("hubspot",hubspot,m.fetcher);
 assert.equal(result.external_id,"123");assert.equal(result.checks.call_logging_verified,false);
 assert.equal(m.requests[0].url,"https://api.hubapi.com/oauth/v2/private-apps/get/access-token-info");
 assert.equal(m.requests[0].opts.redirect,"error");
});
test("HubSpot scope failure is explicit and does not claim call logging readiness",async()=>{
 const m=mock([{body:{hubId:123,scopes:["companies"]}}]);
 await assert.rejects(validateCredentials("hubspot",hubspot,m.fetcher),e=>e.safeCode==="contact_read_scope_required");
});
test("Twilio Standard API Key validation uses number list, not Accounts endpoint",async()=>{
 const m=mock([{body:{incoming_phone_numbers:[]}}]);await validateCredentials("twilio",twilio,m.fetcher);
 assert.equal(m.requests.length,1);assert.ok(m.requests[0].url.endsWith("/IncomingPhoneNumbers.json?PageSize=1"));
 assert.equal(m.requests[0].opts.headers.Authorization,"Basic "+btoa(twilio.api_key_sid+":"+twilio.api_key_secret));
});
test("optional webhook Auth Token is validated separately with account-scoped auth",async()=>{
 const m=mock([{body:{incoming_phone_numbers:[]}},{body:{sid:twilio.account_sid,status:"active",type:"Trial"}}]);
 const result=await validateCredentials("twilio",{...twilio,auth_token:"d".repeat(32)},m.fetcher);
 assert.equal(result.checks.account_type,"Trial");assert.equal(result.checks.auth_token_verified,true);
 assert.equal(result.checks.voice_token_issuance_verified,false);
});
test("invalid SIDs and foreign-account number responses fail closed",async()=>{
 await assert.rejects(validateCredentials("twilio",{...twilio,account_sid:"https://evil.invalid"},()=>{throw Error("should not fetch");}));
 const m=mock([{body:{incoming_phone_numbers:[{account_sid:"AC"+"e".repeat(32)}]}}]);
 await assert.rejects(validateCredentials("twilio",twilio,m.fetcher),e=>e.safeCode==="provider_response_invalid");
});
test("browser provisioning is denied before reading secrets or calling Auth",async()=>{
 const s=setup([]);assert.equal((await s.handler(req("PUT",undefined,{Origin:"chrome-extension://anything"}))).status,403);
 assert.equal(s.requests.length,0);
});
test("rep or disabled admin cannot trigger external credential validation",async()=>{
 for(const memberships of [[],[{role:"rep"}]]){
 const s=setup([{body:{id:u}},{body:memberships}]);assert.equal((await s.handler(req())).status,403);
 assert.equal(s.requests.length,2);}
});
test("validated credentials are staged as caller then approved with server-only credential",async()=>{
 const s=setup([{body:{id:u}},{body:[{role:"admin"}]},{body:{hubId:123,scopes:["crm.objects.contacts.read"]}},
 {body:{connection_id:"63000000-0000-0000-0000-000000000001",generation:1}},{body:true}]);
 const r=await s.handler(req());assert.equal(r.status,200);const text=await r.text();
 assert.ok(!text.includes(hubspot.access_token));assert.ok(!text.includes("server-secret"));
 assert.equal(s.requests[3].opts.headers.Authorization,"Bearer user-token");
 assert.equal(s.requests[4].opts.headers.Authorization,"Bearer server-secret-synthetic");
});
test("failed provider auth never persists credentials or echoes provider errors",async()=>{
 const s=setup([{body:{id:u}},{body:[{role:"admin"}]},{status:401,body:{message:hubspot.access_token}}]);
 const r=await s.handler(req());assert.equal(r.status,422);assert.deepEqual(await r.json(),{error:"provider_validation_failed"});
 assert.equal(s.requests.length,3);
});
test("rotation conflict returns 409, never retries or approves stale generation",async()=>{
 const s=setup([{body:{id:u}},{body:[{role:"admin"}]},{body:{hubId:123,scopes:["crm.objects.contacts.read"]}},
 {status:409,body:{code:"PT409",message:"sensitive details"}}]);
 const r=await s.handler(req());assert.equal(r.status,409);assert.equal(s.requests.length,4);
});
test("admin deactivation race at approval leaves staged connection unapproved",async()=>{
 const s=setup([{body:{id:u}},{body:[{role:"admin"}]},{body:{hubId:123,scopes:["crm.objects.contacts.read"]}},
 {body:{connection_id:"63000000-0000-0000-0000-000000000001",generation:1}},{body:false}]);
 const r=await s.handler(req());assert.equal(r.status,409);
 assert.deepEqual(await r.json(),{error:"connection_changed_retry"});
});
test("429 and network failures are redacted without automatic retries",async()=>{
 const first=setup([{body:{id:u}},{body:[{role:"admin"}]},{status:429,body:{private:"x"}}]);
 assert.equal((await first.handler(req())).status,503);assert.equal(first.requests.length,3);
 const second=setup([new Error(hubspot.access_token)]);
 const r=await second.handler(req());assert.deepEqual(await r.json(),{error:"backend_unavailable"});
});
test("DELETE only disconnects stored credentials without contacting provider APIs",async()=>{
 const s=setup([{body:{id:u}},{body:[{role:"admin"}]},{body:null}]);
 const r=await s.handler(req("DELETE",{expected_generation:2}));assert.equal(r.status,200);
 assert.ok(s.requests.every(x=>x.url.startsWith("https://example.supabase.co/")));
});
test("unexpected credential fields and oversized requests are rejected",async()=>{
 const s=setup([{body:{id:u}},{body:[{role:"admin"}]}]);
 const r=await s.handler(req("PUT",{expected_generation:0,credentials:{...hubspot,other:"x"}}));
 assert.equal(r.status,422);assert.equal(s.requests.length,2);
 const large=setup([{body:{id:u}},{body:[{role:"admin"}]}]);
 assert.equal((await large.handler(req("PUT",{expected_generation:0,credentials:{access_token:"x".repeat(17000)}}))).status,413);
});
