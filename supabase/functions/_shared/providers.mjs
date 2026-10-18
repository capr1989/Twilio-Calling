
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function fail(code,status=422){throw Object.assign(new Error(code),{safeCode:code,status});}
export function checkCredentials(provider,c) {
 if(!c || Array.isArray(c) || typeof c!=="object") fail("invalid_credentials");
 if(provider==="hubspot"){
  if(Object.keys(c).length!==1 || typeof c.access_token!=="string" ||
    !/^[\x21-\x7e]{10,4096}$/.test(c.access_token)) fail("invalid_credentials");
 }else{
  if(Object.keys(c).some(k=>!["account_sid","api_key_sid","api_key_secret","auth_token"].includes(k)) ||
   !/^AC[0-9a-f]{32}$/i.test(c.account_sid||"") || !/^SK[0-9a-f]{32}$/i.test(c.api_key_sid||"") ||
   typeof c.api_key_secret!=="string" || !/^[A-Za-z0-9_+\/=-]{16,256}$/.test(c.api_key_secret) ||
   (c.auth_token!==undefined && !/^[0-9a-f]{32}$/i.test(c.auth_token))) fail("invalid_credentials");
 }
}
export async function validateCredentials(provider,c,fetcher=fetch) {
 checkCredentials(provider,c);
 async function providerRequest(url,options){
  const r=await fetcher(url,{...options,redirect:"error",signal:AbortSignal.timeout(10000)});
  if(r.status===429) fail("provider_rate_limited",503);
  if(r.status>=500) fail("provider_unavailable",503);
  if(!r.ok) fail("provider_validation_failed",422);
  return r.json();
 }
 if(provider==="hubspot"){
  const data=await providerRequest("https://api.hubapi.com/oauth/v2/private-apps/get/access-token-info",
   {method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({tokenKey:c.access_token})});
  const id=String(data.hubId||"");
  if(!/^[1-9][0-9]*$/.test(id) || !Array.isArray(data.scopes)) fail("provider_response_invalid",503);
  if(!data.scopes.includes("crm.objects.contacts.read")) fail("contact_read_scope_required");
  return {external_id:id,checks:{credential_verified:true,contact_read_scope:true,call_logging_verified:false}};
 }
 const root="https://api.twilio.com/2010-04-01/Accounts/"+c.account_sid;
 const numbers=await providerRequest(root+"/IncomingPhoneNumbers.json?PageSize=1",
  {headers:{Authorization:"Basic "+btoa(c.api_key_sid+":"+c.api_key_secret)}});
 if(!Array.isArray(numbers.incoming_phone_numbers) ||
   numbers.incoming_phone_numbers.some(n=>n.account_sid!==c.account_sid)) fail("provider_response_invalid",503);
 let accountType=null;
 if(c.auth_token){
  const account=await providerRequest(root+".json",
   {headers:{Authorization:"Basic "+btoa(c.account_sid+":"+c.auth_token)}});
  if(account.sid!==c.account_sid || account.status!=="active") fail("provider_account_inactive");
  accountType=account.type;
 }
 return {external_id:c.account_sid,checks:{credential_verified:true,auth_token_verified:!!c.auth_token,
  account_type:accountType,voice_token_issuance_verified:false}};
}
async function readJson(req){
 const reader=req.body?.getReader();let size=0;const chunks=[];
 if(reader) while(true){const {value,done}=await reader.read();if(done)break;size+=value.length;
  if(size>16384){await reader.cancel();fail("body_too_large",413);}chunks.push(value);}
 const bytes=new Uint8Array(size);let offset=0;for(const c of chunks){bytes.set(c,offset);offset+=c.length;}
 try{return JSON.parse(new TextDecoder().decode(bytes));}catch{fail("invalid_json",400);}
}
export function createProviderHandler({url,publishableKey,serviceKey,fetcher=fetch}){
 const base=new URL(url).origin;
 if(!publishableKey || !serviceKey)throw new Error("Missing server configuration");
 return async req=>{
  const respond=(data,status=200)=>Response.json(data,{status,headers:{"Cache-Control":"no-store","Vary":"Origin"}});
  // Provisioning is a local/admin operation, not an extension/browser form.
  if(req.headers.has("origin"))return respond({error:"browser_provisioning_disabled"},403);
  const authorization=req.headers.get("authorization")||"";
  if(!/^Bearer \S+$/i.test(authorization))return respond({error:"unauthorized"},401);
  try{
   const path=new URL(req.url).pathname.replace(/^(?:\/functions\/v1)?\/providers(?=\/|$)/,"");
   const m=path.match(/^\/workspaces\/([^/]+)\/(hubspot|twilio)$/);
   if(!m || !UUID.test(m[1]) || !["GET","PUT","DELETE"].includes(req.method))return respond({error:"not_found"},404);
   const [,w,p]=m;
   const headers={apikey:publishableKey,Authorization:authorization,"Content-Type":"application/json"};
   const auth=await fetcher(base+"/auth/v1/user",{headers,redirect:"error",signal:AbortSignal.timeout(10000)});
   if(!auth.ok)fail(auth.status>=500?"auth_unavailable":"unauthorized",auth.status>=500?503:401);
   const user=await auth.json();if(!UUID.test(user.id||""))fail("unauthorized",401);
   async function db(path,method="GET",body,privileged=false){
    const h=privileged?{apikey:serviceKey,Authorization:"Bearer "+serviceKey,"Content-Type":"application/json"}:headers;
    const r=await fetcher(base+"/rest/v1/"+path,{method,headers:h,body:body===undefined?undefined:JSON.stringify(body),
     redirect:"error",signal:AbortSignal.timeout(10000)});
    if(!r.ok){const d=await r.json().catch(()=>({}));
     if(d.code==="PT409")fail("generation_conflict",409);
     if(d.code==="42501")fail("forbidden",403);
     if(["22023","23514"].includes(d.code))fail("invalid_credentials",422);
     fail("backend_unavailable",503);
    }
    const t=await r.text();return t?JSON.parse(t):null;
   }
   const membership=await db("workspace_members?select=role&workspace_id=eq."+w+"&user_id=eq."+user.id+"&enabled=eq.true");
   if(membership.length!==1 || membership[0].role!=="admin")fail("forbidden",403);
   if(req.method==="GET"){
    const rows=await db("provider_connections?select=id,provider,external_account_id,connected,generation,validated_at&workspace_id=eq."+w+"&provider=eq."+p);
    return respond({connection:rows[0]||null});
   }
   if(!req.headers.get("content-type")?.startsWith("application/json"))fail("json_required",415);
   const body=await readJson(req);
   if(!body || Array.isArray(body) || typeof body!=="object" || !Number.isSafeInteger(body.expected_generation) ||
    body.expected_generation<0 || Object.keys(body).some(k=>!["credentials","expected_generation"].includes(k)))fail("invalid_request");
   if(req.method==="DELETE"){
    if(body.credentials!==undefined)fail("invalid_request");
    await db("rpc/disconnect_provider","POST",{w,p,expected_generation:body.expected_generation});
    return respond({connected:false});
   }
   const verified=await validateCredentials(p,body.credentials,fetcher);
   const staged=await db("rpc/stage_provider_credentials","POST",{w,p,external_id:verified.external_id,
    credentials:body.credentials,expected_generation:body.expected_generation});
   const approved=await db("rpc/approve_provider_credentials","POST",{w,c:staged.connection_id,g:staged.generation,
    external_id:verified.external_id,actor:user.id},true);
   if(approved!==true)fail("connection_changed_retry",409);
   return respond({connection_id:staged.connection_id,generation:staged.generation,connected:true,checks:verified.checks});
  }catch(error){
   const safe=new Set(["invalid_credentials","body_too_large","invalid_json","json_required","invalid_request","not_found",
    "unauthorized","auth_unavailable","forbidden","generation_conflict","connection_changed_retry","backend_unavailable",
    "provider_rate_limited","provider_unavailable","provider_validation_failed","provider_response_invalid",
    "contact_read_scope_required","provider_account_inactive"]);
   return respond({error:safe.has(error?.safeCode)?error.safeCode:"backend_unavailable"},
    safe.has(error?.safeCode)?error.status:503);
  }
 };
}
