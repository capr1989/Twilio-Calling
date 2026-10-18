
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const outcomes = new Set([null, "connected", "left_message", "not_interested", "follow_up", "wrong_number"]);
export function createHandler({url, publishableKey, allowedOrigins = [], fetcher = fetch}) {
  const base = new URL(url).origin;
  if (!publishableKey) throw new Error("Missing publishable key");
  return async function handler(req) {
    const origin = req.headers.get("origin");
    const cors = {"Vary":"Origin","Cache-Control":"no-store"};
    if (origin && !allowedOrigins.includes(origin)) return Response.json({error:"origin_not_allowed"},{status:403,headers:cors});
    if (origin) Object.assign(cors, {"Access-Control-Allow-Origin":origin,
      "Access-Control-Allow-Headers":"authorization, apikey, content-type, x-client-info",
      "Access-Control-Allow-Methods":"GET, PATCH, PUT, OPTIONS"});
    const json = (data,status=200) => Response.json(data,{status,headers:cors});
    if (req.method === "OPTIONS") return new Response(null,{status:204,headers:cors});
    const bearer = req.headers.get("authorization") || "";
    if (!/^Bearer \S+$/i.test(bearer)) return json({error:"unauthorized"},401);
    const headers = {apikey:publishableKey,Authorization:bearer,"Content-Type":"application/json"};
    try {
      // Online verification; never authorize using unverified JWT/user_metadata.
      const auth = await fetcher(base+"/auth/v1/user",{headers,signal:AbortSignal.timeout(10000)});
      if (!auth.ok) return json({error:auth.status>=500?"auth_unavailable":"unauthorized"},auth.status>=500?503:401);
      const user = await auth.json();
      if (!uuid.test(user.id || "")) return json({error:"unauthorized"},401);
      async function db(path,method="GET",body) {
        const response = await fetcher(base+"/rest/v1/"+path,{method,headers,
          body:body === undefined ? undefined : JSON.stringify(body),signal:AbortSignal.timeout(10000)});
        if (!response.ok) {
          const detail = await response.json().catch(()=>({}));
          const status = detail.code==="40001"?409:detail.code==="42501"?403:
            ["23514","23503","22023","23502"].includes(detail.code)?422:503;
          throw Object.assign(new Error("database_error"),{status,
            code:status===409?"version_conflict":status===403?"forbidden":status===422?"invalid_request":"backend_unavailable"});
        }
        const text = await response.text();
        return text ? JSON.parse(text) : null;
      }
      const path = new URL(req.url).pathname.replace(/^(?:\/functions\/v1)?\/api(?=\/|$)/,"");
      if (req.method==="GET" && path==="/me") {
        const memberships = await db("workspace_members?select=workspace_id,role,enabled&user_id=eq."+user.id);
        return json({user_id:user.id,memberships});
      }
      const match = path.match(/^\/workspaces\/([^/]+)\/(calls|members)(?:\/([^/]+))?(?:\/(sync))?$/);
      if (!match || !uuid.test(match[1]) || (match[3] && !uuid.test(match[3]))) return json({error:"not_found"},404);
      const [,w,resource,id,sync] = match;
      const memberships = await db("workspace_members?select=role&workspace_id=eq."+w+"&user_id=eq."+user.id+"&enabled=eq.true");
      if (!memberships.length) return json({error:"forbidden"},403);
      const isAdmin = memberships[0].role==="admin";
      if (resource==="calls" && req.method==="GET") {
        if (sync && id) return json({items:await db("rpc/call_sync_status","POST",{w,c:id})});
        let query = "calls?select=id,rep_user_id,contact_id,direction,technical_status,occurred_at,duration_seconds,notes,outcome,version&workspace_id=eq."+w;
        if (id) query += "&id=eq."+id;
        else query += "&order=occurred_at.desc,id.desc&limit=50";
        const items = await db(query);
        if (id && !items.length) return json({error:"not_found"},404);
        return json(id?{call:items[0]}:{items});
      }
      if (!id || sync) return json({error:"not_found"},404);
      if ((resource==="calls" && req.method==="PATCH") || (resource==="members" && req.method==="PUT")) {
        if (resource==="members" && !isAdmin) return json({error:"forbidden"},403);
        if (!req.headers.get("content-type")?.startsWith("application/json")) return json({error:"json_required"},415);
        const reader = req.body?.getReader(); let bytes = 0; const chunks = [];
        if (reader) {
          while (true) {
            const {done,value} = await reader.read(); if (done) break;
            bytes += value.byteLength;
            if (bytes>65536) { await reader.cancel(); return json({error:"body_too_large"},413); }
            chunks.push(value);
          }
        }
        const bodyBytes = new Uint8Array(bytes); let offset=0;
        for (const chunk of chunks) { bodyBytes.set(chunk,offset); offset+=chunk.length; }
        let body;
        try { body=JSON.parse(new TextDecoder().decode(bodyBytes)); } catch { return json({error:"invalid_json"},400); }
        if (!body || Array.isArray(body) || typeof body!=="object") return json({error:"invalid_request"},422);
        if (resource==="calls") {
          if (Object.keys(body).some(k=>!["version","notes","outcome"].includes(k)) ||
            !Number.isSafeInteger(body.version) || body.version<1 || typeof body.notes!=="string" ||
            body.notes.length>10000 || !outcomes.has(body.outcome)) return json({error:"invalid_request"},422);
          const call = await db("rpc/edit_call","POST",{w,c:id,expected_version:body.version,
            new_notes:body.notes,new_outcome:body.outcome});
          return json({call});
        }
        if (Object.keys(body).some(k=>!["role","enabled"].includes(k)) ||
          !["admin","rep"].includes(body.role) || typeof body.enabled!=="boolean") return json({error:"invalid_request"},422);
        await db("rpc/set_member","POST",{w,u:id,new_role:body.role,new_enabled:body.enabled});
        return json({ok:true});
      }
      return json({error:"not_found"},404);
    } catch (error) {
      return json({error:["version_conflict","forbidden","invalid_request","backend_unavailable"].includes(error?.code) ? error.code : "backend_unavailable"},
        [403,409,422,503].includes(error?.status) ? error.status : 503);
    }
  };
}
