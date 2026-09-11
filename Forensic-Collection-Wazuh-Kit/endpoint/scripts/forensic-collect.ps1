<#
  WAZUH TOOLKIT endpoint forensic snapshot collector.
  Runs on an interval (Wazuh command wodle). Writes a full timestamped snapshot to
  C:\ProgramData\wazuh-toolkit\forensics\ for the evidence trail, prunes to a retention
  window, and ALWAYS prints one compact JSON summary line to stdout (captured by
  Wazuh -> rule 100800) even if individual collectors fail.
  Read-only: inspects state, changes nothing.
#>
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$root    = 'C:\ProgramData\wazuh-toolkit\forensics'
$retDays = 14
$ts      = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir  = Join-Path $root $ts
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

function Try-Save([string]$name, [scriptblock]$get) {
    try {
        $v = & $get
        $v | ConvertTo-Json -Depth 6 -Compress -ErrorAction Stop |
            Set-Content -Path (Join-Path $outDir "$name.json") -Encoding utf8
    } catch {
        "collector '$name' failed: $($_.Exception.Message)" |
            Set-Content -Path (Join-Path $outDir "$name.ERROR.txt") -Encoding utf8
    }
}

Try-Save 'processes'   { Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,CommandLine,ExecutablePath,CreationDate }
Try-Save 'services'    { Get-CimInstance Win32_Service | Select-Object Name,DisplayName,State,StartMode,PathName,StartName }
Try-Save 'nettcp'      { Get-NetTCPConnection | Select-Object LocalAddress,LocalPort,RemoteAddress,RemotePort,State,OwningProcess }
Try-Save 'netudp'      { Get-NetUDPEndpoint | Select-Object LocalAddress,LocalPort,OwningProcess }
Try-Save 'sessions'    { (quser) 2>$null }
Try-Save 'logons'      { Get-CimInstance Win32_LoggedOnUser | Select-Object Antecedent,Dependent }
Try-Save 'localadmins' { (net localgroup administrators) 2>$null }
Try-Save 'arp'         { Get-NetNeighbor -AddressFamily IPv4 | Select-Object IPAddress,LinkLayerAddress,State,InterfaceAlias }
Try-Save 'dnscache'    { Get-DnsClientCache | Select-Object Entry,Name,Data,Type }
Try-Save 'shares'      { Get-SmbShare | Select-Object Name,Path,Description }
Try-Save 'autoruns'    {
    $keys = @(
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
      'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Run',
      'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')
    foreach ($k in $keys) { if (Test-Path $k) { $i = Get-Item $k; foreach ($n in $i.GetValueNames()) { [pscustomobject]@{Key=$k;Name=$n;Value=$i.GetValue($n)} } } }
}
Try-Save 'scheduledtasks' { Get-ScheduledTask | Where-Object State -ne 'Disabled' | Select-Object TaskName,TaskPath,@{n='Action';e={($_.Actions | ForEach-Object {"$($_.Execute) $($_.Arguments)"}) -join ' | '}} }
Try-Save 'startup_folder' { Get-ChildItem 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp','C:\Users\*\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup' -Recurse -File | Select-Object FullName,LastWriteTime,Length }
Try-Save 'recent_files'  { Get-ChildItem 'C:\Users\*\Downloads','C:\Users\*\Desktop' -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 150 FullName,Length,LastWriteTime,CreationTime }
Try-Save 'usbstor'       { Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USBSTOR' | ForEach-Object { $_.PSChildName } }
Try-Save 'defender'      { Get-MpPreference | Select-Object ExclusionPath,ExclusionExtension,ExclusionProcess,DisableRealtimeMonitoring }
Try-Save 'firewall'      { Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction }

# prune
try { Get-ChildItem $root -Directory | Where-Object { $_.CreationTime -lt (Get-Date).AddDays(-$retDays) } | Remove-Item -Recurse -Force } catch {}

# ---- summary line (each field guarded) ----
function G([scriptblock]$b, $d='') { try { $v = & $b; if ($null -ne $v) { $v } else { $d } } catch { $d } }

$summary = [ordered]@{
    wazuh-toolkit_forensic  = 'true'
    host           = $env:COMPUTERNAME
    timestamp      = (Get-Date).ToString('o')
    snapshot_dir   = $outDir
    proc_count     = [string](G { (Get-Process).Count } 0)
    estab_conns    = [string](G { (Get-NetTCPConnection -State Established).Count } 0)
    listeners      = [string](G { (Get-NetTCPConnection -State Listen).Count } 0)
    local_admins   = [string](G { ((net localgroup administrators) | Where-Object { $_ -and $_ -notmatch '---|command completed|^Alias|^Comment|^Members|^\s*$' }) -join ';' } '')
    usbstor_count  = [string](G { (Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USBSTOR' | Measure-Object).Count } 0)
    logged_on      = [string](G { ((quser) 2>$null | Select-Object -Skip 1) -join ' / ' } '')
    snapshots_kept = [string](G { (Get-ChildItem $root -Directory | Measure-Object).Count } 0)
}
$summary | ConvertTo-Json -Compress
