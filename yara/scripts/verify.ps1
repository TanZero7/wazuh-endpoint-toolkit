<#
    Stage 3 -- Verify. Changes nothing except a throwaway self-test file
    under %TEMP% (removed after the check).
#>
$ok = $true
function Check($name, [bool]$cond, $detail='') {
    if ($cond) { Write-Host "    [PASS] $name  $detail" -ForegroundColor Green }
    else       { Write-Host "    [FAIL] $name  $detail" -ForegroundColor Red; $script:ok = $false }
}

Write-Host "==> VERDICT"
$exe   = 'C:\Program Files\YARA\yara64.exe'
$index = 'C:\Program Files\YARA\rules\index.yar'
Check "YARA installed" (Test-Path $exe) $exe
Check "Rule index present" (Test-Path $index) $index

if ((Test-Path $exe) -and (Test-Path $index)) {
    $tmp = Join-Path $env:TEMP "yara-selftest-$(Get-Random).txt"
    "benign content, no marker here" | Set-Content $tmp -Encoding ascii
    $global:PSNativeCommandUseErrorActionPreference = $false
    $null = & $exe -w $index $tmp 2>&1
    Check "Index compiles + scans without error" ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

$bin = 'C:\Program Files (x86)\ossec-agent\active-response\bin'
Check "yara-scan.cmd deployed"  (Test-Path (Join-Path $bin 'yara-scan.cmd'))
Check "yara-scan.ps1 deployed"  (Test-Path (Join-Path $bin 'yara-scan.ps1'))

$ar = 'C:\Program Files (x86)\ossec-agent\shared\ar.conf'
$arOk = (Test-Path $ar) -and ((Get-Content $ar -Raw) -match 'yara-scan')
Check "Manager has pushed yara-scan into ar.conf" $arOk "(requires the server-side active-response block to be installed)"

$results = 'C:\ProgramData\wazuh-toolkit\yara\yara-results.log'
Check "Results log exists" (Test-Path $results) $results

$ossec = 'C:\Program Files (x86)\ossec-agent\ossec.conf'
$wired = (Test-Path $ossec) -and ((Get-Content $ossec -Raw) -match 'yara-results\.log')
Check "Agent wired to read the results log" $wired

if ($ok) {
    # [fix] was "section 5" -- section 5 is just the "Observed on a
    # real deployment" metrics table. The actual live-test steps are in 4.2.
    Write-Host "`nAll static checks passed. For a full live test, see INTEGRATION-GUIDE.md section 4.2." -ForegroundColor Green
} else {
    Write-Host "`nSome checks failed -- see above." -ForegroundColor Yellow
    # [fix] The "ar.conf" check above depends on the MANAGER pushing
    # yara-scan into shared\ar.conf, which happens on its own periodic cycle --
    # it is not instant, even right after the server-side steps are completed
    # and the manager is restarted. This is a different mechanism from the
    # logcollector-state races the other kits' verify scripts warn about (this
    # one isn't reading a state file that catches up after an agent restart --
    # it's waiting on the manager's own push cycle to reach this agent).
    if (-not $arOk) {
        Write-Host "If 'Manager has pushed yara-scan into ar.conf' failed, wait 5-10 minutes after installation and run this script again before troubleshooting further -- the manager pushes ar.conf out on its own cycle. If it keeps failing, the manager side (wazuh-manager-toolkit/yara) is not done yet." -ForegroundColor Yellow
    }
}
