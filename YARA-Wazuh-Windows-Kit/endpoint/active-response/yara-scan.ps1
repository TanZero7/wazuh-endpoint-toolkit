<#
  WAZUH TOOLKIT YARA active-response.
  Wazuh triggers this on FIM add/modify alerts (Desktop + Downloads). It reads
  the AR JSON payload from stdin, pulls the changed file's path, scans it with
  YARA, and appends one JSON result line to a log Wazuh tails (-> rules 100700
  match / 100701 clean).
#>
$ErrorActionPreference = 'SilentlyContinue'
$yara    = 'C:\Program Files\YARA\yara64.exe'
$index   = 'C:\Program Files\YARA\rules\index.yar'
$logDir  = 'C:\ProgramData\wazuh-toolkit\yara'
$logFile = Join-Path $logDir 'yara-results.log'
$dbgFile = Join-Path $logDir 'yara-scan-debug.log'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Dbg($msg) { "$(Get-Date -Format o)  $msg" | Add-Content -Path $dbgFile -Encoding utf8 }

# Wazuh's logcollector keeps this file open to tail it, which makes plain
# Add-Content fail with "being used by another process". Open explicitly with
# FileShare.ReadWrite so both processes can hold a handle at once.
function Emit($obj) {
    $line = ($obj | ConvertTo-Json -Compress)
    try {
        $fs = [System.IO.File]::Open($logFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $sw = New-Object System.IO.StreamWriter($fs)
        $sw.WriteLine($line)
        $sw.Flush(); $sw.Close(); $fs.Close()
        Dbg "emit OK: $line"
    } catch {
        Dbg "emit FAILED: $($_.Exception.Message)"
    }
}

Dbg "invoked"
# execd keeps the pipe open (in case a later "delete"/revert message follows
# for timeout-based commands), so ReadToEnd() blocks forever waiting for EOF
# that never comes. The AR message is one newline-terminated JSON line -
# read exactly that.
$raw = [Console]::In.ReadLine()
Dbg "raw length: $($raw.Length)"
if (-not $raw) { Dbg "empty raw, exiting"; exit 0 }

try { $j = $raw | ConvertFrom-Json } catch { Dbg "json parse failed: $($_.Exception.Message)"; exit 0 }
Dbg "parsed command=$($j.command)"
# This AR has no <timeout>, so Wazuh only ever sends the "do it" invocation
# (command = the AR name, e.g. "yara-scan0") - there is no "delete"/revert
# call to filter out here, unlike timeout-based (blocking) active responses.
if ($j.command -and $j.command -match '^delete') { Dbg "delete/revert call, exiting"; exit 0 }

$path = $j.parameters.alert.syscheck.path
Dbg "path=$path"
if (-not $path) { Dbg "no path, exiting"; exit 0 }
if (-not (Test-Path -LiteralPath $path)) { Dbg "path does not exist, exiting"; exit 0 }
if (-not (Test-Path $yara)) { Dbg "yara exe missing, exiting"; exit 0 }
if (-not (Test-Path $index)) { Dbg "index missing, exiting"; exit 0 }

$fi = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
if (-not $fi) { Dbg "Get-Item failed, exiting"; exit 0 }
if ($fi.Length -gt 100MB -or $fi.Length -eq 0) { Dbg "size out of range ($($fi.Length)), exiting"; exit 0 }

Dbg "about to scan, size=$($fi.Length)"
$out = & $yara -w -r $index $path 2>&1
Dbg "yara exit=$LASTEXITCODE out=[$($out -join '|')]"
$matches = @($out | Where-Object { $_ -and $_ -notmatch '^warning' })
Dbg "matches count=$($matches.Count)"

if ($matches.Count -gt 0) {
    foreach ($m in $matches) {
        $ruleName = ($m -split '\s+')[0]
        Emit @{
            integration        = 'yara'
            yara_rule           = $ruleName
            yara_scan_result    = 'match'
            yara_scanned_file   = $path
            agent               = $env:COMPUTERNAME
            timestamp           = (Get-Date).ToString('o')
        }
    }
} else {
    Emit @{
        integration       = 'yara'
        yara_scan_result  = 'clean'
        yara_scanned_file = $path
        agent             = $env:COMPUTERNAME
        timestamp         = (Get-Date).ToString('o')
    }
}
Dbg "done"
exit 0
