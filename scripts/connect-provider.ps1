#Requires -Version 7.0
[CmdletBinding()]
param(
 [Parameter(Mandatory)][ValidateSet('hubspot','twilio')][string]$Provider,
 [Parameter(Mandatory)][guid]$WorkspaceId,
 [ValidateSet('Connect','Disconnect')][string]$Action = 'Connect'
)
$ErrorActionPreference = 'Stop'
$baseUrl = 'https://uimerlzcoizabjqzacyk.supabase.co'
$session = $null
$headers = $null
$body = $null
$credentials = $null
function Read-SecretText([string]$Prompt) {
 $secretValue = Read-Host $Prompt -AsSecureString
 try { return [System.Net.NetworkCredential]::new('', $secretValue).Password }
 finally { $secretValue.Dispose() }
}
function Send-Json([string]$Uri,[string]$Method,[hashtable]$Headers,$Payload) {
 try {
  $options = @{ Uri=$Uri; Method=$Method; Headers=$Headers; SkipHttpErrorCheck=$true;
   StatusCodeVariable='responseCode'; TimeoutSec=30; MaximumRedirection=0 }
  if ($null -ne $Payload) {
   $options.ContentType='application/json'
   $options.Body=($Payload | ConvertTo-Json -Depth 6 -Compress)
  }
  $result = Invoke-RestMethod @options
  if ([int]$responseCode -ge 400) {
   $code = if ($result.error -is [string] -and $result.error -match '^[a-z_]{1,80}$') { $result.error } else { 'request_rejected' }
   throw "HTTP $responseCode ($code)"
  }
  return $result
 } catch {
  # Never print raw HTTP responses, request bodies, headers or exception objects.
  if ($_.Exception.Message -match '^HTTP [0-9]{3} \([a-z_]+\)$') { throw $_.Exception.Message }
  throw 'Network or service request failed; no credential values were logged by this script.'
 }
}
try {
 $publishableKey = Read-Host 'Supabase publishable key (project Settings / API keys; never use a secret/service-role key)'
 if ($publishableKey -notmatch '^sb_publishable_' -and $publishableKey -notmatch '^eyJ') {
  throw 'A Supabase publishable key or legacy anon key is required.'
 }
 # Legacy JWT anon keys are accepted only if their untrusted payload says anon;
 # this local safety check is not server authorization.
 if ($publishableKey -match '^eyJ') {
  try {
   $payloadPart=$publishableKey.Split('.')[1].Replace('-','+').Replace('_','/')
   $payloadPart=$payloadPart.PadRight([int]([Math]::Ceiling($payloadPart.Length/4.0)*4),'=')
   $keyClaims=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payloadPart)) | ConvertFrom-Json
   if ($keyClaims.role -ne 'anon') { throw 'not anon' }
  } catch { throw 'Only a publishable or legacy anon key is accepted. Do not enter a service-role key.' }
 }
 $email = Read-Host 'Application administrator email (Supabase Auth user)'
 $password = Read-SecretText 'Application administrator password'
 try {
  $session=Send-Json "$baseUrl/auth/v1/token?grant_type=password" 'POST' @{apikey=$publishableKey} @{email=$email;password=$password}
 } finally { $password=$null }
 if (-not $session.access_token) { throw 'Sign-in failed.' }
 $headers=@{apikey=$publishableKey;Authorization="Bearer $($session.access_token)"}
 $endpoint="$baseUrl/functions/v1/providers/workspaces/$WorkspaceId/$Provider"
 $current=Send-Json $endpoint 'GET' $headers $null
 $generation=if($null -eq $current.connection){0}else{[int]$current.connection.generation}
 if ($Action -eq 'Disconnect') {
  $null=Send-Json $endpoint 'DELETE' $headers @{expected_generation=$generation}
  Write-Output 'Disconnected. The application removed its stored secret; revoke provider credentials separately if needed.'
 } else {
  if ($Provider -eq 'hubspot') {
   $credentials=@{access_token=(Read-SecretText 'HubSpot legacy private-app access token')}
  } else {
   $credentials=@{
    account_sid=(Read-Host 'Twilio live/trial Account SID (AC...)')
    api_key_sid=(Read-Host 'Twilio Standard API Key SID (SK..., US1 region)')
    api_key_secret=(Read-SecretText 'Twilio API Key Secret')
   }
   $webhookToken=Read-SecretText 'Twilio live/trial Auth Token (optional now; Enter to skip)'
   if ($webhookToken.Length -gt 0) { $credentials.auth_token=$webhookToken }
   $webhookToken=$null
  }
  $body=@{expected_generation=$generation;credentials=$credentials}
  $result=Send-Json $endpoint 'PUT' $headers $body
  Write-Output ("Connected {0}; credential generation {1}." -f $Provider,$result.generation)
  Write-Output 'Credential validation succeeded. This does not yet confirm end-to-end calling or HubSpot activity logging.'
 }
} catch {
 Write-Error ("Setup failed: " + $_.Exception.Message) -ErrorAction Continue
 exit 1
} finally {
 if ($session -and $headers) {
  try { $null=Send-Json "$baseUrl/auth/v1/logout?scope=local" 'POST' $headers $null } catch { }
 }
 $credentials=$null;$body=$null;$headers=$null;$session=$null
}
