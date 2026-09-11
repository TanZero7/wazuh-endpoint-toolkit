$ok = $true
function Check($name, [bool]$cond, $detail='') {
    if ($cond) { Write-Host "    [PASS] $name  $detail" -ForegroundColor Green }
    else       { Write-Host "    [FAIL] $name  $detail" -ForegroundColor Red; $script:ok = $false }
}
Write-Host "==> VERDICT"
$channel = 'Microsoft-Windows-Partition/Diagnostic'
$log = Get-WinEvent -ListLog $channel -ErrorAction SilentlyContinue
Check "Channel enabled" ($log -and $log.IsEnabled) "records=$($log.RecordCount)"

$base = 'C:\Program Files (x86)\ossec-agent'
Check "ossec.conf wired to the channel" ((Test-Path "$base\ossec.conf") -and ((Get-Content "$base\ossec.conf" -Raw) -match [regex]::Escape($channel)))

$lcState = Get-Content "$base\wazuh-logcollector.state" -Raw -ErrorAction SilentlyContinue
Check "Agent tailing the channel" ($lcState -match [regex]::Escape($channel))

if ($ok) {
    Write-Host "`nAll static checks passed. This cannot be fully proven without plugging in a real USB device -- see INTEGRATION-GUIDE.md section 4." -ForegroundColor Green
} else {
    Write-Host "`nSome checks failed -- see above." -ForegroundColor Yellow
}
