# Verification record

Executed against the new development database on 2026-10-18:

- tests/database.sql passed as a single rollback transaction: tenant/role isolation, disabled-user denial, unauthorized direct writes, last-admin protection, note optimistic concurrency plus atomic enqueue, workspace-consistent foreign keys, duplicate/out-of-order event handling, parent/authoritative legs, terminal regression protection, size/age flush rules, double-claim prevention within a session, lease-token fencing, partial item completion, in-flight edits, ambiguous/expired create quarantine, disconnected provider denial and anonymous access denial.
- Post-test verification confirmed zero workspaces, calls and Auth users persisted.
- 12 API tests passed using Node's test runner and mocked Auth/REST responses. They cover origin handling, authentication, disabled membership, role escalation attempts, version conflicts without mutation retries, validation, payload bounds, RLS bearer forwarding, bounded recent reads and upstream error redaction.
- These tests do NOT verify a live HTTP Auth/Data API round-trip or actual Twilio/HubSpot behavior. Real concurrent-session claim/deadlock tests, retry delay/rate-limit cases, provider credential rotation and end-to-end scenarios remain required before calling this production-ready.

Advisors: private tables with RLS/no policies are intentional deny-all findings; no client table grants exist in that schema. Unused indexes are expected on an empty database and retained for the intended access paths. An uncovered composite call/contact foreign key was identified and is addressed by the follow-up migration.

Advisor references:
- https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy
- https://supabase.com/docs/guides/database/database-linter?lint=0005_unused_index
- https://supabase.com/docs/guides/database/database-linter?lint=0001_unindexed_foreign_keys

The regression also verifies that expired known-activity leases stop at eight attempts. A deployed unauthenticated GET /api/me returned HTTP 401 from the gateway. The api Edge Function is active, version 1, with verify_jwt=true; EXTENSION_ORIGINS still requires the actual extension ID before browser-origin requests can succeed.

No real calls, customer imports, audio files, provider credentials, or HubSpot HTTP requests were used. No production deployment or default-branch merge occurred.

## Provider credential slice

- 26 JavaScript tests passed (12 foundation API + 14 provider validation/authorization/redaction tests).
- tests/provider-credentials.sql passed and rolled back: actual Vault encryption/recovery/rotation, rep/admin/disabled-user and cross-tenant access, staging cannot mark connected, service-only validation approval, stale generation/account mismatch rejection, and secret deletion on disconnect.
- Foundation SQL suite passed again after the credential migration.
- scripts/connect-provider.ps1 parsed successfully with PowerShell's AST parser; its full interactive flow has not been run against real credentials.
- Security advisor reports only intentional deny-all/no-policy private tables, including provider_credentials. Vault plaintext reads by authenticated users were tested and denied.
- No real provider credentials have been entered; no real-provider validation, calls, number purchases, contact imports or activity writes were performed.

- The deployed providers Edge Function is active, version 1, with verify_jwt=true. A live unauthenticated request returned HTTP 401. Final fixture cleanup check found zero Auth users, workspaces and stored provider credential records.
- Mocked interactive PowerShell HubSpot and Twilio setup flows passed, checking posted credential shapes, no secret stdout, and local sign-out. Reproduce with `pwsh -File tests/setup-script.test.ps1`; no provider requests are made by that test. The live authenticated backend path and real provider credentials remain unverified.
