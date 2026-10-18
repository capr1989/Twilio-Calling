# JSON API: implemented foundation

Base URL: `https://<project-ref>.supabase.co/functions/v1/api`.
Send `apikey: <publishable key>` and `Authorization: Bearer <user access token>`. Write requests use `Content-Type: application/json`. Only origins listed in server `EXTENSION_ORIGINS` are allowed; absent Origin remains subject to authentication and authorization. CORS grants no application permission.

The gateway retains JWT verification; the handler also verifies the token online through Supabase Auth and accesses REST with that user's bearer. Membership is checked against current database rows for every workspace operation. RPC writes repeat authorization within the transaction. No client-supplied role or user_metadata authorizes access.

## Implemented routes

| Method/path | Request | Success |
| --- | --- | --- |
| GET /me | none | {user_id, memberships:[{workspace_id,role,enabled}]} |
| GET /workspaces/:w/calls | none | {items:[call]} most recent 50, newest first |
| GET /workspaces/:w/calls/:id | none | {call} |
| PATCH /workspaces/:w/calls/:id | {version:1,notes:"text",outcome:null} | {call} with incremented version |
| GET /workspaces/:w/calls/:id/sync | none | {items:[{state,desired_version,activity_id,last_error_code}]} |
| PUT /workspaces/:w/members/:user | {role:"rep",enabled:true} | {ok:true}; admin only |

Call fields: id, rep_user_id, contact_id, direction, technical_status, occurred_at, duration_seconds, notes, outcome, version. The edit RPC currently also returns workspace_id and hubspot_connection_id, which are identifiers, not credentials. Notes are at most 10,000 characters. Send both notes and outcome for an edit. Outcomes: connected, left_message, not_interested, follow_up, wrong_number, or null. Technical status is provider-derived and cannot be edited by clients.

Read isolation: admins see workspace calls; reps see their own calls. Enabled workspace members can read the workspace's minimal contact references and connection metadata through RLS; there are no provider tokens in these tables. Empty sync items mean no queued work, including unmatched contacts, not successful synchronization.

## Errors and retries

JSON errors have shape {error:"code"}. Codes/statuses: unauthorized 401; origin_not_allowed or forbidden 403; not_found 404; version_conflict 409; body_too_large 413; json_required 415; invalid_json 400; invalid_request 422; auth_unavailable/backend_unavailable 503. Sensitive upstream errors are not returned.

On version_conflict, fetch the call and resolve edits before retrying with its current version. Do not automatically replay a notes mutation after a network timeout: the commit may have succeeded. Refetch first. Membership PUT sets desired state and can be retried after checking current membership. GETs may be retried with bounded backoff. The API does not retry mutations internally.

## Sign-in/session integration

Use Supabase Auth directly for sign-in and refresh; never embed server/provider secrets. Onboarding for this slice is operator invitation through Supabase Auth, followed by initial workspace/admin creation by a trusted operator and subsequent membership assignment by the admin. Users must exist in Auth before membership assignment. This slice does not send invitations itself. Signup alone grants no workspace access.

Use a verified session access token on requests, refresh via the Auth refresh-token flow, and clear local session data on logout. The extension developer must choose secure extension storage and coordinate refresh across calling surfaces; this backend does not implement the extension.

A call must live in a supported long-lived extension page/window or suitably supported offscreen document, not solely the suspendable service worker. Verify microphone, WebRTC, media and offscreen requirements for the chosen Chrome version and Twilio SDK. Browser audio connects directly to Twilio.

## Not yet implemented

Twilio tokens/assignments; outbound intents/contact verification; incoming context endpoints; signed Twilio webhook/TwiML routes; OAuth callback; administrator sync settings/retry routes. These have no published endpoint contract yet. Do not route provider callbacks to this JSON API or call internal service-only RPCs from the extension.

## Provider provisioning (implemented separately)

Base: /functions/v1/providers/workspaces/:workspace/:provider, where provider is hubspot or twilio. Admin only; browser Origin headers are rejected. GET returns {connection:null|{id,provider,external_account_id,connected,generation,validated_at}} without secrets. PUT accepts {expected_generation:0,credentials:{...}}; zero is only for an absent connection. HubSpot credentials contain access_token only. Twilio credentials contain account_sid,api_key_sid,api_key_secret and optional auth_token. DELETE accepts {expected_generation:n}.

PUT verifies provider credentials, stages encrypted storage as disconnected, then approves only the validated current generation using server credentials. It returns connection_id,generation,connected and nonsecret check results. GET/DELETE never retrieve secrets or call provider APIs. There is no credential-read route. Use the local setup script in docs/provider-setup.md; this is not an extension setup flow.

Errors include forbidden/browser_provisioning_disabled 403, generation_conflict/connection_changed_retry 409, provider_validation_failed/contact_read_scope_required/invalid_credentials 422, and provider_rate_limited/provider_unavailable/backend_unavailable 503. No automatic retries. If PUT times out or returns 409, inspect GET status before submitting again. A failed approval leaves stored credentials disconnected. Reconnect does not start synchronization.
