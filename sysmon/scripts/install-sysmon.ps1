<#
    Stage 1 -- Install Sysmon with the SwiftOnSecurity config, or update the
    config on an existing install. Idempotent: safe to re-run.

    Source of truth for both downloads is fetched at run time from their
    official homes:
      - Sysmon itself:   Microsoft Sysinternals (download.sysinternals.com)
      - Sysmon config:   SwiftOnSecurity/sysmon-config on GitHub (open source,
                          the de-facto standard baseline config; well commented,
                          moderate noise, actively maintained)
#>
[CmdletBinding()]
param(
    [string]$InstallDir  = 'C:\Program Files\Sysmon',
    [string]$ConfigUrl   = 'https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml',
    [string]$SysmonUrl   = 'https://download.sysinternals.com/files/Sysmon.zip',
    [switch]$ConfigOnly
)
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Assert-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this from an elevated (Administrator) PowerShell session."
    }
}
Assert-Elevated

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$exe    = Join-Path $InstallDir 'Sysmon64.exe'
$config = Join-Path $InstallDir 'sysmonconfig.xml'

Write-Host "== Sysmon binary =="
if (-not (Test-Path $exe)) {
    $zip = Join-Path $InstallDir 'Sysmon.zip'
    Write-Host "Downloading Sysmon from $SysmonUrl"
    Invoke-WebRequest -Uri $SysmonUrl -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $InstallDir -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $exe)) { throw "Sysmon64.exe missing after extraction" }
    Write-Host "OK: $exe"
} else {
    Write-Host "already present: $exe"
}

Write-Host "`n== Sysmon config (SwiftOnSecurity) =="
Write-Host "Downloading config from $ConfigUrl"
Invoke-WebRequest -Uri $ConfigUrl -OutFile $config -UseBasicParsing
Write-Host ("config: {0} bytes" -f (Get-Item $config).Length)

if ($ConfigOnly) {
    & $exe -c $config
    Write-Host "`nConfig updated on existing install."
    exit 0
}

Write-Host "`n== install / update service =="
$svc = Get-Service -Name Sysmon64,Sysmon -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "Service already installed ($($svc.Name)) -- applying config only"
    & $exe -c $config
} else {
    Write-Host "Installing Sysmon service with config (-accepteula)"
    & $exe -accepteula -i $config
}

Start-Sleep 3
Write-Host "`n== result =="
Get-Service -Name Sysmon64,Sysmon -ErrorAction SilentlyContinue | Select-Object Name,Status,StartType | Format-Table -AutoSize
