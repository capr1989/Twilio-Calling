# Development setup

Confirmed destination: capr1989/Twilio-Calling. Supabase project: Twilio Calling, ref uimerlzcoizabjqzacyk, Carlos Pretto organization, us-east-1. Treat this as development only. The pre-existing techbuddy project was not changed.

1. Checkout the feature branch and inspect migrations before applying them to another development project.
2. Use pinned Supabase CLI 2.81.3 and Docker for local development. Discover commands via --help, then use init/start/db reset as appropriate. Run the CLI through `npx --yes supabase@2.81.3 <command>`. The newer CLI failed initialization at the sandbox home directory; this older version successfully generated migration files.
3. For local replay use the checked-in config and `supabase db reset`; for remote deployments link the intended development project, inspect migration history and use `supabase db push` only after reviewing its plan. Never target production by default.
4. Configure a publishable key and exact extension origin(s). Hosted runtimes provide SUPABASE_URL and the legacy SUPABASE_ANON_KEY compatibility fallback; SUPABASE_PUBLISHABLE_KEY is preferred if explicitly configured. Set EXTENSION_ORIGINS as a comma-separated list. No wildcard origins.
5. Invite authorized test users in the Supabase Auth dashboard. A trusted operator creates a workspace and its first enabled admin in one SQL transaction using the actual Auth user UUID. Do not hardcode real users into migrations. Enable reps individually through set_member/API. This is the explicit onboarding mechanism for the foundation slice.
6. Disable public signups in the remote Auth configuration for invitation-only onboarding. The repository config disables signup locally; it does not automatically change the hosted Auth settings. Remote signup configuration has not been changed. Even if signup is enabled, a new user has no workspace membership and no access to application data.
7. Run database and API tests. The SQL test script rolls back all fixtures. No provider credentials are needed for these tests.

The source migration filenames are aligned to the version returned by remote migration history. The original files were generated with Supabase CLI; the remote migration tool assigned a later version during application, so the repository filename was aligned to avoid a pending duplicate migration on the next push.

The first-admin bootstrap is intentionally an operator action. Do not expose a public workspace-creation/admin-grant endpoint or rely on self-declared metadata.

Provider setup is the next slice. The owner reports a HubSpot account and Twilio testing account; whether a HubSpot developer app exists is unconfirmed. Do not paste credentials in chat/issues. Establish the app distribution/platform version, OAuth redirect URL and least required scopes before implementing authorization. Twilio testing may mean trial account or test credentials; confirm which before attempting Voice SDK integration.
