<#
    Suricata capture launcher.

    Installed to C:\Program Files\Suricata\suricata-launch.ps1 and run by scheduled tasks.
    DELIBERATELY SELF-CONTAINED: it does not dot-source the deployment kit, so the kit
    folder can be moved or deleted without breaking a running deployment.

    WHY THIS EXISTS
    ===============
    The naive approach pins one capture device into the service command line at configure
    time (-i \Device\NPF_{GUID}). That breaks the moment the machine changes how it
    connects: dock a laptop and traffic moves to Ethernet while Suricata keeps watching an
    idle Wi-Fi adapter, seeing nothing and reporting no error.

    Instead this enumerates every physical adapter at START time and passes one -i per
    adapter. Verified on Suricata 8.0.6 / Npcap 1.87: multiple -i flags are accepted, and
    an adapter in Disconnected state does NOT abort startup -- Suricata simply creates a
    capture thread per device ("Threads created -> RX: 2"). So a machine with both Wi-Fi
    and Ethernet is covered on both, whichever is actually carrying traffic, with no gap
    when the user switches between them and nothing to reconfigure.

    MODES
    -----
      (default)   stop anything running, then start fresh with the current adapter set
      -CheckOnly  watchdog: start only if not running, or if the adapter set has changed
                  since last launch. Cheap enough to run every few minutes.

    Exit codes: 0 = Suricata running on exit, 1 = failed to start.
#>

[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [int]$LogRetentionDays = 7
)

$ErrorActionPreference = 'Stop'

$SuricataDir = 'C:\Program Files\Suricata'
$SuricataExe = Join-Path $SuricataDir 'suricata.exe'
$Yaml        = Join-Path $SuricataDir 'suricata.yaml'
$LogDir      = Join-Path $SuricataDir 'log'
$StateFile   = Join-Path $SuricataDir 'launcher-state.txt'
$LauncherLog = Join-Path $LogDir 'launcher.log'

function Write-Log {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        Add-Content -Path $LauncherLog -Value $line -Encoding utf8
    } catch { }
}

<#
    Every physical adapter, regardless of link state.

    Disconnected adapters are included on purpose: Suricata tolerates them, and including
    them means plugging in a cable later needs no restart. Virtual adapters are excluded --
    capturing a VMware/Hyper-V switch would duplicate guest traffic that is already seen
    on the physical NIC it egresses through.
#>
function Get-CaptureAdapters {
    Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InterfaceDescription -notmatch 'VMware|Hyper-V|Virtual|Loopback|TAP-|VirtualBox|WAN Miniport|Bluetooth' -and
            $_.Status -ne 'Not Present' -and
            $_.InterfaceGuid
        } |
        Sort-Object Name
}

function Get-AdapterSignature {
    param($Adapters)
    ($Adapters | ForEach-Object { $_.InterfaceGuid } | Sort-Object) -join ','
}

# --------------------------------------------------------------------------
if (-not (Test-Path $SuricataExe)) { Write-Log "FATAL: $SuricataExe not found"; exit 1 }
if (-not (Test-Path $Yaml))        { Write-Log "FATAL: $Yaml not found"; exit 1 }

$adapters = @(Get-CaptureAdapters)
if ($adapters.Count -eq 0) { Write-Log 'FATAL: no physical adapters found'; exit 1 }

$signature = Get-AdapterSignature -Adapters $adapters
$running   = @(Get-Process -Name 'suricata' -ErrorAction SilentlyContinue)

if ($CheckOnly) {
    $lastSig = ''
    if (Test-Path $StateFile) { $lastSig = (Get-Content $StateFile -Raw).Trim() }

    if ($running.Count -gt 0 -and $lastSig -eq $signature) {
        # Healthy and watching the right set. Say nothing -- this runs on a timer and
        # should not fill the log with noise.
        exit 0
    }
    if ($running.Count -eq 0) { Write-Log 'Watchdog: Suricata not running, starting it' }
    else { Write-Log 'Watchdog: adapter set changed, restarting capture' }
}

# --------------------------------------------------------------------------
Write-Log "Adapters to capture ($($adapters.Count)):"
foreach ($a in $adapters) { Write-Log ("   {0,-22} {1,-13} {2}" -f $a.Name, $a.Status, $a.InterfaceGuid) }

if ($running.Count -gt 0) {
    Write-Log "Stopping existing suricata.exe (PID $($running.Id -join ', '))"
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

# One -i per adapter. Quoting matters: the config and log paths contain a space, and an
# unquoted "C:\Program Files\..." is parsed as two arguments.
$argParts = @("-c `"$Yaml`"")
foreach ($a in $adapters) { $argParts += "-i \Device\NPF_$($a.InterfaceGuid)" }
$argParts += "-l `"$LogDir`""
$argStr = $argParts -join ' '

Write-Log "Starting: suricata.exe $argStr"
try {
    Start-Process -FilePath $SuricataExe -ArgumentList $argStr -WindowStyle Hidden -WorkingDirectory $SuricataDir
} catch {
    Write-Log "FATAL: failed to start Suricata: $($_.Exception.Message)"
    exit 1
}

Start-Sleep -Seconds 12
$now = @(Get-Process -Name 'suricata' -ErrorAction SilentlyContinue)
if ($now.Count -eq 0) {
    Write-Log 'FATAL: Suricata exited immediately. See log\suricata.log'
    exit 1
}
Write-Log "Started OK (PID $($now.Id -join ', ')) on $($adapters.Count) adapter(s)"
Set-Content -Path $StateFile -Value $signature -Encoding ascii

# --------------------------------------------------------------------------
# Retention. eve.json rotates daily; without pruning, rotated copies accumulate forever.
try {
    $cut = (Get-Date).AddDays(-$LogRetentionDays)
    $old = @(Get-ChildItem $LogDir -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match '^eve\.json\.' -and $_.LastWriteTime -lt $cut })
    if ($old.Count -gt 0) {
        $mb = [math]::Round(($old | Measure-Object Length -Sum).Sum / 1MB, 1)
        $old | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Log "Pruned $($old.Count) rotated log(s) older than $LogRetentionDays days, freed ${mb} MB"
    }
    # Keep the launcher log itself bounded.
    if ((Test-Path $LauncherLog) -and (Get-Item $LauncherLog).Length -gt 2MB) {
        $keep = Get-Content $LauncherLog -Tail 500
        Set-Content -Path $LauncherLog -Value $keep -Encoding utf8
    }
} catch { Write-Log "Retention pass failed (non-fatal): $($_.Exception.Message)" }

exit 0
