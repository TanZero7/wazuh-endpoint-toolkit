<#
    Stage 2 -- Point the Wazuh agent at the Sysmon eventchannel.
    Idempotent: checks for an existing <localfile> block before adding one.
#>
[CmdletBinding()]
param(
    [string]$WazuhConf = 'C:\Program Files (x86)\ossec-agent\ossec.conf'
)
$ErrorActionPreference = 'Stop'

function Assert-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this from an elevated (Administrator) PowerShell session."
    }
}
Assert-Elevated

if (-not (Test-Path $WazuhConf)) { throw "ossec.conf not found at $WazuhConf -- is the Wazuh agent installed?" }

$conf = Get-Content $WazuhConf -Raw
if ($conf -match 'Microsoft-Windows-Sysmon/Operational') {
    Write-Host "ossec.conf already references the Sysmon channel -- leaving it alone (idempotent)."
    exit 0
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Copy-Item $WazuhConf "$WazuhConf.$stamp.bak" -Force
Write-Host "Backup: $WazuhConf.$stamp.bak"

$block = @"

  <!-- Sysmon. Added by the Sysmon+Wazuh deployment kit on $(Get-Date -Format 'yyyy-MM-dd') -->
  <localfile>
    <location>Microsoft-Windows-Sysmon/Operational</location>
    <log_format>eventchannel</log_format>
  </localfile>
"@

$idx = $conf.LastIndexOf('</ossec_config>')
if ($idx -lt 0) { throw "No </ossec_config> found -- refusing to guess where to insert." }
$conf = $conf.Substring(0, $idx) + $block + "`r`n" + $conf.Substring($idx)
[IO.File]::WriteAllText($WazuhConf, $conf, (New-Object Text.UTF8Encoding($false)))
Write-Host "Inserted Sysmon localfile block."

Write-Host "`nRestarting WazuhSvc..."
Restart-Service -Name WazuhSvc -Force
(Get-Service WazuhSvc).WaitForStatus('Running', '00:01:00')
Write-Host "WazuhSvc restarted."
