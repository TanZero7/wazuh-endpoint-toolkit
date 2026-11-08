<#
    Stage 6 -- Disable DNS-over-HTTPS so Suricata can see DNS queries.

    WHY THIS IS NECESSARY
    ---------------------
    Chrome, Edge and Firefox all default to resolving DNS over HTTPS. Those lookups
    travel inside a TLS session to the DoH resolver, so on the wire they are
    indistinguishable from ordinary HTTPS traffic. Suricata sees the TLS connection and
    nothing else -- no query, no domain, no dns event.

    The practical effect is that DNS visibility looks broken when it is in fact working
    perfectly on a stream of traffic that no longer exists. This is the single most
    common reason a Suricata DNS dashboard sits empty.

    WHAT THIS CHANGES
    -----------------
    Machine-wide policy for Chrome, Edge and Firefox, plus Windows' own automatic DoH
    upgrade. All are registry policy values and all are reverted by -Revert.

    TRADE-OFF, STATED PLAINLY
    -------------------------
    Disabling DoH means DNS queries travel in cleartext. On a home LAN, monitored by you,
    for a PoC whose entire purpose is DNS visibility, that is the intended trade. On a
    hostile or shared network it is a real reduction in privacy against the network
    operator and your ISP. Decide accordingly -- and note that TLS SNI visibility
    (rule 100220) works whether or not DoH is on, so if you only care about "which sites",
    you can skip this script entirely.

    Browsers must be fully restarted for the policy to take effect.
#>

[CmdletBinding()]
param(
    [switch]$Revert,
    [switch]$Force
)

. "$PSScriptRoot\lib\common.ps1"
Start-Transcript-Safe -Name '06-disable-doh'

try {
    Assert-Elevated

    if (-not $Force -and -not $Revert) {
        Write-Warn 'This disables encrypted DNS machine-wide. DNS queries will travel in cleartext.'
        $ans = Read-Host '    Proceed? [y/N]'
        if ($ans -notmatch '^(y|yes)$') { Write-Info 'Aborted.'; return }
    }

    function Set-PolicyValue {
        param([string]$Path, [string]$Name, $Value, [string]$Type = 'String', [string]$Label)
        if ($Revert) {
            if (Test-Path $Path) {
                $existing = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
                if ($existing) {
                    Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction SilentlyContinue
                    Write-Ok "Reverted: $Label"
                } else { Write-Info "$Label was not set" }
            } else { Write-Info "$Label -- policy key absent" }
        } else {
            if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
            New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
            Write-Ok "$Label -> $Value"
        }
    }

    Write-Step 'Google Chrome'
    Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Google\Chrome' -Name 'DnsOverHttpsMode' `
                    -Value 'off' -Type String -Label 'Chrome DnsOverHttpsMode'

    Write-Step 'Microsoft Edge'
    Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'DnsOverHttpsMode' `
                    -Value 'off' -Type String -Label 'Edge DnsOverHttpsMode'

    Write-Step 'Mozilla Firefox'
    # Firefox uses a nested DNSOverHTTPS policy key; Locked stops the user re-enabling it.
    Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS' -Name 'Enabled' `
                    -Value 0 -Type DWord -Label 'Firefox DoH Enabled'
    Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS' -Name 'Locked' `
                    -Value 1 -Type DWord -Label 'Firefox DoH Locked'

    Write-Step 'Windows automatic DoH upgrade'
    # Windows 11 will silently upgrade known public resolvers to DoH. 0 disables that.
    Set-PolicyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name 'EnableAutoDoh' `
                    -Value 0 -Type DWord -Label 'Windows EnableAutoDoh'

    Write-Step 'Flush the DNS cache'
    Clear-DnsClientCache
    Write-Ok 'Cache flushed'

    Write-Step 'Done'
    if ($Revert) {
        Write-Ok 'DoH policies removed. Browsers revert to their own defaults after a restart.'
    } else {
        Write-Ok 'DoH disabled machine-wide.'
        Write-Warn 'RESTART ALL BROWSERS COMPLETELY -- policy is read at startup, not per-tab.'
        Write-Info 'Verify in Chrome/Edge at  chrome://policy  or  edge://policy'
        Write-Info 'Then re-run .\05-verify.ps1 and confirm DNS events are non-zero.'
    }
}
finally {
    Stop-Transcript-Safe
}
