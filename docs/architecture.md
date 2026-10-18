# Foundation decisions and remaining design work

## Scope and components

Only calling is in scope. No extension UI, billing, email, sequences, meetings, companies or deals are implemented. Customers own/pay Twilio directly; membership.enabled is application access, not a billing ledger.

Supabase Auth provides identity; PostgreSQL provides live workspace membership, RLS, call state and durable queue transactions. The Edge JSON API uses only user-scoped credentials. Narrow private SECURITY DEFINER helpers support membership lookup/mutations, note edit plus queue persistence, and authorized sync visibility. Each uses explicit identity/authorization checks, an empty search_path and restricted execute grants. The public wrappers are SECURITY INVOKER. No generic privileged write endpoint exists.

Private tables have RLS with no authenticated policies by design (deny all); service-role/internal owner access is necessary for workers. The private schema must stay outside the exposed Data API schemas. Call attribution and membership rows are retained; offboard by disabling membership, not deleting historical users.

## Logical call and durable synchronization primitives

A call has one immutable workspace/rep attribution. Provider call legs have unique (workspace, connection, provider SID) and reference one call. Only a server-designated authoritative telephone leg updates logical state; parent/client legs never create duplicate logical calls. The future signed adapter must register and validate this mapping before invoking accept_call_event. The reducer accepts increasing sequence numbers, deduplicates repeated events, and protects terminal state. Inbound matching/routing and safe unknown-leg acceptance remain unimplemented.

Notes/outcome edits check an expected version, lock the call, mutate it and enqueue the desired version atomically. Minimal CRM references are scoped to the same workspace and connection. Phone/email are intentionally not unique person identifiers. No raw webhook payloads are stored. Provider secrets are now stored only in encrypted Vault records as described below.

Jobs are unique per workspace/connection/call. claim_sync_batch serializes each connection with a settings-row lock and uses SKIP LOCKED for claims. It flushes when enough eligible jobs exist OR the oldest eligible job reaches max_wait_seconds. Default batch size is 50, default wait 900 seconds, synchronization disabled until explicitly configured. Schema bound 100 is provisional until the selected HubSpot endpoint/version is verified; no HTTP batch worker is deployed.

Claims expire after 90 seconds; an unexpired batch blocks overlapping claims for the same connection. Completion requires the current lease token before expiry. Updates that arrive in flight stay pending through desired_version versus claimed_version. Each item completes independently; successful items retain their mapping, while partial failures remain separate. Retry delay respects a supplied Retry-After lower bound and bounded exponential delay; jitter belongs in the future worker. Eight attempts is the retry bound, including expired known-activity updates. Claim and completion use a consistent settings-before-jobs lock order. Per-connection blocked_until gates rate-limited work.

An expired create claim or explicit ambiguous response is quarantined, not blindly retried. This favors avoiding duplicates over silent delivery promises. The HTTP worker must include an application correlation marker wherever the selected HubSpot API supports it, retain returned activity IDs and reconcile uncertain creates within the correct installed account. A request correlation ID alone is not an idempotency guarantee. Search absence may be eventual; never use it as proof a create failed. Reconciliation/admin recovery are not yet implemented, so ambiguous jobs currently require operator investigation and must not be reset blindly. Exactly-once delivery is not claimed.

## Provider slice to implement next

The owner selected an existing legacy HubSpot private app for single-account development. Multi-customer distribution will prefer company-level OAuth; private distribution, marketplace distribution/listing and the extension UI location are separate choices. Contact/call APIs do not justify company/deal scopes. Batch limit, association inclusion and per-item correlation support must be confirmed against the chosen endpoints before enabling synchronization.

The development provisioning slice now uses encrypted Supabase Vault records referenced from private.provider_credentials, with generation-checked rotation, administrator-only writes and disconnect cleanup. The public schema stores only metadata. A separate server-only validation approval prevents the user-facing staging RPC from activating unverified credentials. There is no secret-read API; worker retrieval remains future work. Do not put per-customer secrets in the public schema or extension.

Future Edge adapters handle token issuance, OAuth and signed provider HTTP callbacks. Transactional functions own authorization and state transitions. Scheduled bounded worker invocations drain durable work; no long-lived Edge worker and no telephone audio through Supabase. No external queue infrastructure is currently necessary. Free Edge worker wall-clock duration is documented as 150 seconds; the 15–30-minute delay therefore belongs in database readiness timestamps.

Twilio setup must validate account-owned numbers, assigned identity, normalized E.164 destinations and configurable geographic restrictions. Disabled reps cannot obtain new calling authority; already issued tokens require short TTL plus server checks on subsequent call initiation. Inbound unavailability/no-answer should end cleanly and record a missed call. Do not add advanced IVR/queues/transfers.

## Retention development defaults

No automatic purge is implemented yet. Proposed operational policy: confirmed-synced call metadata/notes 30 days; provider event receipts 7 days; sync attempts 14 days; redacted diagnostics 7 days. Recording is excluded; add provider-private references only if explicitly included later. Never purge pending/failed/ambiguous work or the minimal activity mappings/deduplication evidence needed for reconciliation. Do not enable cleanup until tombstone/mapping retention and delayed-callback handling are implemented and tested. Permanent searchable call history is not a confirmed product feature.

## Sources checked 2026-10-18

- https://supabase.com/docs/guides/database/postgres/row-level-security
- https://supabase.com/docs/guides/database/functions
- https://supabase.com/docs/guides/functions/auth
- https://supabase.com/docs/guides/functions/limits
- https://supabase.com/pricing
- https://supabase.com/changelog
- https://developers.hubspot.com/docs/api-reference/legacy/crm/activities/calls/guide
- https://developers.hubspot.com/docs/developer-tooling/platform/usage-guidelines
- https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle

The Markdown changelog endpoint could not be read by the web reader; HTML was accessible. The chosen provider API/scopes and complete Free-plan capacity assessment remain future verification work; 7,000 daily calls is not a confirmed launch workload and no such load was seeded.
