<#
    Stage 0 -- Preflight.

    Changes nothing. Establishes ground truth about this machine and writes it to
    state\ for the later stages. Run this first in any new session, and re-read its
    output rather than trusting HANDOFF.md, which is a snapshot and may have gone stale.
#>

[CmdletBinding()]
param()

. "$PSScriptRoot\lib\common.ps1"
Start-Transcript-Safe -Name '00-preflight'

try {
    # Set by any hard-prerequisite failure below; checked at the end.
    $script:PreflightFailed = $false

    Write-Step 'Elevation'
    Assert-Elevated

    Write-Step 'Operating system'
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Info "$($os.Caption) build $($os.BuildNumber), host $env:COMPUTERNAME"

    # ------------------------------------------------------------------
    Write-Step 'Npcap (Suricata capture dependency)'
    $npcapReg = $null
    foreach ($p in @('HKLM:\SOFTWARE\WOW6432Node\Npcap', 'HKLM:\SOFTWARE\Npcap')) {
        if (Test-Path $p) { $npcapReg = Get-ItemProperty $p; break }
    }
    if (-not $npcapReg) {
        Write-Fail 'Npcap NOT installed. Suricata cannot capture without it.'
        Write-Info 'Install prereqs\npcap-1.87.exe with "WinPcap API-compatible Mode" ticked.'
        Write-Info 'Fetch it with: .\scripts\Get-Prerequisites.ps1'
        Save-State 'npcap_ok' 'false'
        # Hard stop. Without Npcap, Suricata installs happily and captures nothing --
        # a deployment that looks healthy until you notice eve.json never grows.
        $script:PreflightFailed = $true
    } else {
        $winpcapCompat = $npcapReg.WinPcapCompatible
        Write-Ok "Npcap present at $($npcapReg.'(default)')"
        Write-Info "WinPcapCompatible=$winpcapCompat  AdminOnly=$($npcapReg.AdminOnly)"
        if ($winpcapCompat -ne 1) {
            Write-Warn 'WinPcap-compatible mode is OFF. Suricata may fail to open the adapter.'
            Write-Info 'Re-run the Npcap installer and tick "Install Npcap in WinPcap API-compatible Mode".'
        }
        Save-State 'npcap_ok' 'true'
    }

    # ------------------------------------------------------------------
    Write-Step 'Capture interface selection'
    Get-NetAdapter | Sort-Object Status, Name |
        Select-Object Name, Status, InterfaceDescription, InterfaceGuid |
        Format-Table -AutoSize | Out-String | Write-Host

    $iface = Get-CaptureInterface
    Write-Ok "Selected: $($iface.Name) -- $($iface.Description)"
    Write-Info "IPv4       : $($iface.IPv4)/$($iface.PrefixLength)"
    Write-Info "NPF device : $($iface.NpfDevice)"

    if (-not $iface.IPv4) {
        Write-Warn 'Selected adapter has no usable IPv4 address. HOME_NET cannot be derived.'
    } else {
        $homeNet = Get-SubnetCidr -IPv4 $iface.IPv4 -PrefixLength $iface.PrefixLength
        Write-Info "HOME_NET   : $homeNet"
        Save-State 'home_net' $homeNet
    }
    Save-State 'iface_name'  $iface.Name
    Save-State 'npf_device'  $iface.NpfDevice
    Save-State 'host_ip'     $iface.IPv4

    # ------------------------------------------------------------------
    Write-Step 'Suricata'
    if (Test-Path $SuricataExe) {
        $v = & $SuricataExe -V 2>&1 | Out-String
        Write-Ok "Installed: $($v.Trim())"
        Save-State 'suricata_installed' 'true'
    } else {
        Write-Info "Not installed (expected at $SuricataExe)"
        Save-State 'suricata_installed' 'false'
    }

    # ------------------------------------------------------------------
    Write-Step 'Wazuh agent'
    if (-not (Test-Path $WazuhDir)) {
        Write-Fail "Wazuh agent not found at $WazuhDir"
        Save-State 'wazuh_installed' 'false'
    } else {
        Save-State 'wazuh_installed' 'true'

        $verFile = Join-Path $WazuhDir 'VERSION.json'
        $agentVersion = 'unknown'
        if (Test-Path $verFile) {
            $vj = Get-Content $verFile -Raw | ConvertFrom-Json
            $agentVersion = $vj.version
            Write-Ok "Agent version: $agentVersion (stage $($vj.stage))"
        }
        Save-State 'agent_version' $agentVersion

        $svc = Get-Service -Name 'WazuhSvc' -ErrorAction SilentlyContinue
        if ($svc) { Write-Info "Service WazuhSvc: $($svc.Status)" }
        else      { Write-Warn 'Service WazuhSvc not found.' }

        # Which manager is this agent pointed at?
        if (Test-Path $WazuhConf) {
            try {
                [xml]$confXml = '<root>' + (Get-Content $WazuhConf -Raw) + '</root>'
                $servers = $confXml.root.ossec_config.client.server
                if ($servers) {
                    foreach ($s in @($servers)) {
                        Write-Ok "Manager target: $($s.address) port $($s.port) proto $($s.protocol)"
                        Save-State 'manager_address' $s.address
                    }
                } else {
                    Write-Warn 'No <client><server> block found in ossec.conf.'
                }
            } catch {
                Write-Warn "Could not parse ossec.conf as XML: $($_.Exception.Message)"
                Select-String -Path $WazuhConf -Pattern '<address>|<port>|<protocol>' |
                    ForEach-Object { Write-Info $_.Line.Trim() }
            }

            # Is eve.json already wired in?
            if (Select-String -Path $WazuhConf -Pattern 'eve\.json' -Quiet) {
                Write-Ok 'ossec.conf already contains an eve.json localfile block.'
                Save-State 'eve_wired' 'true'
            } else {
                Write-Info 'ossec.conf does not yet reference eve.json (expected before stage 4).'
                Save-State 'eve_wired' 'false'
            }
        }

        # Enrollment
        $keys = Join-Path $WazuhDir 'client.keys'
        if ((Test-Path $keys) -and ((Get-Item $keys).Length -gt 0)) {
            $line = (Get-Content $keys -First 1) -split ' '
            Write-Ok "Enrolled: agent id=$($line[0]) name=$($line[1]) (key withheld)"
            Save-State 'agent_id' $line[0]
        } else {
            Write-Warn 'client.keys empty or missing -- agent is NOT enrolled.'
        }

        Write-Step 'Wazuh agent log (last 20 lines)'
        $log = Join-Path $WazuhDir 'ossec.log'
        if (Test-Path $log) {
            Get-Content $log -Tail 20 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            # Contextualise rather than alarm: ossec.log keeps every past disconnect, so a
            # plain grep makes a currently-healthy agent look broken -- especially after
            # the manager address changes, where every pre-change error is still on file.
            $recentErrors = @(Get-Content $log -Tail 200 | Where-Object { $_ -match 'ERROR|CRITICAL|Unable to connect|refused' })
            if ($recentErrors.Count -gt 0) {
                $stateFile = Join-Path $WazuhDir 'wazuh-agent.state'
                $connectedNow = $false
                if (Test-Path $stateFile) {
                    $connectedNow = @(Get-Content $stateFile | Where-Object { $_ -match "^status='connected'" }).Count -gt 0
                }
                if ($connectedNow) {
                    Write-Info "$($recentErrors.Count) past error(s) in ossec.log, but the agent is connected NOW. Most recent:"
                    $recentErrors | Select-Object -Last 2 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
                } else {
                    Write-Warn 'Errors in agent log AND the agent is not currently connected:'
                    $recentErrors | Select-Object -Last 8 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
                }
            }
        }
    }

    # ------------------------------------------------------------------
    Write-Step 'Manager reachability'
    $mgr = Get-State 'manager_address'
    if (-not $mgr -or $mgr -eq 'MANAGER_IP') {
        Write-Warn 'No manager address configured yet. Skipping reachability test.'
    } else {
        foreach ($port in @(1514, 1515)) {
            $r = Test-NetConnection -ComputerName $mgr -Port $port -WarningAction SilentlyContinue
            if ($r.TcpTestSucceeded) { Write-Ok  "$mgr : $port reachable" }
            else                     { Write-Fail "$mgr : $port NOT reachable" }
        }
    }

    # ------------------------------------------------------------------
    Write-Step 'Internet reachability for downloads'
    foreach ($u in @($SuricataMsiUrl, $EtRulesUrl)) {
        try {
            $r = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 30
            Write-Ok "$([System.IO.Path]::GetFileName($u)) -- HTTP $($r.StatusCode)"
        } catch {
            Write-Fail "$u -- $($_.Exception.Message)"
        }
    }

    if ($script:PreflightFailed) {
        Write-Step 'PREFLIGHT FAILED'
        Stop-WithError 'A hard prerequisite is missing (see above). Resolve it before continuing.'
    }

    Write-Step 'Preflight complete'
    Write-Info "State written to $StateDir"
    Write-Host ''
    Write-Host '  NEXT: confirm the MANAGER version over SSH before touching the agent:' -ForegroundColor White
    Write-Host '        ssh <user>@<manager>  /var/ossec/bin/wazuh-control info' -ForegroundColor White
}
finally {
    Stop-Transcript-Safe
}
