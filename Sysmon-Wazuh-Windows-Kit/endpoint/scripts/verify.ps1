<#
    Stage 3 -- Verify. Changes nothing. Pass/fail per check.
#>
$ok = $true
function Check($name, [bool]$cond, $detail='') {
    if ($cond) { Write-Host "    [PASS] $name  $detail" -ForegroundColor Green }
    else       { Write-Host "    [FAIL] $name  $detail" -ForegroundColor Red; $script:ok = $false }
}

Write-Host "==> VERDICT"
$svc = Get-Service -Name Sysmon64,Sysmon -ErrorAction SilentlyContinue
Check "Sysmon service running" ($svc -and $svc.Status -eq 'Running') "$($svc.Name) = $($svc.Status)"

$drv = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\SysmonDrv' -ErrorAction SilentlyContinue
Check "Sysmon driver registered" ([bool]$drv) "Start=$($drv.Start)"

$log = Get-WinEvent -ListLog 'Microsoft-Windows-Sysmon/Operational' -ErrorAction SilentlyContinue
Check "Operational log enabled" ($log -and $log.IsEnabled) "records=$($log.RecordCount)"

$recent = Get-WinEvent -LogName 'Microsoft-Windows-Sysmon/Operational' -MaxEvents 1 -ErrorAction SilentlyContinue
Check "Recent Sysmon events present" ([bool]$recent) "$($recent.TimeCreated)"

$ossec = 'C:\Program Files (x86)\ossec-agent\ossec.conf'
$wired = (Test-Path $ossec) -and ((Get-Content $ossec -Raw) -match 'Microsoft-Windows-Sysmon/Operational')
Check "Wazuh agent wired to Sysmon channel" $wired

$lcState = 'C:\Program Files (x86)\ossec-agent\wazuh-logcollector.state'
$collecting = (Test-Path $lcState) -and ((Get-Content $lcState -Raw) -match 'Sysmon')
Check "Wazuh logcollector tailing the channel" $collecting

if ($ok) { Write-Host "`nAll checks passed." -ForegroundColor Green }
else     { Write-Host "`nSome checks failed -- see above." -ForegroundColor Yellow }
