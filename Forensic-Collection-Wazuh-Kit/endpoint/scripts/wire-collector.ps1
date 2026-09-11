<#
    Deploy the forensic collector script into the Wazuh agent, register it as
    a <wodle name="command"> running every N hours, and enable
    wazuh_command.remote_commands (required for any manager-pushed command
    wodle). Idempotent.
#>
[CmdletBinding()]
param(
    [string]$WazuhDir  = 'C:\Program Files (x86)\ossec-agent',
    [string]$KitRoot   = (Split-Path -Parent $PSScriptRoot),
    [string]$Interval  = '6h'
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
Copy-Item (Join-Path $KitRoot 'scripts\forensic-collect.ps1') (Join-Path $bin 'forensic-collect.ps1') -Force
Write-Host "Collector deployed: $bin\forensic-collect.ps1"

New-Item -ItemType Directory -Force -Path 'C:\ProgramData\wazuh-toolkit\forensics' | Out-Null

Write-Host "`n== enabling wazuh_command.remote_commands =="
$lio = Join-Path $WazuhDir 'local_internal_options.conf'
$cur = if (Test-Path $lio) { Get-Content $lio -Raw } else { '' }
if ($cur -notmatch 'wazuh_command\.remote_commands\s*=\s*1') {
    if (Test-Path $lio) { Copy-Item $lio "$lio.$(Get-Date -Format yyyyMMdd-HHmmss).bak" }
    Add-Content -Path $lio -Value "`r`n# Forensic collection kit`r`nwazuh_command.remote_commands=1" -Encoding ascii
    Write-Host "added"
} else { Write-Host "already set" }

$ossec = Join-Path $WazuhDir 'ossec.conf'
$conf = Get-Content $ossec -Raw
if ($conf -match 'wazuh-toolkit-forensic-snapshot') {
    Write-Host "`nossec.conf already has the forensic wodle -- leaving it alone (idempotent)."
} else {
    Copy-Item $ossec "$ossec.$(Get-Date -Format yyyyMMdd-HHmmss).bak" -Force
    $block = @"

  <!-- WAZUH TOOLKIT forensic snapshot. Added by the Forensic-Collection-Wazuh-Kit on $(Get-Date -Format 'yyyy-MM-dd') -->
  <wodle name="command">
    <disabled>no</disabled>
    <tag>wazuh-toolkit-forensic-snapshot</tag>
    <command>PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "$bin\forensic-collect.ps1"</command>
    <interval>$Interval</interval>
    <run_on_start>yes</run_on_start>
    <ignore_output>no</ignore_output>
    <timeout>180</timeout>
  </wodle>
"@
    $idx = $conf.LastIndexOf('</ossec_config>')
    if ($idx -lt 0) { throw "No </ossec_config> found -- refusing to guess where to insert." }
    $conf = $conf.Substring(0, $idx) + $block + "`r`n" + $conf.Substring($idx)
    [IO.File]::WriteAllText($ossec, $conf, (New-Object Text.UTF8Encoding($false)))
    Write-Host "`nInserted wodle command block (interval=$Interval, run_on_start=yes)."
}

Write-Host "`nRestarting WazuhSvc..."
Restart-Service -Name WazuhSvc -Force
(Get-Service WazuhSvc).WaitForStatus('Running', '00:01:00')
Write-Host "WazuhSvc restarted. The collector will run immediately (run_on_start=yes), then every $Interval."
