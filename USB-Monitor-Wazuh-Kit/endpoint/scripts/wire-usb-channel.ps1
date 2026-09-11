<#
    Enable the Windows event channel USB storage connections are already
    logged to, and wire the Wazuh agent to read it. Idempotent.

    Windows already logs this (Microsoft-Windows-Partition/Diagnostic, event
    ID 1006, fired for every disk including internal ones) -- this just
    turns the channel on if it's disabled and points Wazuh at it. The
    matching rule (server\local_rules_usb.xml) filters to USB only
    (busType=7) and formats it as a readable alert.
#>
[CmdletBinding()]
param(
    [string]$WazuhDir = 'C:\Program Files (x86)\ossec-agent'
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

$channel = 'Microsoft-Windows-Partition/Diagnostic'
Write-Host "== Windows event channel =="
try {
    $log = Get-WinEvent -ListLog $channel -ErrorAction Stop
    if (-not $log.IsEnabled) {
        & wevtutil sl "$channel" /e:true
        Write-Host "Enabled $channel"
    } else {
        Write-Host "Already enabled: $channel (records=$($log.RecordCount))"
    }
} catch {
    throw "Could not access channel $channel -- $($_.Exception.Message)"
}

$ossec = Join-Path $WazuhDir 'ossec.conf'
$conf = Get-Content $ossec -Raw
if ($conf -match [regex]::Escape($channel)) {
    Write-Host "`nossec.conf already references $channel -- leaving it alone (idempotent)."
} else {
    Copy-Item $ossec "$ossec.$(Get-Date -Format yyyyMMdd-HHmmss).bak" -Force
    $block = @"

  <!-- USB storage monitor. Added by the USB-Monitor-Wazuh-Kit on $(Get-Date -Format 'yyyy-MM-dd') -->
  <localfile>
    <location>$channel</location>
    <log_format>eventchannel</log_format>
  </localfile>
"@
    $idx = $conf.LastIndexOf('</ossec_config>')
    if ($idx -lt 0) { throw "No </ossec_config> found -- refusing to guess where to insert." }
    $conf = $conf.Substring(0, $idx) + $block + "`r`n" + $conf.Substring($idx)
    [IO.File]::WriteAllText($ossec, $conf, (New-Object Text.UTF8Encoding($false)))
    Write-Host "`nInserted localfile block for $channel."
}

Write-Host "`nRestarting WazuhSvc..."
Restart-Service -Name WazuhSvc -Force
(Get-Service WazuhSvc).WaitForStatus('Running', '00:01:00')
Write-Host "WazuhSvc restarted."
