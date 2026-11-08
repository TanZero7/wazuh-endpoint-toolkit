<#
    Stage 4 -- Point the Wazuh agent at eve.json.

    This is the one-block change the official Wazuh PoC makes, with the path adapted for
    Windows. Everything else in this kit exists to make this block produce useful output.

    Also checks the agent's event-rate buffer, which is the failure mode people hit here:
    the agent defaults to 500 events/sec with a 5000-event buffer, and DNS+TLS logging on
    a busy endpoint can exceed that. When it does, the agent silently drops events and
    only mentions it in ossec.log. Better to see it now than to wonder later why the
    dashboard is missing traffic.
#>

[CmdletBinding()]
param(
    # Wazuh REJECTS values above 1000 for this element. Setting 2000 makes the agent fail
    # config parsing entirely ("Invalid value for element 'events_per_second'") and then
    # exit with "No client configured" -- i.e. the agent goes DOWN, silently, until the
    # value is corrected. ValidateRange makes that impossible to do by accident.
    [ValidateRange(0, 1000)]
    [int]$EventsPerSecond = 0,   # >0 raises <client_buffer><events_per_second>; max 1000
    [switch]$NoRestart
)

. "$PSScriptRoot\lib\common.ps1"
Start-Transcript-Safe -Name '04-wire-wazuh-agent'

try {
    Assert-Elevated

    if (-not (Test-Path $WazuhConf)) { Stop-WithError "ossec.conf not found at $WazuhConf" }

    # --------------------------------------------------------------
    Write-Step 'Confirm eve.json exists before wiring to it'
    if (-not (Test-Path $EveJson)) {
        Write-Warn "$EveJson does not exist yet."
        Write-Info 'Suricata creates it on first event. Wiring the agent anyway is safe -- logcollector will pick it up when it appears -- but you should confirm stage 3 actually worked.'
    } else {
        $sizeKb = [math]::Round((Get-Item $EveJson).Length / 1KB, 1)
        Write-Ok "eve.json present ($sizeKb KB)"
    }

    # --------------------------------------------------------------
    Write-Step 'Back up ossec.conf'
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $StateDir "ossec.conf.$stamp.bak"
    Copy-Item $WazuhConf $backup -Force
    Write-Ok "Backup: $backup"

    # --------------------------------------------------------------
    Write-Step 'Add the eve.json localfile block'

    $conf = Get-Content $WazuhConf -Raw

    if ($conf -match 'eve\.json') {
        Write-Ok 'ossec.conf already references eve.json -- leaving it alone (idempotent).'
    } else {
        # No double hyphen inside the comment body: XML forbids it, and a malformed
        # ossec.conf stops the agent from starting.
        $block = @"

  <!-- Suricata IDS. Added by the Suricata+Wazuh deployment kit on $(Get-Date -Format 'yyyy-MM-dd') -->
  <localfile>
    <log_format>json</log_format>
    <location>$EveJson</location>
  </localfile>
"@
        # ossec.conf can legally contain more than one <ossec_config> root, so this
        # inserts before the LAST closing tag rather than parsing it as a single XML doc.
        $idx = $conf.LastIndexOf('</ossec_config>')
        if ($idx -lt 0) { Stop-WithError 'No </ossec_config> found in ossec.conf -- refusing to guess where to insert.' }

        $conf = $conf.Substring(0, $idx) + $block + "`r`n" + $conf.Substring($idx)
        Write-TextFile -Path $WazuhConf -Lines @($conf) -NoNewline
        Write-Ok "Inserted localfile block for $EveJson"
    }

    # --------------------------------------------------------------
    Write-Step 'Check the agent event-rate buffer'

    if ($conf -match '<events_per_second>(\d+)</events_per_second>') {
        $eps = [int]$Matches[1]
        Write-Info "Current events_per_second: $eps"
        if ($eps -lt 1000) {
            Write-Warn "At $eps eps the agent may throttle DNS/TLS bursts and drop events."
            Write-Info 'Re-run with -EventsPerSecond 1000 to raise it, or accept the loss for a PoC.'
        }
    } else {
        Write-Info 'No explicit <client_buffer> found; the agent default applies (500 eps, 5000-event buffer).'
    }

    if ($EventsPerSecond -gt 0) {
        $conf = Get-Content $WazuhConf -Raw
        if ($conf -match '<events_per_second>\d+</events_per_second>') {
            $conf = $conf -replace '<events_per_second>\d+</events_per_second>', "<events_per_second>$EventsPerSecond</events_per_second>"
            Write-TextFile -Path $WazuhConf -Lines @($conf) -NoNewline
            Write-Ok "events_per_second set to $EventsPerSecond"
        } else {
            Write-Warn 'No <events_per_second> element to update. Add a <client_buffer> section manually if you need this.'
        }
    }

    # --------------------------------------------------------------
    Write-Step 'Restart the agent'
    if ($NoRestart) {
        Write-Warn 'NoRestart set -- config written but not applied. Restart WazuhSvc to activate.'
        return
    }

    Restart-Service -Name 'WazuhSvc' -Force
    (Get-Service 'WazuhSvc').WaitForStatus('Running', '00:01:00')
    Write-Ok 'WazuhSvc restarted'

    Write-Info 'Waiting 20s for logcollector to open the file...'
    Start-Sleep -Seconds 20

    # --------------------------------------------------------------
    Write-Step 'Confirm logcollector picked up eve.json'

    $lcState = Join-Path $WazuhDir 'wazuh-logcollector.state'
    if (Test-Path $lcState) {
        $state = Get-Content $lcState -Raw
        if ($state -match 'eve\.json') {
            Write-Ok 'eve.json appears in wazuh-logcollector.state -- the agent is tailing it.'
            ($state -split "`r?`n") | Where-Object { $_ -match 'eve\.json|events=' } |
                Select-Object -First 6 | ForEach-Object { Write-Host "    $_" -ForegroundColor Green }
        } else {
            Write-Warn 'eve.json not yet listed in logcollector state. It can take a minute, or the file may not exist yet.'
        }
    } else {
        Write-Info 'wazuh-logcollector.state not present yet.'
    }

    $log = Join-Path $WazuhDir 'ossec.log'
    if (Test-Path $log) {
        $relevant = Get-Content $log -Tail 120 | Where-Object { $_ -match 'eve\.json|Analyzing file|ERROR|Unable' }
        if ($relevant) {
            Write-Info 'Relevant ossec.log lines:'
            $relevant | Select-Object -Last 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }
    }

    Write-Step 'Stage 4 complete'
    Write-Info 'Suricata alerts should now reach the manager as rule 86601 (level 3).'
    Write-Info 'DNS/TLS/HTTP will still be INVISIBLE until the custom manager rules are installed --'
    Write-Info 'see wazuh-manager\install-manager-rules.sh. That is expected, not a fault.'
}
finally {
    Stop-Transcript-Safe
}
