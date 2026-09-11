$ok = $true
function Check($name, [bool]$cond, $detail='') {
    if ($cond) { Write-Host "    [PASS] $name  $detail" -ForegroundColor Green }
    else       { Write-Host "    [FAIL] $name  $detail" -ForegroundColor Red; $script:ok = $false }
}

Write-Host "==> VERDICT"
$base = 'C:\Program Files (x86)\ossec-agent'
Check "Policy file present" (Test-Path "$base\ruleset\sca\cdac_win_baseline.yml")
Check "sca.remote_commands enabled" ((Test-Path "$base\local_internal_options.conf") -and ((Get-Content "$base\local_internal_options.conf" -Raw) -match 'sca\.remote_commands\s*=\s*1'))
Check "ossec.conf references the policy" ((Test-Path "$base\ossec.conf") -and ((Get-Content "$base\ossec.conf" -Raw) -match 'cdac_win_baseline'))

$log = Get-Content "$base\ossec.log" -Tail 300 -ErrorAction SilentlyContinue
$loaded = $log | Select-String "Loaded policy.*cdac_win_baseline" | Select-Object -Last 1
$evaluated = $log | Select-String "Evaluation finished.*cdac_win_baseline" | Select-Object -Last 1
Check "Policy loaded (recent log)" ([bool]$loaded) "$($loaded.Line)"
Check "Evaluation completed (recent log)" ([bool]$evaluated) "$($evaluated.Line)"

if ($ok) { Write-Host "`nAll checks passed. Check the dashboard's SCA tab for the agent for the actual score." -ForegroundColor Green }
else     { Write-Host "`nSome checks failed -- see above." -ForegroundColor Yellow }
