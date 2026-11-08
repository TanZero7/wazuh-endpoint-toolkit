<#
    Stage 5 -- End-to-end verification.

    Read-only. Answers, in order, the questions that actually determine whether this
    integration works:

      1. Is Suricata running and capturing?
      2. Is eve.json growing, and what event types are in it?
      3. Is DNS visibility real, or is DoH hiding it?
      4. Is the Wazuh agent reading eve.json?
      5. Is the agent connected to a manager, and is it dropping events?

    Each stage prints a verdict. Run it after every change.
#>

[CmdletBinding()]
param(
    [int]$SampleSeconds = 20
)

. "$PSScriptRoot\lib\common.ps1"
Start-Transcript-Safe -Name '05-verify'

$results = [ordered]@{}

function Set-Verdict { param([string]$Name, [bool]$Pass, [string]$Detail)
    $results[$Name] = [PSCustomObject]@{ Pass = $Pass; Detail = $Detail }
}

try {
    Assert-Elevated

    # ==============================================================
    Write-Step '1. Suricata process'
    # @() so .Count is valid when exactly one process matches. Set-StrictMode -Version
    # Latest removes PowerShell's scalar .Count fallback, so an unwrapped single object
    # throws PropertyNotFoundStrict.
    $proc = @(Get-Process -Name 'suricata' -ErrorAction SilentlyContinue)
    if ($proc.Count -gt 0) {
        foreach ($p in $proc) {
            $cpu = [math]::Round($p.CPU, 1)
            $mem = [math]::Round($p.WorkingSet64 / 1MB, 1)
            Write-Ok "PID $($p.Id)  CPU ${cpu}s  RAM ${mem}MB  up since $($p.StartTime)"
        }
        Set-Verdict 'Suricata running' $true "$($proc.Count) process(es)"
    } else {
        Write-Fail 'suricata.exe is not running.'
        $mech = Get-State 'suricata_mechanism'
        if ($mech -eq 'service')            { Write-Info 'Try: Start-Service Suricata' }
        elseif ($mech -eq 'scheduledtask')  { Write-Info 'Try: Start-ScheduledTask -TaskName "Suricata IDS"' }
        Set-Verdict 'Suricata running' $false 'process absent'
    }

    # Scope errors to the current Suricata process. suricata.log persists across restarts,
    # so an unscoped scan reports already-fixed failures as if they were live.
    if ($proc.Count -gt 0) {
        $since = ($proc | Sort-Object StartTime | Select-Object -First 1).StartTime
        $errs = @(Get-SuricataLogSince -Since $since -Pattern '[0-9][0-9]:[0-9][0-9]:[0-9][0-9] (Error|Critical):')
        if ($errs.Count -gt 0) {
            Write-Warn "Errors since Suricata started ($($errs.Count)):"
            $errs | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
        } else {
            Write-Ok 'No errors logged since Suricata started'
        }
    }

    # ==============================================================
    Write-Step "2. eve.json growth over ${SampleSeconds}s"
    if (-not (Test-Path $EveJson)) {
        Write-Fail "$EveJson does not exist. Suricata has produced no events at all."
        Set-Verdict 'eve.json growing' $false 'file missing'
    } else {
        $before = (Get-Item $EveJson).Length
        Write-Info "Size now: $([math]::Round($before/1KB,1)) KB. Sampling..."
        Write-Info 'Generating some traffic so there is something to observe.'
        try { Resolve-DnsName 'www.microsoft.com' -ErrorAction SilentlyContinue | Out-Null } catch {}
        try { Invoke-WebRequest -Uri 'https://example.com' -UseBasicParsing -TimeoutSec 10 | Out-Null } catch {}
        Start-Sleep -Seconds $SampleSeconds
        $after = (Get-Item $EveJson).Length
        $delta = $after - $before

        if ($delta -gt 0) {
            Write-Ok "Grew by $delta bytes -- Suricata is writing events."
            Set-Verdict 'eve.json growing' $true "+$delta bytes"
        } else {
            Write-Fail 'No growth. Suricata is running but not capturing on this interface.'
            Write-Info "Confirm the NPF device is right: $(Get-State 'npf_device')"
            Write-Info 'Compare against Wireshark on the same adapter to rule out an Npcap problem.'
            Set-Verdict 'eve.json growing' $false 'no growth'
        }
    }

    # ==============================================================
    Write-Step '3. Event type breakdown (last 2000 lines)'
    if (Test-Path $EveJson) {
        $tail   = Get-Content $EveJson -Tail 2000 -ErrorAction SilentlyContinue
        $counts = @{}
        $bad    = 0
        foreach ($line in $tail) {
            if (-not $line.Trim()) { continue }
            try {
                $t = ($line | ConvertFrom-Json).event_type
                if ($t) { if ($counts.ContainsKey($t)) { $counts[$t]++ } else { $counts[$t] = 1 } }
            } catch { $bad++ }
        }

        if ($counts.Count -gt 0) {
            $counts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
                Write-Host ("    {0,-12} {1,6}" -f $_.Key, $_.Value) -ForegroundColor White
            }
        } else {
            Write-Warn 'No parseable events in the tail.'
        }
        if ($bad -gt 0) { Write-Warn "$bad unparseable lines (usually a partially-written final line -- harmless)" }

        # DNS visibility is the goal most likely to be silently broken, by DoH.
        $dnsCount = 0; if ($counts.ContainsKey('dns')) { $dnsCount = $counts['dns'] }
        $tlsCount = 0; if ($counts.ContainsKey('tls')) { $tlsCount = $counts['tls'] }

        if ($dnsCount -gt 0) {
            Write-Ok "$dnsCount DNS events -- plaintext DNS is visible."
            Set-Verdict 'DNS visibility' $true "$dnsCount events"
        } else {
            Write-Fail 'ZERO DNS events. Almost certainly DNS-over-HTTPS.'
            Write-Info 'Browsers default to DoH, which encrypts lookups inside HTTPS where Suricata cannot see them.'
            Write-Info 'Fix: .\06-disable-doh.ps1'
            Set-Verdict 'DNS visibility' $false 'no dns events -- likely DoH'
        }

        if ($tlsCount -gt 0) {
            Write-Ok "$tlsCount TLS events -- SNI visibility is working."
            Set-Verdict 'TLS visibility' $true "$tlsCount events"
        } else {
            Write-Warn 'No TLS events. Unexpected on any machine doing normal browsing.'
            Set-Verdict 'TLS visibility' $false 'no tls events'
        }

        Write-Step '   Most recent domains seen (proof of visibility)'
        $seen = New-Object System.Collections.Generic.HashSet[string]
        foreach ($line in ($tail | Select-Object -Last 800)) {
            if (-not $line.Trim()) { continue }
            try {
                $o = $line | ConvertFrom-Json
                if ($o.event_type -eq 'tls'  -and $o.tls.sni)    { [void]$seen.Add("TLS  $($o.tls.sni)") }
                if ($o.event_type -eq 'dns'  -and $o.dns.rrname) { [void]$seen.Add("DNS  $($o.dns.rrname)") }
                if ($o.event_type -eq 'http' -and $o.http.hostname) { [void]$seen.Add("HTTP $($o.http.hostname)") }
            } catch {}
        }
        if ($seen.Count -gt 0) {
            $seen | Select-Object -First 25 | ForEach-Object { Write-Host "    $_" -ForegroundColor Cyan }
            Write-Ok "$($seen.Count) distinct destinations observed"
        } else {
            Write-Warn 'No destinations extracted.'
        }
    }

    # ==============================================================
    Write-Step '4. Wazuh agent is reading eve.json'
    $lcState = Join-Path $WazuhDir 'wazuh-logcollector.state'
    if (Test-Path $lcState) {
        $state = Get-Content $lcState -Raw
        if ($state -match 'eve\.json') {
            Write-Ok 'eve.json is in wazuh-logcollector.state'
            ($state -split "`r?`n") | Where-Object { $_ -match 'eve\.json' -or $_ -match '^events=' } |
                Select-Object -First 8 | ForEach-Object { Write-Host "    $_" -ForegroundColor Green }
            Set-Verdict 'Agent tailing eve.json' $true 'present in logcollector state'
        } else {
            Write-Fail 'eve.json is NOT in the logcollector state -- the agent is not reading it.'
            Write-Info 'Check the <localfile> block in ossec.conf, then restart WazuhSvc.'
            Set-Verdict 'Agent tailing eve.json' $false 'absent from logcollector state'
        }
    } else {
        Write-Warn 'wazuh-logcollector.state not found.'
        Set-Verdict 'Agent tailing eve.json' $false 'state file missing'
    }

    # ==============================================================
    Write-Step '5. Agent connectivity and event loss'
    $svc = Get-Service -Name 'WazuhSvc' -ErrorAction SilentlyContinue
    if ($svc) { Write-Info "WazuhSvc: $($svc.Status)" } else { Write-Fail 'WazuhSvc not found' }

    $agentState = Join-Path $WazuhDir 'wazuh-agent.state'
    if (Test-Path $agentState) {
        Get-Content $agentState | Where-Object { $_ -match '=' } | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        $statusLine = Get-Content $agentState | Where-Object { $_ -match '^status=' }
        if ($statusLine -match 'connected') {
            Write-Ok 'Agent status: connected'
            Set-Verdict 'Agent connected' $true 'status=connected'
        } else {
            Write-Fail "Agent status is not connected ($statusLine)"
            Set-Verdict 'Agent connected' $false "$statusLine"
        }
    }

    $log = Join-Path $WazuhDir 'ossec.log'
    if (Test-Path $log) {
        $recent = Get-Content $log -Tail 300
        $dropped = $recent | Where-Object { $_ -match 'buffer is full|Event lost|flooding|dropped' }
        if ($dropped) {
            Write-Warn 'Agent is dropping events -- the dashboard will be missing traffic:'
            $dropped | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
            Write-Info 'Fix: .\04-wire-wazuh-agent.ps1 -EventsPerSecond 1000'
        } else {
            Write-Ok 'No event-loss messages in recent agent log'
        }
        # Contextualise rather than alarm. ossec.log keeps every past disconnect, so a
        # plain grep makes a currently-healthy agent look broken -- and a manager restart
        # (which installing rules requires) always leaves a few of these behind. What
        # matters is whether the agent is connected NOW, which section 5 already
        # established from wazuh-agent.state.
        $connErr = @($recent | Where-Object { $_ -match 'Unable to connect|refused|Lost connection' })
        if ($connErr.Count -gt 0) {
            $nowConnected = $false
            if (Test-Path $agentState) {
                $nowConnected = @(Get-Content $agentState | Where-Object { $_ -match "^status='connected'" }).Count -gt 0
            }
            if ($nowConnected) {
                Write-Info "$($connErr.Count) past connectivity error(s) in ossec.log, but the agent is connected now (expected after any manager restart). Most recent:"
                $connErr | Select-Object -Last 2 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            } else {
                Write-Warn 'Connectivity problems in agent log and the agent is NOT currently connected:'
                $connErr | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
            }
        }
    }

    # ==============================================================
    Write-Step 'VERDICT'
    $failed = 0
    foreach ($k in $results.Keys) {
        $r = $results[$k]
        if ($r.Pass) { Write-Host ("    [PASS] {0,-26} {1}" -f $k, $r.Detail) -ForegroundColor Green }
        else         { Write-Host ("    [FAIL] {0,-26} {1}" -f $k, $r.Detail) -ForegroundColor Red; $failed++ }
    }
    Write-Host ''
    if ($failed -eq 0) {
        Write-Ok 'Endpoint side is fully working.'
        Write-Info 'Remaining check is manager side: confirm alerts arrive with  rule.groups:suricata'
    } else {
        Write-Warn "$failed check(s) failed -- resolve these before looking at the dashboard."
        # [fix] "Agent tailing eve.json" reads wazuh-logcollector.state, which only
        # catches up a few minutes after WazuhSvc restarts (script 04 restarts it right before
        # this can be run). Do not treat a FAIL right after setup as broken -- wait and recheck.
        Write-Info 'If this just ran right after setup, wait about 10 minutes and run this script again before troubleshooting further -- some checks (especially "Agent tailing eve.json") read log/state files that take a few minutes to catch up after a restart.'
    }
}
finally {
    Stop-Transcript-Safe
}
