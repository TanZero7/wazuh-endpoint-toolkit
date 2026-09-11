<#
    Guarantee the Wazuh agent never DROPS events.

    Disables the agent's anti-flooding buffer. That buffer caps outgoing events
    at events_per_second (max 1000) and silently DROPS anything above the cap.
    On a real deployment this was measured dropping 1250 Suricata DNS/TLS events
    on a single endpoint. For a SOC that must not miss logs, the buffer is
    disabled so every event is shipped as it is generated.

    This is a <client_buffer> setting, which lives in the agent's LOCAL
    ossec.conf and is NOT pushable from the manager's shared agent.conf -- so it
    has to be applied per-agent (here, or baked into the base ossec.conf your
    installer ships). It is agent-wide, not FIM-specific; it lives in the FIM
    kit only because FIM is the base kit every endpoint gets first.

    TRADE-OFF (deliberate): with anti-flooding off there is no per-agent rate
    limit protecting the manager from a genuinely runaway agent. On a large
    fleet, watch manager ingestion; if one endpoint ever floods, re-enable the
    buffer on that one with a high cap (events_per_second 1000, queue_size
    100000) instead of the default 500. For WAZUH TOOLKIT's "miss nothing" requirement,
    off is the correct default.

    Idempotent and reversible (a timestamped backup is written next to
    ossec.conf; -Revert restores the stock 500-eps buffer).
#>
[CmdletBinding()]
param(
    [string]$WazuhConf = 'C:\Program Files (x86)\ossec-agent\ossec.conf',
    [switch]$Revert
)
$ErrorActionPreference = 'Stop'

function Assert-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this from an elevated (Administrator) PowerShell session."
    }
}
Assert-Elevated
if (-not (Test-Path $WazuhConf)) { throw "ossec.conf not found at $WazuhConf" }

$raw = Get-Content $WazuhConf -Raw
Copy-Item $WazuhConf "$WazuhConf.bak-eventloss-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force

if ($Revert) {
    $block = @"
<client_buffer>
    <disabled>no</disabled>
    <queue_size>5000</queue_size>
    <events_per_second>500</events_per_second>
  </client_buffer>
"@.Trim()
    Write-Host "Reverting to the stock anti-flooding buffer (500 eps)."
} else {
    $block = @"
<client_buffer>
    <!-- Anti-flooding DISABLED so the agent never drops events (WAZUH TOOLKIT: miss nothing). -->
    <disabled>yes</disabled>
  </client_buffer>
"@.Trim()
    Write-Host "Disabling the anti-flooding buffer (no event drops)."
}

$pattern = '<client_buffer>[\s\S]*?</client_buffer>'
if ([regex]::IsMatch($raw, $pattern)) {
    $raw = [regex]::Replace($raw, $pattern, $block, 1)
} else {
    $idx = $raw.LastIndexOf('</ossec_config>')
    if ($idx -lt 0) { throw "No </ossec_config> in ossec.conf -- refusing to guess where to insert." }
    $raw = $raw.Substring(0, $idx) + "  $block`r`n" + $raw.Substring($idx)
}
[IO.File]::WriteAllText($WazuhConf, $raw, (New-Object Text.UTF8Encoding($false)))

Write-Host "`nRestarting WazuhSvc to apply..."
Restart-Service -Name WazuhSvc -Force
(Get-Service WazuhSvc).WaitForStatus('Running', '00:01:00')
Write-Host "Done. Verify no drops with: (Get-Content '$([IO.Path]::GetDirectoryName($WazuhConf))\wazuh-logcollector.state' -Raw | ConvertFrom-Json).global.files | %% { `$_.location; (`$_.targets|measure drops -sum).Sum }"
