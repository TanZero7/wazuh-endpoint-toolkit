$ok = $true
function Check($name, [bool]$cond, $detail='') {
    if ($cond) { Write-Host "    [PASS] $name  $detail" -ForegroundColor Green }
    else       { Write-Host "    [FAIL] $name  $detail" -ForegroundColor Red; $script:ok = $false }
}
Write-Host "==> VERDICT"
$base = 'C:\Program Files (x86)\ossec-agent'
Check "Collector deployed" (Test-Path "$base\active-response\bin\forensic-collect.ps1")
Check "wazuh_command.remote_commands enabled" ((Test-Path "$base\local_internal_options.conf") -and ((Get-Content "$base\local_internal_options.conf" -Raw) -match 'wazuh_command\.remote_commands\s*=\s*1'))
Check "ossec.conf has the wodle" ((Test-Path "$base\ossec.conf") -and ((Get-Content "$base\ossec.conf" -Raw) -match 'wazuh-toolkit-forensic-snapshot'))

$snapRoot = 'C:\ProgramData\wazuh-toolkit\forensics'
$snaps = Get-ChildItem $snapRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
Check "At least one snapshot exists" ($snaps.Count -gt 0) "$($snaps.Count) kept"
if ($snaps.Count -gt 0) {
    $files = Get-ChildItem $snaps[0].FullName -ErrorAction SilentlyContinue
    Check "Newest snapshot has data files" ($files.Count -ge 5) "$($files.Count) files in $($snaps[0].Name)"
}

$log = Get-Content "$base\ossec.log" -Tail 200 -ErrorAction SilentlyContinue
$ran = $log | Select-String "command:wazuh-toolkit-forensic-snapshot" | Select-Object -Last 1
Check "wodle command module ran (recent log)" ([bool]$ran)

if ($ok) { Write-Host "`nAll checks passed." -ForegroundColor Green }
else     { Write-Host "`nSome checks failed -- see above." -ForegroundColor Yellow }
