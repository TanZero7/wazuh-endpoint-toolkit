$ok = $true
function Check($name, [bool]$cond, $detail='') {
    if ($cond) { Write-Host "    [PASS] $name  $detail" -ForegroundColor Green }
    else       { Write-Host "    [FAIL] $name  $detail" -ForegroundColor Red; $script:ok = $false }
}
Write-Host "==> VERDICT"
$base = 'C:\Program Files (x86)\ossec-agent'
Check "ossec.conf has the FIM scope" ((Test-Path "$base\ossec.conf") -and ((Get-Content "$base\ossec.conf" -Raw) -match [regex]::Escape('C:\Users\*\Desktop')))

$log = Get-Content "$base\ossec.log" -Tail 400 -ErrorAction SilentlyContinue
$rt = $log | Select-String 'Real-time file integrity monitoring started' | Select-Object -Last 1
Check "Realtime engine started (recent log)" ([bool]$rt) "$($rt.Line)"

$watching = $log | Select-String 'Monitoring path.*desktop' | Select-Object -Last 1
Check "Agent confirms watching a Desktop path" ([bool]$watching)

if ($ok) { Write-Host "`nAll checks passed. Live test: create/edit a file in Desktop or Downloads and check the dashboard for rule 550/554 within a couple seconds." -ForegroundColor Green }
else {
    Write-Host "`nSome checks failed -- see above." -ForegroundColor Yellow
    # [fix] Some of the checks above read a log/state file that only catches up a
    # few minutes after the agent restarts. Do not treat a FAIL right after setup as broken --
    # wait and recheck first.
    Write-Host "If this just ran right after setup, wait about 10 minutes and run this script again before troubleshooting further -- some checks read log/state files that take a few minutes to catch up after a restart." -ForegroundColor Yellow
}
