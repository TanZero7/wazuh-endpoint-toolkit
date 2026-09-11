<#
    Stage 2 -- Deploy the YARA active-response scripts into the Wazuh agent's
    active-response\bin\, wire the results log into ossec.conf, and restart
    the agent. Idempotent.

    This is the ENDPOINT half. The manager also needs the matching
    <command>/<active-response> block added to ossec.conf and the rules file
    installed -- see server\INSTALL.md. Both halves are required; this script
    alone does nothing until the server side is done too.
#>
[CmdletBinding()]
param(
    [string]$WazuhDir  = 'C:\Program Files (x86)\ossec-agent',
    [string]$KitRoot   = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'

function Assert-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this from an elevated (Administrator) PowerShell session."
    }
}
Assert-Elevated

if (-not (Test-Path $WazuhDir)) { throw "Wazuh agent not found at $WazuhDir" }

$bin = Join-Path $WazuhDir 'active-response\bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null
Copy-Item (Join-Path $KitRoot 'active-response\yara-scan.ps1')  (Join-Path $bin 'yara-scan.ps1')  -Force
Copy-Item (Join-Path $KitRoot 'active-response\yara-scan.cmd') (Join-Path $bin 'yara-scan.cmd') -Force
Write-Host "Deployed yara-scan.ps1 / yara-scan.cmd to $bin"

$resultsDir = 'C:\ProgramData\wazuh-toolkit\yara'
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
$resultsLog = Join-Path $resultsDir 'yara-results.log'
if (-not (Test-Path $resultsLog)) { New-Item -ItemType File -Path $resultsLog | Out-Null }

$ossec = Join-Path $WazuhDir 'ossec.conf'
$conf = Get-Content $ossec -Raw
if ($conf -match [regex]::Escape('yara-results.log')) {
    Write-Host "ossec.conf already references yara-results.log -- leaving it alone (idempotent)."
} else {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item $ossec "$ossec.$stamp.bak" -Force
    $block = @"

  <!-- YARA results. Added by the YARA+Wazuh deployment kit on $(Get-Date -Format 'yyyy-MM-dd') -->
  <localfile>
    <log_format>json</log_format>
    <location>C:\ProgramData\wazuh-toolkit\yara\yara-results.log</location>
  </localfile>
"@
    $idx = $conf.LastIndexOf('</ossec_config>')
    if ($idx -lt 0) { throw "No </ossec_config> found -- refusing to guess where to insert." }
    $conf = $conf.Substring(0, $idx) + $block + "`r`n" + $conf.Substring($idx)
    [IO.File]::WriteAllText($ossec, $conf, (New-Object Text.UTF8Encoding($false)))
    Write-Host "Inserted yara-results.log localfile block."
}

Write-Host "`nRestarting WazuhSvc..."
Restart-Service -Name WazuhSvc -Force
(Get-Service WazuhSvc).WaitForStatus('Running', '00:01:00')
Write-Host "WazuhSvc restarted."
Write-Host "`nNOTE: the manager side (server\INSTALL.md) must also be done before this does anything."
