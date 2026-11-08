<#
    Stage 3 -- Configure suricata.yaml, validate it, and run Suricata continuously.

    Design decisions worth knowing before you read the code:

    * The capture interface is passed on the COMMAND LINE (-i \Device\NPF_{GUID}), not
      written into suricata.yaml. The NPF GUID is different on every machine, so keeping
      it out of the YAML means the same suricata.yaml deploys unchanged to every endpoint
      and only the service definition is machine-specific.

    * The eve-log block is replaced WHOLESALE rather than line-patched. Line-by-line
      regex surgery on a nested YAML list is how these scripts usually break; swapping a
      whole indentation-delimited block is predictable.

    * Every edit is followed by "suricata -T", which is the real safety net. If the
      config does not validate, the script stops before touching the service.

    * Running as a service: Suricata's own --service-install is tried first. If this
      build does not support it, the script falls back to a SYSTEM scheduled task at
      startup, which needs no third-party supervisor (no NSSM dependency).
#>

[CmdletBinding()]
param(
    [string]$InterfaceName,       # override auto-selection, e.g. 'Wi-Fi'
    [string]$HomeNet,             # override derived subnet, e.g. '192.168.1.0/24'
    [switch]$SkipStart
)

. "$PSScriptRoot\lib\common.ps1"
Start-Transcript-Safe -Name '03-configure-suricata'

try {
    Assert-Elevated

    if (-not (Test-Path $SuricataYaml)) { Stop-WithError "suricata.yaml not found at $SuricataYaml. Run 02-install-suricata.ps1 first." }

    # --------------------------------------------------------------
    Write-Step 'Resolve capture interface'
    $iface = Get-CaptureInterface -PreferredName $InterfaceName
    Write-Ok  "Interface : $($iface.Name) -- $($iface.Description)"
    Write-Info "NPF device: $($iface.NpfDevice)"
    Write-Info "IPv4      : $($iface.IPv4)/$($iface.PrefixLength)"

    if (-not $HomeNet) {
        if ($iface.IPv4) { $HomeNet = Get-SubnetCidr -IPv4 $iface.IPv4 -PrefixLength $iface.PrefixLength }
        else { Stop-WithError 'Cannot derive HOME_NET: interface has no IPv4. Pass -HomeNet explicitly.' }
    }
    Write-Ok "HOME_NET  : $HomeNet"
    Save-State 'home_net'   $HomeNet
    Save-State 'npf_device' $iface.NpfDevice
    Save-State 'iface_name' $iface.Name

    # --------------------------------------------------------------
    Write-Step 'Back up the pristine configuration'
    $orig = "$SuricataYaml.orig"
    if (-not (Test-Path $orig)) {
        Copy-Item $SuricataYaml $orig -Force
        Write-Ok "Saved pristine copy to $orig"
    } else {
        Write-Info "Pristine copy already exists at $orig -- patching from it for a clean, idempotent result"
    }
    # Always patch from the pristine copy so repeated runs cannot compound edits.
    $lines = @(Get-Content $orig)

    # --------------------------------------------------------------
    Write-Step 'Patch address groups'

    # HOME_NET scoped to the local subnet rather than a single /32: this is a DHCP laptop
    # and a /32 would silently stop matching after a lease change.
    $lines = $lines | ForEach-Object {
        if ($_ -match '^\s*HOME_NET:') { ($_ -replace '(^\s*HOME_NET:\s*).*$', "`$1`"[$HomeNet]`"") }
        elseif ($_ -match '^\s*EXTERNAL_NET:') { ($_ -replace '(^\s*EXTERNAL_NET:\s*).*$', '$1"any"') }
        else { $_ }
    }
    Write-Ok "HOME_NET = [$HomeNet]"
    Write-Ok 'EXTERNAL_NET = "any"  (matches the official Wazuh PoC; broader matching, more alerts)'

    # --------------------------------------------------------------
    Write-Step 'Patch rule paths'
    # Forward slashes throughout: valid on Windows and avoids YAML backslash escaping.
    $lines = $lines | ForEach-Object {
        if ($_ -match '^\s*default-rule-path:') { 'default-rule-path: C:/Program Files/Suricata/rules' } else { $_ }
    }
    # Suricata on Windows does NOT expand globs in rule-files -- "*.rules" fails with
    # "opening rule file ...\*.rules: Invalid argument". The official Wazuh PoC uses the
    # glob because it works on Linux. Here the list has to be enumerated explicitly.
    # Consequence: after refreshing signatures (02 -RefreshRulesOnly), re-run THIS script
    # so any newly-added rule file gets listed. 05-verify.ps1 warns if they drift apart.
    $ruleFileNames = @(Get-ChildItem $SuricataRuleDir -Filter '*.rules' -File |
                       Sort-Object Name | ForEach-Object { "  - $($_.Name)" })
    if ($ruleFileNames.Count -eq 0) { Stop-WithError "No .rules files in $SuricataRuleDir. Run 02-install-suricata.ps1 first." }

    $newRuleFiles = @('rule-files:') + $ruleFileNames
    $patched = Set-YamlBlock -Lines $lines -KeyPattern '^rule-files:' -Replacement $newRuleFiles
    if ($null -eq $patched) { Stop-WithError 'Could not find the rule-files block in suricata.yaml.' }
    $lines = $patched
    Write-Ok "default-rule-path -> C:/Program Files/Suricata/rules"
    Write-Ok "rule-files -> $($ruleFileNames.Count) files listed explicitly (no glob; Windows Suricata cannot expand one)"

    # --------------------------------------------------------------
    Write-Step 'Disable checksum validation (NIC offload workaround)'
    #
    # Modern NICs compute TCP/IP checksums in hardware on transmit. Suricata captures
    # outbound packets BEFORE the NIC fills the checksum in, sees zeros, and fires
    # "SURICATA TCPv4 invalid checksum" / "IPv4 invalid checksum" on essentially every
    # outbound packet. Measured on this host before the fix: 1832 of 1835 alerts were
    # this artifact, at ~6 KB each, which alone was ~14 GB/day of pure noise.
    #
    # suricata.log flags the cause at startup:
    #   "win32-syscall: NIC offloading ... Checksum IPv4 Rx: 0 Tx: 1"
    # and suricata.yaml's own comments describe the same trap.
    #
    # "auto" is supposed to detect this statistically but does not reliably do so on
    # Windows/Npcap, so it is set explicitly. Nothing of value is lost: genuinely corrupt
    # packets are dropped by the receiving stack anyway, and this is an IDS, not a
    # network-fault monitor.
    $pcapBlock = @(
        'pcap:',
        '  - interface: default',
        '    checksum-checks: no'
    )
    $patched = Set-YamlBlock -Lines $lines -KeyPattern '^pcap:' -Replacement $pcapBlock
    if ($null -eq $patched) { Stop-WithError 'Could not find the pcap block in suricata.yaml.' }
    $lines = $patched
    Write-Ok 'pcap: interface default, checksum-checks: no'

    # The stream engine performs its own checksum validation and would otherwise refuse
    # to reassemble every outbound flow, silently crippling app-layer detection.
    $lines = $lines | ForEach-Object {
        if ($_ -match '^\s{2}checksum-validation:\s*yes') {
            '  checksum-validation: no      # was yes; disabled for NIC checksum offload'
        } else { $_ }
    }
    Write-Ok 'stream: checksum-validation: no'

    # --------------------------------------------------------------
    Write-Step 'Install threshold.config'
    # Suricata looks for this regardless of whether threshold-file is set, and warns on
    # every start when it is absent. It also carries suppressions for the checksum
    # decoder events as a backstop to the config fix above.
    $thresholdSrc = Join-Path $KitRoot 'config\threshold.config'
    $thresholdDst = Join-Path $SuricataDir 'threshold.config'
    if (Test-Path $thresholdSrc) {
        Copy-Item $thresholdSrc $thresholdDst -Force
        Write-Ok "Installed $thresholdDst"
    } else {
        Write-Warn "Kit threshold.config not found at $thresholdSrc; creating an empty one to silence the startup warning."
        Write-TextFile -Path $thresholdDst -Lines @('# intentionally empty')
    }

    # --------------------------------------------------------------
    Write-Step 'Replace the eve-log output block'
    $eveBlock = @(
        '  - eve-log:',
        '      enabled: yes',
        '      filetype: regular',
        '      filename: eve.json',
        '      rotate-interval: day',
        '      pcap-file: false',
        '      community-id: true',
        '      community-id-seed: 0',
        '      types:',
        '        - alert:',
        '            payload: yes',
        '            payload-buffer-size: 4kb',
        '            payload-printable: yes',
        '            metadata: yes',
        # packet / tagged-packets deliberately omitted. They embed the full raw frame as
        # base64 on top of the payload that is already here, roughly doubling alert size
        # for information a dashboard cannot render usefully. Re-enable only if you plan
        # to extract frames for offline analysis.
        '        - dns:',
        '            enabled: yes',
        '            version: 2',
        '            requests: yes',
        '            responses: no',
        '        - tls:',
        '            extended: yes',
        '        - http:',
        '            extended: yes',
        '        - ssh'
    )
    $patched = Set-YamlBlock -Lines $lines -KeyPattern '^\s*-\s*eve-log:' -Replacement $eveBlock
    if ($null -eq $patched) { Stop-WithError 'Could not find the eve-log block in suricata.yaml.' }
    $lines = $patched
    Write-Ok 'eve-log configured: alert + dns(query only) + tls + http + ssh'
    Write-Info 'flow/netflow/stats deliberately excluded -- flow events alone would dwarf everything else'

    # --------------------------------------------------------------
    Write-Step 'Write and validate'
    Write-TextFile -Path $SuricataYaml -Lines $lines
    Write-Ok "Wrote $SuricataYaml (UTF-8, no BOM)"

    Write-Info 'Running suricata -T (config + ruleset validation). This takes a moment.'
    $testOut = & $SuricataExe -T -c $SuricataYaml -l $SuricataLogDir 2>&1 | Out-String
    Write-Host $testOut -ForegroundColor DarkGray

    if ($LASTEXITCODE -ne 0) {
        Write-Fail 'Configuration test FAILED. suricata.yaml has been left in place for inspection.'
        Write-Info "Restore the pristine copy with: Copy-Item '$orig' '$SuricataYaml' -Force"
        Stop-WithError "suricata -T exited with $LASTEXITCODE"
    }
    Write-Ok 'Configuration test passed'

    if ($testOut -match '(\d+)\s+rules? (?:successfully )?loaded') {
        Write-Ok "Rules loaded: $($Matches[1])"
    }

    # --------------------------------------------------------------
    Write-Step 'Install the capture launcher'
    #
    # Capture is driven by a launcher script rather than a fixed -i baked into the task.
    #
    # WHY: pinning one adapter at configure time breaks whenever the machine changes how
    # it connects. Dock a laptop and traffic moves to Ethernet while Suricata keeps
    # watching an idle Wi-Fi adapter -- capturing nothing, reporting no error. The
    # launcher enumerates every physical adapter at START time and passes one -i each.
    #
    # Verified on this build: multiple -i flags are accepted, and an adapter in
    # Disconnected state does not abort startup (Suricata reports "RX: 2" for two
    # devices). So Wi-Fi and Ethernet are both covered continuously, switching between
    # them needs no restart, and no reconfiguration is required.
    #
    # The launcher is copied NEXT TO SURICATA, not run from this kit, so the deployment
    # keeps working if the kit folder is moved or deleted.
    $launcherSrc = Join-Path $KitRoot 'config\suricata-launch.ps1'
    $launcherDst = Join-Path $SuricataDir 'suricata-launch.ps1'
    if (-not (Test-Path $launcherSrc)) { Stop-WithError "Launcher not found at $launcherSrc" }
    Copy-Item $launcherSrc $launcherDst -Force
    Write-Ok "Installed $launcherDst"

    $adapters = @(Get-NetAdapter | Where-Object {
        $_.InterfaceDescription -notmatch 'VMware|Hyper-V|Virtual|Loopback|TAP-|VirtualBox|WAN Miniport|Bluetooth' -and
        $_.Status -ne 'Not Present' -and $_.InterfaceGuid })
    Write-Info "Adapters that will be captured ($($adapters.Count)):"
    foreach ($a in $adapters) { Write-Info ("   {0,-22} {1}" -f $a.Name, $a.Status) }

    if ($SkipStart) {
        Write-Warn 'SkipStart set -- launcher installed but no tasks created and nothing started.'
        Write-Info "Manual run:  powershell -ExecutionPolicy Bypass -File `"$launcherDst`""
        return
    }

    # --------------------------------------------------------------
    Write-Step 'Set up continuous capture (auto-start + watchdog)'

    # Remove every previous mechanism first, so re-runs cannot leave two capturers
    # competing for the same adapters and the same eve.json.
    $existingSvc = Get-Service -Name 'Suricata' -ErrorAction SilentlyContinue
    if ($existingSvc) {
        Write-Info 'Removing the old Suricata service.'
        if ($existingSvc.Status -ne 'Stopped') { Stop-Service -Name 'Suricata' -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
        & sc.exe delete Suricata | Out-Null
    }
    foreach ($t in @('Suricata IDS', 'Suricata IDS Watchdog')) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Write-Info "Removing existing task '$t'."
            Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    Get-Process -Name 'suricata' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    # Marks the boundary for log scanning below, so only this run's errors are reported.
    $runStart = Get-Date

    $psExe      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $principal  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $baseArgs   = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$launcherDst`""

    # --- 1. Boot task -------------------------------------------------------
    # 20s delay: not to wait for the network (capture is adapter-bound and does not need
    # one) but to let adapter enumeration settle and to stay out of the way of the boot
    # storm, so this never slows a user's logon.
    Write-Info 'Creating "Suricata IDS" (SYSTEM, at system startup)'
    $bootTrigger = New-ScheduledTaskTrigger -AtStartup
    $bootTrigger.Delay = 'PT20S'
    $bootSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                      -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
                      -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName 'Suricata IDS' `
        -Action (New-ScheduledTaskAction -Execute $psExe -Argument $baseArgs -WorkingDirectory $SuricataDir) `
        -Trigger $bootTrigger -Principal $principal -Settings $bootSettings `
        -Description 'Starts Suricata network IDS capture on all physical adapters. Feeds the Wazuh agent.' | Out-Null
    Write-Ok 'Boot task created'

    # --- 2. Watchdog task ---------------------------------------------------
    # Runs indefinitely every 5 minutes. In -CheckOnly mode it exits silently when
    # Suricata is running on the expected adapter set, so the cost is negligible. It
    # covers three cases the boot task cannot: Suricata crashed, a new adapter appeared
    # (USB NIC, dock), or the boot task lost a race at startup.
    Write-Info 'Creating "Suricata IDS Watchdog" (SYSTEM, every 5 minutes)'
    # -RepetitionDuration is deliberately omitted. That leaves Duration empty, which Task
    # Scheduler treats as "repeat indefinitely" (verified: the trigger object comes back
    # with Interval=PT5M, Duration=''). Passing [TimeSpan]::MaxValue instead yields
    # P99999999D, which works but is not actually unbounded -- do not "fix" this by adding
    # a duration.
    $wdTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
                    -RepetitionInterval (New-TimeSpan -Minutes 5)
    $wdSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName 'Suricata IDS Watchdog' `
        -Action (New-ScheduledTaskAction -Execute $psExe -Argument "$baseArgs -CheckOnly" -WorkingDirectory $SuricataDir) `
        -Trigger $wdTrigger -Principal $principal -Settings $wdSettings `
        -Description 'Restarts Suricata capture if it stopped or the set of network adapters changed.' | Out-Null
    Write-Ok 'Watchdog task created (5 min interval)'

    # --- 3. Start now -------------------------------------------------------
    Write-Info 'Starting capture now...'
    Start-ScheduledTask -TaskName 'Suricata IDS'
    Start-Sleep -Seconds 20
    Save-State 'suricata_mechanism' 'launcher+watchdog'
    Save-State 'suricata_adapters'  ($adapters.Count)

    # --------------------------------------------------------------
    Write-Step 'Confirm Suricata is actually capturing'
    Start-Sleep -Seconds 5

    $proc = @(Get-Process -Name 'suricata' -ErrorAction SilentlyContinue)
    if ($proc.Count -gt 0) { Write-Ok "suricata.exe running (PID $($proc.Id -join ', '))" }
    else                   { Write-Fail 'suricata.exe is NOT running. Check log\launcher.log and log\suricata.log.' }

    $launcherLog = Join-Path $SuricataLogDir 'launcher.log'
    if (Test-Path $launcherLog) {
        Write-Info 'Launcher log (what it decided to capture):'
        Get-Content $launcherLog -Tail 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }

    # "RX: N" is Suricata's own count of capture threads, one per device. It is the
    # authoritative confirmation that every adapter was actually opened.
    $rx = @(Get-SuricataLogSince -Since $runStart -Pattern 'Threads created')
    if ($rx.Count -gt 0) { $rx | Select-Object -Last 1 | ForEach-Object { Write-Ok "Capture threads: $($_ -replace '.*Threads created', 'Threads created')" } }

    $suriLog = Join-Path $SuricataLogDir 'suricata.log'
    if (Test-Path $suriLog) {
        Write-Info 'Last 15 lines of suricata.log:'
        Get-Content $suriLog -Tail 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

        # Scope to THIS run only. suricata.log is append-only across restarts, so an
        # unscoped grep reports failures that were already fixed and makes a healthy
        # start look broken.
        $errs = @(Get-SuricataLogSince -Since $runStart -Pattern '[0-9][0-9]:[0-9][0-9]:[0-9][0-9] (Error|Critical):')
        if ($errs.Count -gt 0) {
            Write-Warn "Errors from this run ($($errs.Count)):"
            $errs | Select-Object -Last 8 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
        } else {
            Write-Ok 'No errors logged by this run'
        }
    }

    Write-Step 'Stage 3 complete'
    Write-Info "Generate some traffic, then check that $EveJson is growing."
    Write-Info 'Next: .\04-wire-wazuh-agent.ps1'
}
finally {
    Stop-Transcript-Safe
}
