<#
    Stage 2 -- Install Suricata and load the Emerging Threats Open ruleset.

    Mirrors what the official Wazuh PoC does on Ubuntu (install Suricata, drop the ET
    Open ruleset in place) but for Windows, and without suricata-update -- the Windows
    MSI does not ship a reliable suricata-update, and pulling the ET tarball directly is
    exactly what the official guide does anyway.

    Idempotent: skips the MSI if the right version is already installed, and re-running
    just refreshes the ruleset. Use -RefreshRulesOnly for a rules-only update, which is
    what you would schedule daily.
#>

[CmdletBinding()]
param(
    [switch]$RefreshRulesOnly,
    [switch]$IncludeIndustrial,   # keep dnp3/modbus/enip rules (OT monitoring; needs yaml changes too)
    [switch]$Force
)

. "$PSScriptRoot\lib\common.ps1"
Start-Transcript-Safe -Name '02-install-suricata'

try {
    Assert-Elevated

    # Npcap gate. 02 can be run on its own, so preflight alone is not enough.
    $npcapOk = $false
    foreach ($rk in @('HKLM:\SOFTWARE\WOW6432Node\Npcap', 'HKLM:\SOFTWARE\Npcap')) {
        if (Test-Path $rk) { $npcapOk = $true; break }
    }
    if (-not $npcapOk) {
        Write-Fail 'Npcap is not installed. Suricata cannot capture without it.'
        Write-Info 'Install prereqs\npcap-1.87.exe with "WinPcap API-compatible Mode" ticked.'
        Stop-WithError 'Missing prerequisite: Npcap'
    }
    Write-Ok 'Npcap present'

    # --------------------------------------------------------------
    if (-not $RefreshRulesOnly) {
        Write-Step "Install Suricata $SuricataVersion"

        $alreadyOk = $false
        if (Test-Path $SuricataExe) {
            $vOut = (& $SuricataExe -V 2>&1 | Out-String).Trim()
            Write-Info "Existing install: $vOut"
            if ($vOut -match [regex]::Escape($SuricataVersion)) {
                Write-Ok "Suricata $SuricataVersion already installed."
                $alreadyOk = $true
            } else {
                Write-Warn "A different Suricata version is installed. The MSI will upgrade it in place."
            }
        }

        if (-not $alreadyOk -or $Force) {
            # Prefer a copy bundled by Get-Prerequisites.ps1 so the kit works offline.
            $bundled = Join-Path $KitRoot "prereqs\Suricata-$SuricataVersion-1-64bit.msi"
            $msiPath = if (Test-Path $bundled) { $bundled } else { Join-Path $env:TEMP "Suricata-$SuricataVersion-1-64bit.msi" }
            if (Test-Path $bundled) { Write-Info "Using bundled MSI from prereqs\" }

            if ((Test-Path $msiPath) -and -not $Force) {
                Write-Info "Reusing cached MSI at $msiPath"
            } else {
                Write-Info "Downloading $SuricataMsiUrl"
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $SuricataMsiUrl -OutFile $msiPath -UseBasicParsing -TimeoutSec 900
            }
            $sizeMb = [math]::Round((Get-Item $msiPath).Length / 1MB, 2)
            Write-Ok "MSI ready ($sizeMb MB)"

            $installLog = Join-Path $LogDir 'suricata-msi-install.log'
            $p = Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn /norestart /l*v `"$installLog`"" -Wait -PassThru
            if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
                Stop-WithError "Suricata MSI failed with exit code $($p.ExitCode). See $installLog"
            }
            Write-Ok 'Suricata installed'
        }

        if (-not (Test-Path $SuricataExe)) {
            Stop-WithError "suricata.exe not found at $SuricataExe after install."
        }
        Write-Ok ((& $SuricataExe -V 2>&1 | Out-String).Trim())
        Save-State 'suricata_installed' 'true'
    }

    # --------------------------------------------------------------
    Write-Step 'Ensure directory layout'
    foreach ($d in @($SuricataLogDir, $SuricataRuleDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null; Write-Ok "Created $d" }
        else { Write-Info "Exists: $d" }
    }

    # --------------------------------------------------------------
    Write-Step 'Download Emerging Threats Open ruleset'

    # Use a bundled copy when Get-Prerequisites.ps1 has provided one, so the kit works
    # on an endpoint with no internet access. -Force re-downloads, which is how you
    # refresh signatures.
    $bundledRules = Join-Path $KitRoot 'prereqs\emerging.rules.tar.gz'
    $extract = Join-Path $env:TEMP 'et-rules-extract'

    if ((Test-Path $bundledRules) -and -not $Force) {
        $tarPath = $bundledRules
        $sizeMb = [math]::Round((Get-Item $tarPath).Length / 1MB, 2)
        Write-Ok "Using bundled ruleset from prereqs ($sizeMb MB) -- no download needed"
        Write-Info 'Pass -Force to fetch a fresh copy from Emerging Threats instead.'
    } else {
        $tarPath = Join-Path $env:TEMP 'emerging.rules.tar.gz'
        Write-Info "URL: $EtRulesUrl"
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $EtRulesUrl -OutFile $tarPath -UseBasicParsing -TimeoutSec 600
        $sizeMb = [math]::Round((Get-Item $tarPath).Length / 1MB, 2)
        Write-Ok "Downloaded $sizeMb MB"
        # Refresh the bundled copy too, so the kit stays deployable offline.
        if (Test-Path (Split-Path $bundledRules)) {
            Copy-Item $tarPath $bundledRules -Force
            Write-Info 'Updated the bundled copy in prereqs'
        }
    }

    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
    New-Item -ItemType Directory -Path $extract -Force | Out-Null

    # Windows 10+ ships bsdtar as tar.exe, so no third-party extractor is needed.
    # $TarExe is an absolute path on purpose -- see the note in lib\common.ps1.
    if (-not (Test-Path $TarExe)) { Stop-WithError "bsdtar not found at $TarExe (Windows 10 1803+ required)" }
    & $TarExe -xzf $tarPath -C $extract
    if ($LASTEXITCODE -ne 0) { Stop-WithError "tar extraction failed (exit $LASTEXITCODE) using $TarExe" }

    $srcRules = Join-Path $extract 'rules'
    if (-not (Test-Path $srcRules)) { $srcRules = $extract }

    # @() for StrictMode-safe .Count when only one file is present.
    $ruleFiles = @(Get-ChildItem $srcRules -Filter '*.rules' -File)
    if ($ruleFiles.Count -eq 0) { Stop-WithError "No .rules files found under $srcRules" }

    Copy-Item (Join-Path $srcRules '*.rules') -Destination $SuricataRuleDir -Force
    Write-Ok "Copied $($ruleFiles.Count) rule files to $SuricataRuleDir"

    # The ET tarball ships its own classification/reference configs. Suricata needs the
    # classtype definitions these provide, otherwise rules referencing unknown classtypes
    # are rejected at load time.
    foreach ($cfg in @('classification.config', 'reference.config')) {
        $src = Join-Path $srcRules $cfg
        if (Test-Path $src) {
            Copy-Item $src -Destination $SuricataDir -Force
            Write-Ok "Updated $cfg"
        }
    }

    # @() wrapper is required: under Set-StrictMode, a Where-Object that matches nothing
    # yields $null, and $null.Count throws PropertyNotFoundStrict. Several ET files
    # (e.g. emerging-deleted.rules) are entirely commented out and hit exactly that.
    $totalRules = 0
    foreach ($f in $ruleFiles) {
        $totalRules += @(Get-Content $f.FullName | Where-Object { $_ -match '^\s*(alert|drop|pass|reject)' }).Count
    }
    Write-Ok "Approximately $totalRules signatures available"
    Save-State 'et_rules_count' $totalRules

    # --------------------------------------------------------------
    Write-Step 'Sanitize ruleset for this Suricata build'
    #
    # The ET Open ruleset and Suricata's own bundled rules both assume a full-featured
    # Linux build. Two classes of rule cannot load on the official Windows MSI, and each
    # one is fatal: Suricata aborts with "Loading signatures failed" rather than skipping
    # them, so the whole ruleset fails to load over a handful of unusable signatures.
    #
    # This step neutralises exactly those, and nothing else. It is re-run on every
    # ruleset refresh, because refreshing restores the originals.

    # 1. Industrial protocol rules. dnp3/modbus/enip are disabled under app-layer in the
    #    stock Windows suricata.yaml, and a rule whose protocol is disabled is a hard
    #    parse error. These are SCADA/OT protocols that will never appear on an endpoint,
    #    so disabling the rule files is correct here. To monitor OT instead, set
    #    enabled: yes for those protocols in suricata.yaml and pass -IncludeIndustrial.
    if (-not $IncludeIndustrial) {
        $industrial = @('dnp3-events.rules', 'modbus-events.rules', 'enip-events.rules')
        foreach ($f in $industrial) {
            $p = Join-Path $SuricataRuleDir $f
            if (Test-Path $p) {
                Move-Item $p "$p.disabled" -Force
                Write-Ok "Disabled $f (protocol not enabled in suricata.yaml)"
            }
        }
    } else {
        Write-Warn 'IncludeIndustrial set: dnp3/modbus/enip rules kept. Enable those protocols under app-layer in suricata.yaml or validation WILL fail.'
    }

    # 2. file.magic rules. The official Windows build reports "Libmagic support: no"
    #    (verify with: suricata.exe --build-info), so file.magic is an unknown keyword
    #    and every rule using it is a parse error. Comment them out individually rather
    #    than dropping whole files, since they sit among thousands of working rules.
    $magicDisabled = 0
    foreach ($f in (Get-ChildItem $SuricataRuleDir -Filter '*.rules' -File)) {
        $content = Get-Content $f.FullName
        $hit = @($content | Where-Object { $_ -match 'file\.magic' -and $_ -notmatch '^\s*#' })
        if ($hit.Count -gt 0) {
            $new = $content | ForEach-Object {
                if ($_ -match 'file\.magic' -and $_ -notmatch '^\s*#') { "# [DISABLED: no libmagic on Windows] $_" } else { $_ }
            }
            # Write-TextFile, not Set-Content: a BOM here makes line 1's "#" stop being a
            # comment and Suricata fails the entire ruleset load. See lib\common.ps1.
            Write-TextFile -Path $f.FullName -Lines $new
            $magicDisabled += $hit.Count
            Write-Info "$($f.Name): commented out $($hit.Count) file.magic rule(s)"
        }
    }
    if ($magicDisabled -gt 0) { Write-Ok "Disabled $magicDisabled file.magic rule(s) unsupported by this build" }
    else { Write-Info 'No active file.magic rules found' }

    # --------------------------------------------------------------
    Write-Step 'Install local custom rules'
    $localSrc = Join-Path $KitRoot 'config\local.rules'
    if (Test-Path $localSrc) {
        Copy-Item $localSrc -Destination (Join-Path $SuricataRuleDir 'local.rules') -Force
        Write-Ok 'local.rules installed'
    } else {
        Write-Warn "Kit local.rules not found at $localSrc"
    }

    Write-Step 'Stage 2 complete'
    Write-Info 'Ruleset is on disk but NOT yet loaded -- suricata.yaml still points at defaults.'
    Write-Info 'Next: .\03-configure-suricata.ps1'
}
finally {
    Stop-Transcript-Safe
}
