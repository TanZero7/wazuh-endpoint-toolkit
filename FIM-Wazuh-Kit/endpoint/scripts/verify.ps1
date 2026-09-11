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
else     { Write-Host "`nSome checks failed -- see above." -ForegroundColor Yellow }
