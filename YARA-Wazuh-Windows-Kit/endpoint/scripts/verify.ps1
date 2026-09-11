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

if ($ok) { Write-Host "`nAll static checks passed. For a full live test, see INTEGRATION-GUIDE.md section 5." -ForegroundColor Green }
else     { Write-Host "`nSome checks failed -- see above." -ForegroundColor Yellow }
