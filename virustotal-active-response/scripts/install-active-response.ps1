<#
    [addition -- not in the original kit]

    Deploy remove-threat.exe -- the Active Response executable that deletes
    a file once VirusTotal (rule 87105) flags it as malicious -- to this
    agent's active-response\bin folder, and verify it lands in place.

    IMPORTANT -- this script does NOT build remove-threat.exe. It copies a
    file called remove-threat.exe that must already exist next to this
    script, in ..\bin\remove-threat.exe (i.e.
    virustotal-active-response\bin\remove-threat.exe). That file is
    deliberately not committed to this repository -- see
    bin\PUT-remove-threat.exe-HERE.txt for how to build it. Put a copy there once (built from
    remove-threat.py with `pyinstaller -F remove-threat.py`) and every
    endpoint you run this script against gets the same, already-verified
    binary -- no rebuilding per machine.

    Server side (the <command>/<active-response> block that actually calls
    this) is server\add-virustotal-active-response.sh -- run that once on
    the manager, this once per endpoint.
#>
[CmdletBinding()]
param(
    [string]$WazuhDir = 'C:\Program Files (x86)\ossec-agent',
    [string]$SourceExe = ''
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

if ([string]::IsNullOrEmpty($SourceExe)) {
    $SourceExe = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\remove-threat.exe'
}
if (-not (Test-Path $SourceExe)) {
    throw "remove-threat.exe not found at $SourceExe. Build it once with 'pyinstaller -F remove-threat.py' and place the result at virustotal-active-response\bin\remove-threat.exe (or pass -SourceExe), then re-run this script. See bin\PUT-remove-threat.exe-HERE.txt for details."
}

$arDir = Join-Path $WazuhDir 'active-response\bin'
if (-not (Test-Path $arDir)) { throw "active-response\bin not found under $WazuhDir -- is this really a Wazuh agent install?" }

$dest = Join-Path $arDir 'remove-threat.exe'
Write-Host "Installing $dest ..."
Copy-Item $SourceExe $dest -Force

if (-not (Test-Path $dest)) { throw "Copy appeared to succeed but $dest is not present." }
$size = (Get-Item $dest).Length
Write-Host "[OK] remove-threat.exe installed ($size bytes)."

Write-Host "`nNothing to restart on the agent side for this step -- the manager"
Write-Host "decides when to invoke it, once virustotal/add-virustotal-active-response.sh"
Write-Host "(wazuh-manager-toolkit) has been run there. Fire-test with an EICAR file and watch for rule 657"
Write-Host "(active response fired) followed by 553 (file deleted) in alerts.json."
