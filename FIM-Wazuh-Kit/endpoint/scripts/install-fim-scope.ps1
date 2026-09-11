<#
    Add Desktop + Downloads (all user profiles) to Wazuh FIM, realtime,
    with new-file alerting on. Idempotent.

    Deliberately realtime, NOT whodata: whodata sets a SACL on every
    wildcard-expanded path, including Windows service/virtual profiles
    (TEMP.Font Driver Host, UMFD-0, etc.) that exist on some machines -- this
    was measured to stall the first-run FIM baseline scan from ~1 minute to
    2.5+ minutes on a real deployment, for no detection benefit on those
    paths. "Who changed it" is available from Sysmon (EID 11) if that kit is
    also installed, without paying the whodata cost here.
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

$ossec = Join-Path $WazuhDir 'ossec.conf'
$conf = Get-Content $ossec -Raw
if ($conf -match [regex]::Escape('C:\Users\*\Desktop')) {
    Write-Host "ossec.conf already has this FIM scope -- leaving it alone (idempotent)."
} else {
    Copy-Item $ossec "$ossec.$(Get-Date -Format yyyyMMdd-HHmmss).bak" -Force
    $block = @"

  <!-- WAZUH TOOLKIT standard FIM scope. Added by the FIM-Wazuh-Kit on $(Get-Date -Format 'yyyy-MM-dd') -->
  <syscheck>
    <alert_new_files>yes</alert_new_files>
    <directories check_all="yes" realtime="yes">C:\Users\*\Desktop</directories>
    <directories check_all="yes" realtime="yes">C:\Users\*\Downloads</directories>
    <ignore type="sregex">\.tmp$|\.temp$|\.crdownload$|\.part$|\.partial$|\.~lock|desktop\.ini$|thumbs\.db$</ignore>
    <max_eps>100</max_eps>
  </syscheck>
"@
    $idx = $conf.LastIndexOf('</ossec_config>')
    if ($idx -lt 0) { throw "No </ossec_config> found -- refusing to guess where to insert." }
    $conf = $conf.Substring(0, $idx) + $block + "`r`n" + $conf.Substring($idx)
    [IO.File]::WriteAllText($ossec, $conf, (New-Object Text.UTF8Encoding($false)))
    Write-Host "Inserted FIM scope block."
}

Write-Host "`nRestarting WazuhSvc (triggers a fresh baseline scan -- can take 1-3 minutes on a busy machine)..."
Restart-Service -Name WazuhSvc -Force
(Get-Service WazuhSvc).WaitForStatus('Running', '00:01:00')
Write-Host "WazuhSvc restarted. Realtime monitoring activates once the baseline scan finishes -- check ossec.log for 'Real-time file integrity monitoring started'."
