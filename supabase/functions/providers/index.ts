import { createProviderHandler } from "../_shared/providers.mjs";
Deno.serve(createProviderHandler({url:Deno.env.get("SUPABASE_URL")!,
 publishableKey:Deno.env.get("SUPABASE_PUBLISHABLE_KEY") || Deno.env.get("SUPABASE_ANON_KEY")!,
 serviceKey:Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
}));
