<#
    Download every installer the deployment needs into endpoint\prereqs\.

    WHY THIS EXISTS
    ===============
    Without it the kit is not self-contained: scripts 02 and 01 fetch the Suricata MSI,
    the ET ruleset and the Wazuh agent from the internet at deploy time, and Npcap has to
    be found and installed by hand. That means every endpoint needs internet access and a
    manual GUI step.

    Run this ONCE on a machine with internet, then copy the whole kit to each endpoint.
    Scripts 01 and 02 automatically prefer a local copy in prereqs\ over downloading.

    Run with -Verify to re-check what is already present without downloading anything.
#>

[CmdletBinding()]
param(
    [string]$AgentVersion = '4.14.7',   # match your Wazuh MANAGER version
    [switch]$Verify,
    [switch]$Force
)

. "$PSScriptRoot\lib\common.ps1"

$PrereqDir = Join-Path $KitRoot 'prereqs'
if (-not (Test-Path $PrereqDir)) { New-Item -ItemType Directory -Path $PrereqDir -Force | Out-Null }

# Npcap is listed first deliberately: it is the only hard prerequisite that cannot be
# installed silently in the free edition, so it needs a human at the machine.
$items = @(
    @{ Name = 'Npcap installer'
       File = 'npcap-1.87.exe'
       Url  = 'https://npcap.com/dist/npcap-1.87.exe'
       Note = 'MANUAL install, tick "WinPcap API-compatible Mode"' }
    @{ Name = 'Suricata MSI'
       File = "Suricata-$SuricataVersion-1-64bit.msi"
       Url  = $SuricataMsiUrl
       Note = 'used by 02-install-suricata.ps1' }
    @{ Name = 'ET Open ruleset'
       File = 'emerging.rules.tar.gz'
       Url  = $EtRulesUrl
       Note = 'used by 02-install-suricata.ps1; refresh periodically' }
    @{ Name = "Wazuh agent MSI $AgentVersion"
       File = "wazuh-agent-$AgentVersion-1.msi"
       Url  = "https://packages.wazuh.com/4.x/windows/wazuh-agent-$AgentVersion-1.msi"
       Note = 'only needed if the agent is not already installed' }
)

Write-Step "Prerequisites in $PrereqDir"
$missing = 0
foreach ($i in $items) {
    $path = Join-Path $PrereqDir $i.File
    $have = Test-Path $path

    if ($have -and -not $Force) {
        $mb = [math]::Round((Get-Item $path).Length / 1MB, 1)
        Write-Ok ("{0,-28} present ({1} MB)" -f $i.Name, $mb)
        Write-Info "    $($i.Note)"
        continue
    }
    if ($Verify) { Write-Fail ("{0,-28} MISSING" -f $i.Name); $missing++; continue }

    Write-Info "Downloading $($i.Name)..."
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $i.Url -OutFile $path -UseBasicParsing -TimeoutSec 900
        $mb = [math]::Round((Get-Item $path).Length / 1MB, 1)
        Write-Ok ("{0,-28} downloaded ({1} MB)" -f $i.Name, $mb)
        Write-Info "    $($i.Note)"
    } catch {
        Write-Fail ("{0,-28} FAILED: {1}" -f $i.Name, $_.Exception.Message)
        $missing++
    }
}

Write-Step 'Summary'
if ($missing -eq 0) {
    Write-Ok 'All prerequisites are present. The kit can now be deployed without internet access,'
    Write-Ok 'except for periodic ruleset refreshes.'
} else {
    Write-Warn "$missing prerequisite(s) missing. Run without -Verify to download them."
}

Write-Host ''
Write-Host '  Npcap still needs a human:' -ForegroundColor White
Write-Host '    prereqs\npcap-1.87.exe  ->  tick "Install Npcap in WinPcap API-compatible Mode"' -ForegroundColor White
Write-Host '    The free edition has no supported silent-install switch, so this one step' -ForegroundColor Gray
Write-Host '    cannot be automated. Everything after it can.' -ForegroundColor Gray
