# Twilio Calling backend

Incremental calling MVP for a separately developed Chrome extension, customer-owned Twilio accounts and HubSpot. This branch implements the secure backend foundation; the complete calling demonstration is not ready.

## Implemented

- Workspace/admin/rep access with live enabled membership checks, RLS and scoped foreign keys.
- Administrator membership management with protection for the last enabled admin.
- Recent calls, private rep visibility, version-checked notes/outcomes and atomic synchronization enqueue.
- Internal provider-leg reducer with sequence deduplication, authoritative-leg selection and terminal-state protection.
- Durable tenant/connection-scoped jobs, size-or-age batch claims, leases, completion fencing, retries, remote activity mapping and ambiguous-result quarantine.
- Authenticated JSON API using caller-scoped database permissions. No service-role key in this API.
- Admin-only provider provisioning endpoint with read-only HubSpot private-app/Twilio key validation, encrypted Vault storage, rotation/disconnection and hidden-prompt local setup script.

## Still required for the first complete milestone

HubSpot OAuth installation/refresh for multi-customer distribution, Twilio number/identity assignment, browser token issuance, outbound intent, signed TwiML/webhook endpoints, inbound routing, HTTP synchronization worker/scheduler, reconciliation and admin recovery/settings, retention processing, and end-to-end live synthetic tests. No provider calls or customer imports have been performed.

Start with [provider setup](docs/provider-setup.md) to create your first administrator and enter credentials securely. See [setup](docs/setup.md), [API](docs/api.md), [architecture](docs/architecture.md) and [verification](docs/verification.md). Track full demonstration completion in issue #1.

## Run tests

```sh
node --test tests/api.test.mjs tests/providers.test.mjs
```

Run `tests/database.sql` and `tests/provider-credentials.sql` against an isolated migrated Supabase development database using a database-owner session. It creates synthetic fixtures inside a transaction and rolls them back. Never run fixture tests in production.

The JSON API is deployed to the development project with JWT verification enabled. The actual extension origin and first administrator are not configured yet.

Application code has no external npm/Deno package dependencies. Supabase CLI setup commands pin version 2.81.3; no application lockfile is needed until a dependency is introduced.
