#Requires -Version 7.0
$ErrorActionPreference='Stop'
$scriptPath=Join-Path $PSScriptRoot '../scripts/connect-provider.ps1'
function global:Read-Host { param([string]$Prompt,[switch]$AsSecureString)
 $next=$global:setupAnswers.Dequeue()
 if($AsSecureString){ return ConvertTo-SecureString -String $next -AsPlainText -Force }
 return $next
}
function global:Invoke-RestMethod {
 param($Uri,$Method,$Headers,[switch]$SkipHttpErrorCheck,$StatusCodeVariable,$TimeoutSec,$MaximumRedirection,$ContentType,$Body)
 Set-Variable -Name $StatusCodeVariable -Value 200 -Scope 1
 if($Uri -like '*/auth/v1/token*'){return @{access_token='synthetic-session'}}
 if($Uri -like '*/logout*'){$global:logoutCount++;return $null}
 if($Method -eq 'GET'){return @{connection=$null}}
 if($Method -eq 'PUT'){$global:lastPayload=$Body|ConvertFrom-Json;return @{connected=$true;generation=1}}
 throw 'Unexpected mock request'
}
$global:logoutCount=0
$global:setupAnswers=[System.Collections.Generic.Queue[string]]::new()
@('sb_publishable_synthetic','admin@example.invalid','synthetic-password','pat-synthetic-private-token')|ForEach-Object{$global:setupAnswers.Enqueue($_)}
$resultText=(& $scriptPath -Provider hubspot -WorkspaceId '62000000-0000-0000-0000-000000000001') -join [Environment]::NewLine
if($global:lastPayload.credentials.access_token -ne 'pat-synthetic-private-token' -or $global:lastPayload.expected_generation -ne 0){throw 'Incorrect credential submission'}
if($resultText.Contains('pat-synthetic') -or $resultText.Contains('synthetic-password') -or $resultText.Contains('synthetic-session')){throw 'Secret output leakage'}
$global:setupAnswers=[System.Collections.Generic.Queue[string]]::new()
@('sb_publishable_synthetic','admin@example.invalid','synthetic-password',('AC'+('a'*32)),('SK'+('b'*32)),('c'*32),('d'*32))|ForEach-Object{$global:setupAnswers.Enqueue($_)}
$resultText=(& $scriptPath -Provider twilio -WorkspaceId '62000000-0000-0000-0000-000000000001') -join [Environment]::NewLine
if($global:lastPayload.credentials.api_key_secret -ne ('c'*32) -or $global:lastPayload.credentials.auth_token -ne ('d'*32)){throw 'Twilio payload incorrect'}
if($resultText.Contains('c'*32) -or $resultText.Contains('d'*32)){throw 'Twilio secret output leakage'}
if($global:logoutCount -ne 2){throw 'Refresh sessions not revoked'}
Write-Output 'PASS: mocked HubSpot/Twilio setup, credential payloads, output redaction and local logout'
