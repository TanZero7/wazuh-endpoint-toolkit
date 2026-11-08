<#
    Shared helpers for the Suricata + Wazuh Windows deployment kit.
    Dot-source from every script:  . "$PSScriptRoot\lib\common.ps1"

    Targets Windows PowerShell 5.1 -- no ternary, no null-coalescing, no '&&'.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Kit root is the parent of scripts\.
# This file lives at <root>\scripts\lib\common.ps1, and when dot-sourced $PSCommandPath
# refers to THIS file (not the caller), so getting to <root> takes three hops:
#   common.ps1 -> lib -> scripts -> <root>
$script:KitRoot  = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$script:LogDir   = Join-Path $KitRoot 'logs'
$script:StateDir = Join-Path $KitRoot 'state'

foreach ($d in @($LogDir, $StateDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# Canonical paths. Suricata's MSI is fixed; the Wazuh agent is always the x86 path
# even on x64 Windows.
$script:SuricataDir     = 'C:\Program Files\Suricata'
$script:SuricataExe     = Join-Path $SuricataDir 'suricata.exe'
$script:SuricataYaml    = Join-Path $SuricataDir 'suricata.yaml'
$script:SuricataLogDir  = Join-Path $SuricataDir 'log'
$script:SuricataRuleDir = Join-Path $SuricataDir 'rules'
$script:EveJson         = Join-Path $SuricataLogDir 'eve.json'
$script:WazuhDir        = 'C:\Program Files (x86)\ossec-agent'
$script:WazuhConf       = Join-Path $WazuhDir 'ossec.conf'

# Always the Windows-shipped bsdtar by absolute path. If these scripts are launched from
# Git Bash / MSYS / WSL, that environment's PATH puts GNU tar ahead of Windows' bsdtar, and
# GNU tar parses "C:\..." as an rsync-style host:path spec -- it tries to resolve a host
# called "C" and fails with "Cannot connect to C: resolve failed". Absolute path avoids it.
$script:TarExe = Join-Path $env:SystemRoot 'System32\tar.exe'

$script:SuricataVersion = '8.0.6'
$script:SuricataMsiUrl  = 'https://www.openinfosecfoundation.org/download/windows/Suricata-8.0.6-1-64bit.msi'
$script:EtRulesUrl      = 'https://rules.emergingthreats.net/open/suricata-8.0/emerging.rules.tar.gz'

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok   { param([string]$m) Write-Host "    [ OK ] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    [WARN] $m" -ForegroundColor Yellow }
function Write-Info { param([string]$m) Write-Host "    [info] $m" -ForegroundColor Gray }

function Write-Fail {
    param([string]$m)
    Write-Host "    [FAIL] $m" -ForegroundColor Red
}

function Stop-WithError {
    param([string]$Message)
    Write-Fail $Message
    throw $Message
}

function Assert-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-WithError 'This script requires Administrator. Relaunch Claude Code (or PowerShell) elevated.'
    }
    Write-Ok "Running elevated as $($id.Name)"
}

function Start-Transcript-Safe {
    param([string]$Name)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path  = Join-Path $script:LogDir "$Name-$stamp.log"
    try { Start-Transcript -Path $path -Force | Out-Null; Write-Info "Transcript: $path" }
    catch { Write-Warn "Could not start transcript: $($_.Exception.Message)" }
}

function Stop-Transcript-Safe {
    try { Stop-Transcript | Out-Null } catch { }
}

<#
    Picks the network interface to capture on.

    Chooses the Up adapter that owns the default IPv4 route, which is the one carrying
    this machine's real traffic. Falls back to the first Up physical adapter. Virtual
    adapters (VMware/Hyper-V/loopback) are excluded -- capturing those would show guest
    traffic, not the host's, and this PoC is explicitly about the host's own traffic.

    Returns an object with Name, Guid, NpfDevice, IPv4.
#>
function Get-CaptureInterface {
    param([string]$PreferredName)

    $candidates = Get-NetAdapter | Where-Object {
        $_.Status -eq 'Up' -and
        $_.InterfaceDescription -notmatch 'VMware|Hyper-V|Virtual|Loopback|TAP-|VirtualBox|WAN Miniport'
    }

    if (-not $candidates) { Stop-WithError 'No usable Up network adapter found.' }

    $chosen = $null
    if ($PreferredName) {
        $chosen = $candidates | Where-Object { $_.Name -eq $PreferredName } | Select-Object -First 1
        if (-not $chosen) { Write-Warn "Preferred adapter '$PreferredName' not Up; auto-selecting." }
    }

    if (-not $chosen) {
        # The adapter owning the default route is the one that matters.
        $defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                        Sort-Object RouteMetric | Select-Object -First 1
        if ($defaultRoute) {
            $chosen = $candidates | Where-Object { $_.InterfaceIndex -eq $defaultRoute.InterfaceIndex } | Select-Object -First 1
        }
    }
    if (-not $chosen) { $chosen = $candidates | Select-Object -First 1 }

    $ip = Get-NetIPAddress -InterfaceIndex $chosen.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1

    [PSCustomObject]@{
        Name           = $chosen.Name
        Description    = $chosen.InterfaceDescription
        InterfaceIndex = $chosen.InterfaceIndex
        Guid           = $chosen.InterfaceGuid
        NpfDevice      = "\Device\NPF_$($chosen.InterfaceGuid)"
        IPv4           = if ($ip) { $ip.IPAddress } else { $null }
        PrefixLength   = if ($ip) { $ip.PrefixLength } else { $null }
    }
}

<#
    Derives the local subnet in CIDR form from an IP + prefix length,
    e.g. 192.168.1.7/24 -> 192.168.1.0/24. Used for HOME_NET.
#>
function Get-SubnetCidr {
    param([string]$IPv4, [int]$PrefixLength)

    $addrBytes = ([System.Net.IPAddress]::Parse($IPv4)).GetAddressBytes()
    [Array]::Reverse($addrBytes)
    $addrInt = [BitConverter]::ToUInt32($addrBytes, 0)

    $mask = [uint32]0
    if ($PrefixLength -gt 0) { $mask = [uint32](0xFFFFFFFFL -shl (32 - $PrefixLength) -band 0xFFFFFFFFL) }

    $netInt = $addrInt -band $mask
    $netBytes = [BitConverter]::GetBytes([uint32]$netInt)
    [Array]::Reverse($netBytes)
    $network = ([System.Net.IPAddress]::new($netBytes)).ToString()
    return "$network/$PrefixLength"
}

<#
    Replaces a whole YAML block: the line matching $KeyPattern plus every following
    line that is blank or indented deeper than it. Safer than line-by-line regex
    surgery on nested structures, which is how most YAML-patching scripts break.

    Idempotent: re-running with the same replacement is a no-op.
#>
function Set-YamlBlock {
    param(
        [string[]]$Lines,
        [string]$KeyPattern,     # regex matching the block's opening line
        [string[]]$Replacement
    )

    $startIdx = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $KeyPattern) { $startIdx = $i; break }
    }
    if ($startIdx -lt 0) { return $null }   # caller decides whether that's fatal

    $indent = ($Lines[$startIdx] -replace '^(\s*).*$', '$1').Length

    $endIdx = $Lines.Count
    for ($i = $startIdx + 1; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line.Trim() -eq '') { continue }
        $thisIndent = ($line -replace '^(\s*).*$', '$1').Length
        if ($thisIndent -le $indent) { $endIdx = $i; break }
    }

    $out = @()
    if ($startIdx -gt 0) { $out += $Lines[0..($startIdx - 1)] }
    $out += $Replacement
    if ($endIdx -lt $Lines.Count) { $out += $Lines[$endIdx..($Lines.Count - 1)] }
    return ,$out
}

<#
    Writes UTF-8 WITHOUT a byte-order mark.

    Windows PowerShell 5.1's "-Encoding utf8" emits a BOM, and several consumers here
    choke on it:
      * Suricata rule files  -- a BOM before "# comment" on line 1 stops it being a
        comment, so Suricata tries to parse the header as a signature and fails with
        'Signature missing required value "sid"', taking the whole ruleset down.
      * ossec.conf           -- XML parsers can reject a BOM, which would stop the agent.
      * suricata.yaml        -- libyaml tolerates it, but there is no reason to risk it.

    Always use this instead of Set-Content for files another program parses.
#>
function Write-TextFile {
    param(
        [string]$Path,
        [string[]]$Lines,
        [switch]$NoNewline
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    if ($NoNewline) {
        [System.IO.File]::WriteAllText($Path, ($Lines -join ''), $utf8NoBom)
    } else {
        [System.IO.File]::WriteAllLines($Path, $Lines, $utf8NoBom)
    }
}

<#
    Returns suricata.log lines at or after $Since.

    suricata.log is append-only across restarts, so a naive "tail -n 200 | grep Error"
    surfaces failures from previous runs and makes a healthy engine look broken. This
    parses the "[pid - thread] YYYY-MM-DD HH:MM:SS Level: message" timestamp and filters
    on it, so callers only ever see the run they care about.
#>
function Get-SuricataLogSince {
    param(
        [datetime]$Since,
        [string]$Pattern = '.'
    )
    $log = Join-Path $script:SuricataLogDir 'suricata.log'
    if (-not (Test-Path $log)) { return @() }

    $out = @()
    foreach ($line in (Get-Content $log -Tail 2000)) {
        if ($line -match '^\[\s*\d+\s*-\s*[^\]]+\]\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s') {
            # TryParseExact needs genuinely typed culture/style args; passing $null and
            # the string 'None' fails overload resolution in Windows PowerShell 5.1.
            $ts = [datetime]::MinValue
            $parsed = [datetime]::TryParseExact(
                $Matches[1],
                'yyyy-MM-dd HH:mm:ss',
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None,
                [ref]$ts)
            if ($parsed -and $ts -ge $Since -and $line -match $Pattern) { $out += $line }
        }
    }
    # ",$out" prevents a single-element array unrolling to a scalar, but applied to an
    # EMPTY array it produces a one-element array containing an empty array -- so callers
    # saw Count=1 and printed a blank "error". Return a real empty array in that case.
    if ($out.Count -eq 0) { return @() }
    return ,$out
}

function Save-State {
    param([string]$Key, $Value)
    $f = Join-Path $script:StateDir "$Key.txt"
    Write-TextFile -Path $f -Lines @([string]$Value)
}

function Get-State {
    param([string]$Key)
    $f = Join-Path $script:StateDir "$Key.txt"
    if (Test-Path $f) { return (Get-Content $f -Raw).Trim() }
    return $null
}
