import { createHandler } from "../_shared/api.mjs";
Deno.serve(createHandler({
 url: Deno.env.get("SUPABASE_URL")!,
 publishableKey: Deno.env.get("SUPABASE_PUBLISHABLE_KEY") || Deno.env.get("SUPABASE_ANON_KEY")!,
 allowedOrigins: (Deno.env.get("EXTENSION_ORIGINS") || "").split(",").map(v => v.trim()).filter(Boolean)
}));
