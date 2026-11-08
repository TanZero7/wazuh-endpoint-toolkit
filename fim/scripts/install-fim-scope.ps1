<#
    Add Desktop + Downloads (all user profiles) to Wazuh FIM, realtime,
    with new-file alerting on. Idempotent.

    Deliberately realtime, NOT whodata: whodata sets a SACL on every
    wildcard-expanded path, including Windows service/virtual profiles
    (TEMP.Font Driver Host, UMFD-0, etc.) that exist on some machines -- this
    was measured to stall the first-run FIM baseline scan from ~1 minute to
    2.5+ minutes on a real deployment, for no detection benefit on those
    paths. "Who changed it" is available from Sysmon (EID 11) if that kit is
    also installed, without paying the whodata cost here.

    [fix] The original script only checked whether the literal
    string "C:\Users\*\Desktop" appeared ANYWHERE in ossec.conf, and if not,
    inserted a brand-new, second <syscheck>...</syscheck> block right before
    </ossec_config>. Every Windows Wazuh agent ships with its own default
    <syscheck> block already present (system dirs, registry monitoring,
    synchronization, max_eps, etc.) -- so on every real machine (not just a
    stripped-down test image) this would produce TWO <syscheck> blocks, which
    is undefined/duplicated FIM behavior. Confirmed live on a real endpoint
    during field deployment. Fixed by locating the EXISTING <syscheck>
    block with a regex, editing the four pieces (Desktop directory, Downloads
    directory, alert_new_files, the temp-file ignore line) INTO that same
    block, and writing it back in place -- so there is still only ever one
    <syscheck> block afterward. Each piece is still added idempotently
    (checked individually), and the script now refuses to run at all if it
    can't find a complete existing <syscheck>...</syscheck> block, rather
    than guessing and creating a new one. Verified end-to-end on two endpoints:
    FIM rules 554 (added) / 550 (modified) / 553 (deleted)
    all fired correctly afterward.
#>

[CmdletBinding()]
param(
    [string]$WazuhDir = 'C:\Program Files (x86)\ossec-agent'
)

$ErrorActionPreference = 'Stop'

function Assert-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)

    if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )) {
        throw "Run this script from an elevated (Administrator) PowerShell session."
    }
}

Assert-Elevated

$ossec = Join-Path $WazuhDir 'ossec.conf'

if (-not (Test-Path $ossec)) {
    throw "Wazuh ossec.conf not found: $ossec"
}

Write-Host "`n=== Wazuh FIM: Desktop + Downloads ===" -ForegroundColor Cyan

# -------------------------------------------------------------------
# Read configuration
# -------------------------------------------------------------------

$conf = Get-Content $ossec -Raw

if ($conf -notmatch '<syscheck\b[^>]*>') {
    throw "No existing <syscheck> block found. Refusing to create a new one."
}

if ($conf -notmatch '</syscheck>') {
    throw "Existing <syscheck> opening tag found, but closing </syscheck> is missing. Refusing to modify."
}

Write-Host "[OK] Existing <syscheck> block found."

# -------------------------------------------------------------------
# Backup
# -------------------------------------------------------------------

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "$ossec.bak-fim-$timestamp"

Copy-Item $ossec $backup -Force

Write-Host "[OK] Backup created:"
Write-Host "     $backup"

# -------------------------------------------------------------------
# Locate the existing syscheck block
# -------------------------------------------------------------------

$syscheckPattern = '(?s)<syscheck\b[^>]*>.*?</syscheck>'
$match = [regex]::Match($conf, $syscheckPattern)

if (-not $match.Success) {
    throw "Could not safely locate the complete <syscheck> block."
}

$syscheck = $match.Value

# -------------------------------------------------------------------
# Desktop
# -------------------------------------------------------------------

$desktopEntry = '    <directories check_all="yes" realtime="yes">C:\Users\*\Desktop</directories>'

if ($syscheck -match [regex]::Escape('C:\Users\*\Desktop')) {
    Write-Host "[OK] Desktop FIM entry already exists."
}
else {
    # Insert immediately before the first existing <ignore> entry.
    $ignoreMatch = [regex]::Match($syscheck, '(?m)^\s*<ignore\b')

    if ($ignoreMatch.Success) {
        $insertPos = $ignoreMatch.Index

        $syscheck =
            $syscheck.Substring(0, $insertPos) +
            $desktopEntry + "`r`n`r`n" +
            $syscheck.Substring($insertPos)

        Write-Host "[ADDED] C:\Users\*\Desktop"
    }
    else {
        # Safe fallback: insert immediately before </syscheck>
        $closePos = $syscheck.LastIndexOf('</syscheck>')

        if ($closePos -lt 0) {
            throw "Could not locate </syscheck>."
        }

        $syscheck =
            $syscheck.Substring(0, $closePos) +
            "`r`n$desktopEntry`r`n" +
            $syscheck.Substring($closePos)

        Write-Host "[ADDED] C:\Users\*\Desktop"
    }
}

# -------------------------------------------------------------------
# Downloads
# -------------------------------------------------------------------

$downloadsEntry = '    <directories check_all="yes" realtime="yes">C:\Users\*\Downloads</directories>'

if ($syscheck -match [regex]::Escape('C:\Users\*\Downloads')) {
    Write-Host "[OK] Downloads FIM entry already exists."
}
else {
    $ignoreMatch = [regex]::Match($syscheck, '(?m)^\s*<ignore\b')

    if ($ignoreMatch.Success) {
        $insertPos = $ignoreMatch.Index

        $syscheck =
            $syscheck.Substring(0, $insertPos) +
            $downloadsEntry + "`r`n`r`n" +
            $syscheck.Substring($insertPos)

        Write-Host "[ADDED] C:\Users\*\Downloads"
    }
    else {
        $closePos = $syscheck.LastIndexOf('</syscheck>')

        if ($closePos -lt 0) {
            throw "Could not locate </syscheck>."
        }

        $syscheck =
            $syscheck.Substring(0, $closePos) +
            "`r`n$downloadsEntry`r`n" +
            $syscheck.Substring($closePos)

        Write-Host "[ADDED] C:\Users\*\Downloads"
    }
}

# -------------------------------------------------------------------
# New-file alerting
# -------------------------------------------------------------------

if ($syscheck -match '<alert_new_files>\s*yes\s*</alert_new_files>') {
    Write-Host "[OK] New-file alerting is already enabled."
}
else {
    $openTag = [regex]::Match($syscheck, '<syscheck\b[^>]*>')

    if (-not $openTag.Success) {
        throw "Could not locate <syscheck> opening tag."
    }

    $insertPos = $openTag.Index + $openTag.Length

    $syscheck =
        $syscheck.Substring(0, $insertPos) +
        "`r`n`r`n    <alert_new_files>yes</alert_new_files>" +
        $syscheck.Substring($insertPos)

    Write-Host "[ADDED] alert_new_files=yes"
}

# -------------------------------------------------------------------
# Temporary-file exclusions
# -------------------------------------------------------------------

$tempIgnore = '    <ignore type="sregex">\.tmp$|\.temp$|\.crdownload$|\.part$|\.partial$|\.~lock|desktop\.ini$|thumbs\.db$</ignore>'

if ($syscheck -match [regex]::Escape('\.crdownload$')) {
    Write-Host "[OK] Temporary-file exclusion already exists."
}
else {
    $closePos = $syscheck.LastIndexOf('</syscheck>')

    if ($closePos -lt 0) {
        throw "Could not locate </syscheck>."
    }

    $syscheck =
        $syscheck.Substring(0, $closePos) +
        "`r`n$tempIgnore`r`n" +
        $syscheck.Substring($closePos)

    Write-Host "[ADDED] Temporary-file exclusions."
}

# -------------------------------------------------------------------
# Replace ONLY the existing syscheck block
# -------------------------------------------------------------------

$conf =
    $conf.Substring(0, $match.Index) +
    $syscheck +
    $conf.Substring($match.Index + $match.Length)

# -------------------------------------------------------------------
# Write configuration
# -------------------------------------------------------------------

[IO.File]::WriteAllText(
    $ossec,
    $conf,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Host "`n[OK] ossec.conf updated successfully."

# -------------------------------------------------------------------
# Show the relevant configuration
# -------------------------------------------------------------------

Write-Host "`n=== Resulting FIM entries ===" -ForegroundColor Cyan

$finalConf = Get-Content $ossec -Raw
$finalSyscheck = [regex]::Match(
    $finalConf,
    '(?s)<syscheck\b[^>]*>.*?</syscheck>'
).Value

$finalSyscheck -split "`r?`n" |
    Where-Object {
        $_ -match 'Users.*(Desktop|Downloads)' -or
        $_ -match 'alert_new_files'
    } |
    ForEach-Object {
        Write-Host $_
    }

# -------------------------------------------------------------------
# Restart Wazuh
# -------------------------------------------------------------------

Write-Host "`nRestarting WazuhSvc..." -ForegroundColor Cyan

Restart-Service -Name WazuhSvc -Force

(Get-Service WazuhSvc).WaitForStatus(
    'Running',
    '00:01:00'
)

Write-Host "[OK] WazuhSvc is running."

Write-Host "`nFIM configuration complete." -ForegroundColor Green
Write-Host "A fresh FIM baseline scan will run."
Write-Host "Realtime monitoring becomes active after the baseline scan completes."
Write-Host "`nBackup:"
Write-Host "  $backup"
