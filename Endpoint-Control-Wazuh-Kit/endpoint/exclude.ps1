<#
  exclude.ps1  --  mark a folder OFF-LIMITS to every Wazuh capability on this
  workstation. An excluded folder is not monitored, scanned, hashed, or listed by
  any integration this build installed. (Nothing in this build ever *deletes* files
  in the first place -- FIM, YARA, VirusTotal and the hash blocklist only ever
  alert -- so your files are never touched regardless; exclusion just also stops
  them being watched/scanned at all.)

  What an exclusion covers, per capability:
    - FIM (file integrity)        <ignore> added -> folder not watched, no change alerts
    - VirusTotal / Hash blocklist  both are triggered by FIM -> excluded automatically
    - YARA                         AR script skips any file under an excluded folder
    - Forensic snapshot            excluded files left out of the snapshot
    - Sysmon                       nothing to do: the SwiftOnSecurity config logs only
                                   specific file patterns (executables, Startup, ...), so a
                                   data/game folder is not file-logged to begin with
  Process execution and network activity FROM the folder stay visible on purpose
  (a folder that can run code invisibly would be a security hole). Say so if you
  want those excluded too.

  Single source of truth: C:\ProgramData\wazuh-toolkit\exclusions.txt (one absolute folder
  path per line). Edit it by hand or use this tool; either way run -Apply after.

  Usage (elevated):
    exclude.ps1 -Add "D:\Games\CS2"
    exclude.ps1 -Remove "D:\Games\CS2"
    exclude.ps1 -List
    exclude.ps1 -Apply        # re-push the current list to all configs
#>
[CmdletBinding(DefaultParameterSetName='List')]
param(
    [Parameter(ParameterSetName='Add')]    [string]$Add,
    [Parameter(ParameterSetName='Remove')] [string]$Remove,
    [Parameter(ParameterSetName='List')]   [switch]$List,
    [Parameter(ParameterSetName='Apply')]  [switch]$Apply,
    [string]$WazuhConf   = 'C:\Program Files (x86)\ossec-agent\ossec.conf'
)
$ErrorActionPreference = 'Stop'
$exclFile = 'C:\ProgramData\wazuh-toolkit\exclusions.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $exclFile) | Out-Null
if (-not (Test-Path $exclFile)) {
    "# WAZUH TOOLKIT exclusions - one absolute folder path per line. Lines starting with # are ignored." | Set-Content $exclFile -Encoding ascii
}

function Assert-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this from an elevated (Administrator) PowerShell session."
    }
}
function Get-Excl { Get-Content $exclFile | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $_.Trim().TrimEnd('\') } | Where-Object { $_ } }
function Save-Excl($list) {
    $hdr = '# WAZUH TOOLKIT exclusions - one absolute folder path per line. Lines starting with # are ignored.'
    @($hdr) + ($list | Sort-Object -Unique) | Set-Content $exclFile -Encoding ascii
}

# ---- FIM: rewrite a dedicated, marked <ossec_config> block of <ignore> entries ----
function Apply-FIM($list) {
    $startM = '<!-- WAZUHKIT-EXCLUSIONS-START (managed by exclude.ps1; do not edit by hand) -->'
    $endM   = '<!-- WAZUHKIT-EXCLUSIONS-END -->'
    $raw = Get-Content $WazuhConf -Raw
    Copy-Item $WazuhConf "$WazuhConf.bak-excl-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force
    # strip any previous managed block
    $raw = [regex]::Replace($raw, [regex]::Escape($startM) + '[\s\S]*?' + [regex]::Escape($endM), '', 1).TrimEnd() + "`r`n"
    if ($list.Count -gt 0) {
        $ignores = ($list | ForEach-Object { "    <ignore>$_</ignore>" }) -join "`r`n"
        $block = @"
$startM
<ossec_config>
  <syscheck>
$ignores
  </syscheck>
</ossec_config>
$endM
"@
        $raw = $raw.TrimEnd() + "`r`n`r`n" + $block + "`r`n"
    }
    [IO.File]::WriteAllText($WazuhConf, $raw, (New-Object Text.UTF8Encoding($false)))
}

function Apply-All {
    Assert-Elevated
    $list = @(Get-Excl)
    Write-Host "Applying $($list.Count) folder exclusion(s) across all capabilities..."
    Apply-FIM $list
    Write-Host "  FIM <ignore> written (covers FIM + VirusTotal + hash blocklist, which are all FIM-triggered)"
    Write-Host "  YARA + forensic snapshot read $exclFile at runtime (skip excluded paths; no restart needed)"
    Write-Host "  Sysmon: its SwiftOnSecurity config logs only specific file patterns (executables, Startup,"
    Write-Host "          etc.), so a data/game folder is not file-logged to begin with - no Sysmon change"
    Write-Host "          needed. Executable/script creation and process execution stay visible by design."
    Write-Host "Restarting WazuhSvc to apply FIM changes..."
    Restart-Service WazuhSvc -Force
    (Get-Service WazuhSvc).WaitForStatus('Running','00:01:00')
    Write-Host "Done."
}

switch ($PSCmdlet.ParameterSetName) {
    'Add' {
        $p = $Add.Trim().TrimEnd('\')
        if (-not [IO.Path]::IsPathRooted($p)) { throw "Give an absolute path, e.g. D:\Games\CS2" }
        $cur = @(Get-Excl)
        if ($cur -contains $p) { Write-Host "'$p' is already excluded." }
        else { Save-Excl ($cur + $p); Write-Host "Added '$p'." }
        Apply-All
    }
    'Remove' {
        $p = $Remove.Trim().TrimEnd('\')
        $cur = @(Get-Excl)
        Save-Excl ($cur | Where-Object { $_ -ne $p })
        Write-Host "Removed '$p' (if it was present)."
        Apply-All
    }
    'Apply' { Apply-All }
    default {
        Write-Host "Current WAZUH TOOLKIT exclusions ($exclFile):" -ForegroundColor Cyan
        $cur = @(Get-Excl)
        if ($cur.Count -eq 0) { Write-Host "  (none)" } else { $cur | ForEach-Object { "  $_" } }
        Write-Host "`nAdd one with:  exclude.ps1 -Add `"D:\path\to\folder`""
    }
}
