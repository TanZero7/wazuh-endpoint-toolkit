<#
    Install the CDAC Security Baseline SCA policy onto a Wazuh agent, enable
    remote-command execution for SCA (several of the 30 controls can only be
    checked by running a command, e.g. `net accounts`), and wire agent.conf
    (local copy) to load it. Idempotent.
#>
[CmdletBinding()]
param(
    [string]$WazuhDir = 'C:\Program Files (x86)\ossec-agent',
    [string]$KitRoot  = (Split-Path -Parent $PSScriptRoot)
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

$scaDir = Join-Path $WazuhDir 'ruleset\sca'
New-Item -ItemType Directory -Force -Path $scaDir | Out-Null
Copy-Item (Join-Path $KitRoot 'config\cdac_win_baseline.yml') (Join-Path $scaDir 'cdac_win_baseline.yml') -Force
Write-Host "Policy deployed: $scaDir\cdac_win_baseline.yml"

Write-Host "`n== enabling sca.remote_commands (required for the ~15 command-based checks) =="
$lio = Join-Path $WazuhDir 'local_internal_options.conf'
$cur = if (Test-Path $lio) { Get-Content $lio -Raw } else { '' }
if ($cur -notmatch 'sca\.remote_commands\s*=\s*1') {
    if (Test-Path $lio) { Copy-Item $lio "$lio.$(Get-Date -Format yyyyMMdd-HHmmss).bak" }
    Add-Content -Path $lio -Value "`r`n# CDAC baseline kit`r`nsca.remote_commands=1" -Encoding ascii
    Write-Host "added sca.remote_commands=1"
} else {
    Write-Host "already set"
}

$ossec = Join-Path $WazuhDir 'ossec.conf'
$conf = Get-Content $ossec -Raw
if ($conf -match 'cdac_win_baseline') {
    Write-Host "`nossec.conf already references the CDAC policy -- leaving it alone (idempotent)."
} else {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item $ossec "$ossec.$stamp.bak" -Force
    $block = @"

  <!-- CDAC Security Baseline. Added by the CDAC-Baseline-Wazuh-Kit on $(Get-Date -Format 'yyyy-MM-dd') -->
  <sca>
    <policies>
      <policy>ruleset/sca/cdac_win_baseline.yml</policy>
    </policies>
  </sca>
"@
    $idx = $conf.LastIndexOf('</ossec_config>')
    if ($idx -lt 0) { throw "No </ossec_config> found -- refusing to guess where to insert." }
    $conf = $conf.Substring(0, $idx) + $block + "`r`n" + $conf.Substring($idx)
    [IO.File]::WriteAllText($ossec, $conf, (New-Object Text.UTF8Encoding($false)))
    Write-Host "`nInserted <sca><policies> block referencing the CDAC policy."
}

Write-Host "`nRestarting WazuhSvc (required to load sca.remote_commands and the new policy)..."
Restart-Service -Name WazuhSvc -Force
(Get-Service WazuhSvc).WaitForStatus('Running', '00:01:00')
Write-Host "WazuhSvc restarted."
