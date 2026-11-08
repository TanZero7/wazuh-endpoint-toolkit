<#
    Stage 1 -- Align the Wazuh agent version with the manager.

    Wazuh requires manager version >= agent version. An agent newer than its manager is
    an unsupported configuration and the manager will refuse the connection, so a newer
    agent silently reports nothing.

    THIS SCRIPT REFUSES TO RUN WITHOUT -ManagerVersion.

    That is deliberate. The claim "the manager is 4.12" originated from the user's own
    description of their environment and was never independently verified. Downgrading a
    working agent on the strength of an unverified number is exactly the kind of change
    that is annoying to undo. Confirm it first, on the manager:

        ssh <user>@<manager> "/var/ossec/bin/wazuh-control info"

    then pass what it actually printed:

        .\01-fix-agent-version.ps1 -ManagerVersion 4.12.0

    If the manager turns out to be >= the installed agent, the script exits without
    changing anything.

    client.keys and ossec.conf are backed up and restored, so enrollment survives and
    the agent does not need re-registering on the manager.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Version reported by wazuh-control info on the MANAGER, e.g. 4.12.0')]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$ManagerVersion,

    [switch]$Force
)

. "$PSScriptRoot\lib\common.ps1"
Start-Transcript-Safe -Name '01-fix-agent-version'

try {
    Assert-Elevated

    # --------------------------------------------------------------
    Write-Step 'Compare installed agent against confirmed manager version'

    $verFile = Join-Path $WazuhDir 'VERSION.json'
    if (-not (Test-Path $verFile)) { Stop-WithError "No Wazuh agent found at $WazuhDir" }
    $agentVersion = (Get-Content $verFile -Raw | ConvertFrom-Json).version

    Write-Info "Agent installed here : $agentVersion"
    Write-Info "Manager (confirmed)  : $ManagerVersion"

    $a = [version]$agentVersion
    $m = [version]$ManagerVersion

    if ($a -le $m) {
        Write-Ok "Agent ($a) is not newer than manager ($m). Supported configuration -- nothing to do."
        Write-Info 'If the agent still is not reporting, the cause is elsewhere: enrollment, firewall, or the manager not having the agent registered.'
        return
    }

    Write-Warn "Agent $a is NEWER than manager $m. Unsupported -- the manager will refuse this agent."
    Write-Info "Plan: uninstall $a, install $m, restore enrollment."

    if (-not $Force) {
        $ans = Read-Host "Proceed with downgrade to $m ? [y/N]"
        if ($ans -notmatch '^(y|yes)$') { Write-Info 'Aborted by operator.'; return }
    }

    # --------------------------------------------------------------
    Write-Step 'Back up enrollment and configuration'

    $backupDir = Join-Path $StateDir ("agent-backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    foreach ($f in @('client.keys', 'ossec.conf', 'local_internal_options.conf')) {
        $src = Join-Path $WazuhDir $f
        if (Test-Path $src) {
            Copy-Item $src -Destination $backupDir -Force
            Write-Ok "Backed up $f"
        } else {
            Write-Info "$f not present, skipping"
        }
    }
    Save-State 'agent_backup_dir' $backupDir
    Write-Info "Backup directory: $backupDir"

    # --------------------------------------------------------------
    Write-Step 'Download the matching agent MSI'

    $msiUrl  = "https://packages.wazuh.com/4.x/windows/wazuh-agent-$ManagerVersion-1.msi"
    $msiPath = Join-Path $env:TEMP "wazuh-agent-$ManagerVersion-1.msi"

    Write-Info "URL: $msiUrl"
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing -TimeoutSec 300
    } catch {
        Stop-WithError "Download failed: $($_.Exception.Message). Check that version $ManagerVersion has a published Windows MSI."
    }
    $sizeMb = [math]::Round((Get-Item $msiPath).Length / 1MB, 2)
    Write-Ok "Downloaded $sizeMb MB to $msiPath"

    # --------------------------------------------------------------
    Write-Step 'Stop the agent service'
    $svc = Get-Service -Name 'WazuhSvc' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Stop-Service -Name 'WazuhSvc' -Force
        (Get-Service 'WazuhSvc').WaitForStatus('Stopped', '00:01:00')
        Write-Ok 'WazuhSvc stopped'
    } else {
        Write-Info 'Service already stopped or absent'
    }

    # --------------------------------------------------------------
    Write-Step "Uninstall agent $agentVersion"
    # A straight downgrade install is blocked by MSI ("a newer version is already
    # installed"), so the old product has to come off first.
    $product = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
               Where-Object { $_.DisplayName -eq 'Wazuh Agent' } | Select-Object -First 1

    if ($product) {
        $code = $product.PSChildName
        Write-Info "Product code: $code"
        $p = Start-Process msiexec.exe -ArgumentList "/x $code /qn /norestart /l*v `"$backupDir\uninstall.log`"" -Wait -PassThru
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
            Stop-WithError "Uninstall failed with exit code $($p.ExitCode). See $backupDir\uninstall.log"
        }
        Write-Ok 'Uninstalled'
    } else {
        Write-Warn 'Could not locate the Wazuh Agent product in the uninstall registry; continuing.'
    }

    # --------------------------------------------------------------
    Write-Step "Install agent $ManagerVersion"
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn /norestart /l*v `"$backupDir\install.log`"" -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        Stop-WithError "Install failed with exit code $($p.ExitCode). See $backupDir\install.log"
    }
    Write-Ok 'Installed'

    # --------------------------------------------------------------
    Write-Step 'Restore enrollment and configuration'
    # Restore AFTER install so the fresh MSI defaults are overwritten by the known-good
    # config, and the agent keeps the identity the manager already has registered.
    foreach ($f in @('client.keys', 'ossec.conf', 'local_internal_options.conf')) {
        $src = Join-Path $backupDir $f
        if (Test-Path $src) {
            Copy-Item $src -Destination (Join-Path $WazuhDir $f) -Force
            Write-Ok "Restored $f"
        }
    }

    # --------------------------------------------------------------
    Write-Step 'Start the agent and confirm the version'
    Start-Service -Name 'WazuhSvc'
    (Get-Service 'WazuhSvc').WaitForStatus('Running', '00:01:00')
    Write-Ok 'WazuhSvc running'

    $newVersion = (Get-Content (Join-Path $WazuhDir 'VERSION.json') -Raw | ConvertFrom-Json).version
    if ($newVersion -eq $ManagerVersion) {
        Write-Ok "Agent is now $newVersion, matching the manager."
    } else {
        Write-Warn "Expected $ManagerVersion but VERSION.json reports $newVersion."
    }
    Save-State 'agent_version' $newVersion

    Write-Step 'Give it 30s, then check connectivity'
    Start-Sleep -Seconds 30
    $log = Join-Path $WazuhDir 'ossec.log'
    if (Test-Path $log) {
        $connected = Get-Content $log -Tail 100 | Where-Object { $_ -match 'Connected to the server|Agent is now online' }
        if ($connected) {
            Write-Ok 'Agent reports a connection to the manager:'
            $connected | Select-Object -Last 3 | ForEach-Object { Write-Host "    $_" -ForegroundColor Green }
        } else {
            Write-Warn 'No connection confirmation in the log yet. Recent lines:'
            Get-Content $log -Tail 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            Write-Info 'Verify on the manager with: /var/ossec/bin/agent_control -l'
        }
    }
}
finally {
    Stop-Transcript-Safe
}
