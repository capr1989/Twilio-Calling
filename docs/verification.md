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
