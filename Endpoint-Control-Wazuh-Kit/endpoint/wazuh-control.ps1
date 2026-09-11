<#
  wazuh-control.ps1  --  one switch to PAUSE / RESUME everything Wazuh on
  this workstation, for when you need the machine completely unmonitored for a
  while (heavy work, gaming, privacy) and then want it all back exactly as it was.

  What PAUSE stops (everything this build installed):
    - WazuhSvc          the agent itself: FIM, SCA, syscollector, logcollector,
                        vulnerability inventory, the active-response (YARA) trigger,
                        and the 6-hourly forensic snapshot wodle
    - Suricata IDS      the network capture task + its watchdog + the running process
    - Sysmon64          process/network/registry/file telemetry
  It also sets those services to Manual start and disables the Suricata tasks, so a
  reboot during a pause does NOT silently turn monitoring back on. A marker file
  records that the machine is intentionally paused.

  RESUME puts all of it back: Automatic start, services started, tasks re-enabled.

  WHILE PAUSED, THIS PC IS NOT MONITORED AT ALL and events that happen during the
  pause are not collected (the agent is off, it is not just buffering). That is the
  point of a pause -- use RESUME as soon as the work is done.

  Usage (elevated):
    powershell -ExecutionPolicy Bypass -File wazuh-control.ps1 -Pause
    powershell -ExecutionPolicy Bypass -File wazuh-control.ps1 -Resume
    powershell -ExecutionPolicy Bypass -File wazuh-control.ps1 -Status
#>
[CmdletBinding(DefaultParameterSetName='Status')]
param(
    [Parameter(ParameterSetName='Pause')]  [switch]$Pause,
    [Parameter(ParameterSetName='Resume')] [switch]$Resume,
    [Parameter(ParameterSetName='Status')] [switch]$Status
)
$ErrorActionPreference = 'Continue'
$marker = 'C:\ProgramData\wazuh-toolkit\wazuh-paused.marker'
New-Item -ItemType Directory -Force -Path (Split-Path $marker) | Out-Null

function Assert-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this from an elevated (Administrator) PowerShell session."
    }
}

function Show-Status {
    Write-Host "==== WAZUH TOOLKIT Wazuh monitoring status ====" -ForegroundColor Cyan
    $paused = Test-Path $marker
    Write-Host ("State        : {0}" -f $(if ($paused) { "PAUSED (since $((Get-Content $marker -Raw).Trim()))" } else { "ACTIVE" })) -ForegroundColor $(if($paused){'Yellow'}else{'Green'})
    foreach ($svc in 'WazuhSvc','Sysmon64') {
        $s = Get-Service $svc -ErrorAction SilentlyContinue
        if ($s) { "{0,-12} : {1}  (startup: {2})" -f $svc, $s.Status, $s.StartType }
        else    { "{0,-12} : not installed" -f $svc }
    }
    $su = Get-Process suricata -ErrorAction SilentlyContinue
    "Suricata     : " + $(if ($su) { "running (pid $($su.Id))" } else { "stopped" })
    Get-ScheduledTask -TaskName 'Suricata IDS','Suricata IDS Watchdog' -ErrorAction SilentlyContinue |
        ForEach-Object { "  task {0,-22} {1}" -f $_.TaskName, $_.State }
}

if ($Pause) {
    Assert-Elevated
    Write-Host "Pausing all Wazuh monitoring on this workstation..." -ForegroundColor Yellow

    # Suricata: stop watchdog first so it can't restart capture, then the task, then
    # kill the process and VERIFY it's actually gone (retry).
    Disable-ScheduledTask -TaskName 'Suricata IDS Watchdog' -EA SilentlyContinue | Out-Null
    Stop-ScheduledTask    -TaskName 'Suricata IDS Watchdog' -EA SilentlyContinue
    Disable-ScheduledTask -TaskName 'Suricata IDS' -EA SilentlyContinue | Out-Null
    Stop-ScheduledTask    -TaskName 'Suricata IDS' -EA SilentlyContinue
    for ($i=0; $i -lt 10 -and (Get-Process suricata -EA SilentlyContinue); $i++) {
        Get-Process suricata -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
        Start-Sleep 1
    }
    Write-Host ("  Suricata: {0}, tasks disabled" -f $(if (Get-Process suricata -EA SilentlyContinue) {'STILL RUNNING (could not kill)'} else {'stopped'}))

    # WazuhSvc: the agent that collects + ships everything. Stopping this alone means
    # nothing on this PC is reported to the SOC. Set Manual, stop, verify, kill-fallback.
    if (Get-Service WazuhSvc -EA SilentlyContinue) {
        Set-Service  WazuhSvc -StartupType Manual -EA SilentlyContinue
        Stop-Service WazuhSvc -Force -EA SilentlyContinue
        for ($i=0; $i -lt 10 -and (Get-Service WazuhSvc).Status -ne 'Stopped'; $i++) { Start-Sleep 1 }
        if ((Get-Service WazuhSvc).Status -ne 'Stopped') {
            & sc.exe stop WazuhSvc *> $null; Start-Sleep 2
            Get-Process wazuh-agent -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue; Start-Sleep 2
        }
        Write-Host ("  WazuhSvc: {0} + Manual start" -f $(if ((Get-Service WazuhSvc).Status -eq 'Stopped') {'stopped'} else {'STILL RUNNING'}))
    }

    # Sysmon64: tamper-protected (runs as a protected process), so it cannot be
    # stopped by service/kill even as admin - only Sysmon64.exe -u removes it. We do
    # NOT uninstall it here: with WazuhSvc stopped above, nothing collects or ships
    # Sysmon's events anyway, so leaving it running is harmless (~0.6% CPU, no network)
    # and avoids an uninstall/reinstall that could fail. This is expected, not an error.
    if (Get-Service Sysmon64 -EA SilentlyContinue) {
        Stop-Service Sysmon64 -Force -EA SilentlyContinue
        Start-Sleep 2
        if ((Get-Service Sysmon64 -EA SilentlyContinue).Status -eq 'Stopped') {
            Set-Service Sysmon64 -StartupType Manual -EA SilentlyContinue
            Write-Host "  Sysmon64: stopped"
        } else {
            Write-Host "  Sysmon64: left running (tamper-protected; harmless - with the agent stopped none of its events are collected or sent)"
        }
    }
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Set-Content $marker -Encoding ascii
    Write-Host "`nPAUSED. This PC is now unmonitored. Run -Resume when done." -ForegroundColor Yellow
    Write-Host ""
    Show-Status
}
elseif ($Resume) {
    Assert-Elevated
    Write-Host "Resuming all Wazuh monitoring..." -ForegroundColor Green

    if (Get-Service WazuhSvc -EA SilentlyContinue) {
        Set-Service   WazuhSvc -StartupType Automatic -EA SilentlyContinue
        Start-Service WazuhSvc -EA SilentlyContinue
        Write-Host "  WazuhSvc started + set to Automatic start"
    }
    $sm = Get-Service Sysmon64 -EA SilentlyContinue
    if ($sm) {
        Set-Service Sysmon64 -StartupType Automatic -EA SilentlyContinue
        if ($sm.Status -ne 'Running') { Start-Service Sysmon64 -EA SilentlyContinue; Write-Host "  Sysmon64 started" }
        else { Write-Host "  Sysmon64 already running (was never stopped - tamper-protected)" }
    }
    Enable-ScheduledTask -TaskName 'Suricata IDS' -EA SilentlyContinue | Out-Null
    Enable-ScheduledTask -TaskName 'Suricata IDS Watchdog' -EA SilentlyContinue | Out-Null
    Start-ScheduledTask  -TaskName 'Suricata IDS' -EA SilentlyContinue
    Write-Host "  Suricata capture + watchdog re-enabled and started"

    Remove-Item $marker -Force -EA SilentlyContinue
    Start-Sleep 12
    Write-Host "`nRESUMED." -ForegroundColor Green
    Write-Host ""
    Show-Status
}
else {
    Show-Status
}
