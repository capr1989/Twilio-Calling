# Connect your HubSpot private app and Twilio trial account

This development setup validates and encrypts credentials. It does not yet place calls, issue Voice SDK tokens, configure webhooks, or synchronize activities.

## 1. Create the application administrator

Open the Twilio Calling project in the Supabase dashboard, then Authentication > Users. Create an application user with an email/password you control (this is separate from your Supabase dashboard login). Use the dashboard's create-user option, not an invitation email, if you want to avoid sending an invitation. Confirm the user as appropriate for development. Keep the password out of chat and SQL.

Copy that Auth user's UUID. In the SQL editor, run the contents of [scripts/bootstrap-admin.sql](../scripts/bootstrap-admin.sql) after replacing REPLACE_WITH_AUTH_USER_UUID with that UUID. This creates a development workspace and its first enabled admin atomically. Save the returned workspace_id. Run the bootstrap once; it creates a workspace on every successful run.

No application administrator or workspace was created automatically because your administrator identity has not been supplied. Do not authorize a user merely because they signed up.

## 2. Obtain the setup script

Clone this review branch, or download and inspect it:

```powershell
git clone --branch feat/calling-foundation https://github.com/capr1989/Twilio-Calling.git
cd Twilio-Calling
```

Use PowerShell 7. The script targets only development project uimerlzcoizabjqzacyk. It prompts for the project publishable key (Settings > API keys), application administrator login, and provider credentials. Secrets use hidden prompts; they are sent over HTTPS, not written to a file, command-line argument, repository or chat. They necessarily exist briefly in local/server memory. Do not enable HTTP body/header tracing while provisioning.

## 3. Connect HubSpot

```powershell
pwsh -File .\scripts\connect-provider.ps1 -Provider hubspot -WorkspaceId YOUR_WORKSPACE_UUID
```

At the hidden token prompt, enter your legacy private-app access token from HubSpot Development > Legacy apps > your app > Auth. It must include crm.objects.contacts.read for this validation slice. The server calls the official private-app token-information endpoint to check token identity and that scope; it does not import contacts. Native call-activity write permissions and live activity logging are not verified by this step and will be checked when implementing the worker. Do not add company/deal scopes for this app's calling feature.

## 4. Connect Twilio

```powershell
pwsh -File .\scripts\connect-provider.ps1 -Provider twilio -WorkspaceId YOUR_WORKSPACE_UUID
```

Enter your trial account's live Account SID (AC...), a Standard API Key SID (SK...) and its Secret. Use US1 API credentials for the fixed api.twilio.com endpoint. These are the live credentials of your trial account, not Twilio's separate simulated test credentials. If necessary create a Standard API key in the Twilio Console; its secret is shown only when created.

The optional Auth Token prompt can be left blank for now. It will be required for future webhook signature verification. If entered, it is validated separately against your account and encrypted with the other credentials. Standard API Keys cannot query the Accounts endpoint; the key is instead checked using a read-only, one-item phone-number list request. An empty list does not prove calling readiness. The script does not buy numbers or place calls. Trial destination restrictions remain in force; authorize only your test numbers when calling is implemented.

## Rotation and disconnection

Re-run Connect to validate and replace credentials for the same external account. A generation check prevents concurrent/stale validation from activating newer credentials. Failed external validation leaves the old credentials untouched. If validation succeeds but storage/approval fails, GET status or rerun the script; do not assume the connection succeeded. The old account identity cannot be swapped into a new CRM/customer account in the same workspace because historical records remain bound to it.

```powershell
pwsh -File .\scripts\connect-provider.ps1 -Provider hubspot -WorkspaceId YOUR_WORKSPACE_UUID -Action Disconnect
pwsh -File .\scripts\connect-provider.ps1 -Provider twilio -WorkspaceId YOUR_WORKSPACE_UUID -Action Disconnect
```

Disconnect removes the active Vault secret, marks the connection disconnected, increments its generation, pauses synchronization and fences outstanding leases. It preserves historical calls/jobs/activity mappings; uncertain creates remain ambiguous for reconciliation. It does not revoke your token/key at the provider or erase historical encrypted backups; revoke provider credentials separately when appropriate. Reconnection does not automatically enable synchronization.

## Security and verification boundary

Secrets are encrypted with Supabase Vault and referenced from an unexposed private table. Application reps and admins cannot retrieve them through the API; project database owners/Vault operators remain trusted administrators. The Vault plaintext view and secret table are inaccessible to application users, and Vault is not an exposed Data API schema. Keep the private/vault schemas unexposed. No credential retrieval endpoint is deployed. Future workers must use narrowly authorized server-only access.

The provisioning function accepts bearer authentication from the local administrator script and rejects browser Origin headers. User metadata is never an authorization source. An online Auth check and current enabled-admin membership check precede provider requests. Storage and trusted validation approval repeat authorization and generation checks, so directly calling the staging RPC cannot mark unverified credentials connected. Only the server-side role may approve validation. Raw provider errors, secrets and request bodies are not logged by application code or returned.

Tested: 26 JavaScript tests, database credential/rotation/isolation tests with rollback, foundation SQL regression, and PowerShell syntax parsing. Real-provider validation and full interactive script execution have not been tested with your credentials. There are currently no configured users, workspaces or provider connections. Complete the steps above before attempting provider-dependent development.

Sources checked:
- https://supabase.com/docs/guides/database/vault
- https://developers.hubspot.com/docs/apps/legacy-apps/private-apps/overview
- https://www.twilio.com/docs/iam/api-keys
- https://www.twilio.com/docs/phone-numbers/api/incomingphonenumber-resource
