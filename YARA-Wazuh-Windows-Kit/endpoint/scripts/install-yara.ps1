<#
    Stage 1 -- Install YARA CLI + a curated open-source rule pack, compile
    them into one index, and validate. Idempotent.

    YARA:   VirusTotal/yara on GitHub. Recent releases (4.5.6+) stopped
            shipping prebuilt Windows binaries, so this walks the release
            list backwards to find the newest one that still has a win64 zip
            (currently 4.5.5), rather than hardcoding a version.
    Rules:  Neo23x0/signature-base (Florian Roth) -- open source, curated,
            widely used, actively maintained generic malware/webshell/
            suspicious-behavior rules. Not a full commercial feed; it is a
            strong baseline layer behind VirusTotal + the hash blocklist,
            not a replacement for either.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\Program Files\YARA',
    [switch]$RefreshRulesOnly
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$global:PSNativeCommandUseErrorActionPreference = $false

function Assert-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this from an elevated (Administrator) PowerShell session."
    }
}
Assert-Elevated

$rules = Join-Path $InstallDir 'rules'
New-Item -ItemType Directory -Force -Path $InstallDir,$rules | Out-Null
$exe = Join-Path $InstallDir 'yara64.exe'

if (-not (Test-Path $exe) -and -not $RefreshRulesOnly) {
    Write-Host "== Resolving newest YARA release that ships a win64 zip =="
    $rels = Invoke-RestMethod -Uri 'https://api.github.com/repos/VirusTotal/yara/releases' -Headers @{'User-Agent'='wazuh-toolkit-build'}
    $found = $null
    foreach ($r in $rels) {
        $a = $r.assets | Where-Object { $_.name -match 'win64' -and $_.name -match '\.zip$' } | Select-Object -First 1
        if ($a) { $found = @{ rel = $r; asset = $a }; break }
    }
    if (-not $found) { throw "No YARA release with a win64 zip asset found" }
    Write-Host "Downloading $($found.asset.name) ($($found.rel.tag_name))"
    $zip = Join-Path $InstallDir $found.asset.name
    Invoke-WebRequest -Uri $found.asset.browser_download_url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $InstallDir -Force
    $found2 = Get-ChildItem $InstallDir -Recurse -Filter 'yara64.exe' | Select-Object -First 1
    if ($found2 -and $found2.FullName -ne $exe) { Copy-Item $found2.FullName $exe -Force }
    if (-not (Test-Path $exe)) { throw "yara64.exe missing after extraction" }
    Write-Host "Installed: $exe -- $(& $exe --version)"
} elseif (Test-Path $exe) {
    Write-Host "YARA already installed: $(& $exe --version)"
}

Write-Host "`n== Fetching signature-base rule pack (Neo23x0, open source) =="
$zip2 = Join-Path $InstallDir 'signature-base.zip'
Invoke-WebRequest -Uri 'https://github.com/Neo23x0/signature-base/archive/refs/heads/master.zip' -OutFile $zip2 -UseBasicParsing
$tmp = Join-Path $InstallDir 'sb-extract'
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -Path $zip2 -DestinationPath $tmp -Force
$srcYar = Get-ChildItem $tmp -Recurse -Filter '*.yar' | Where-Object {
    $_.DirectoryName -match '\\yara$' -and $_.Name -notmatch 'thor|apt_|yara_mixed_ext_vars' -and $_.Length -lt 300KB
}
Get-ChildItem $rules -Filter '*.yar*' | Remove-Item -Force -ErrorAction SilentlyContinue
$count = 0
foreach ($f in $srcYar) { try { Copy-Item $f.FullName (Join-Path $rules $f.Name) -Force; $count++ } catch {} }
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zip2 -Force -ErrorAction SilentlyContinue
Write-Host "Copied $count rule files"

Write-Host "`n== Validating each rule file compiles (dropping ones that don't -- external-var deps etc.) =="
$target = "$env:WINDIR\notepad.exe"
$good = 0; $bad = 0
Get-ChildItem $rules -Filter '*.yar' | ForEach-Object {
    $null = & $exe -w $_.FullName $target 2>&1
    if ($LASTEXITCODE -eq 0) { $good++ } else { $bad++; Rename-Item $_.FullName "$($_.FullName).disabled" -Force -ErrorAction SilentlyContinue }
}
Write-Host "compilable: $good   disabled(bad): $bad"

Write-Host "`n== Building index.yar =="
$survivors = Get-ChildItem $rules -Filter '*.yar'
$survivors | ForEach-Object { "include `"$($_.Name)`"" } | Set-Content -Path (Join-Path $rules 'index.yar') -Encoding ascii
Write-Host "index.yar entries: $($survivors.Count)"

Write-Host "`n== Compile test =="
& $exe -w (Join-Path $rules 'index.yar') $target
if ($LASTEXITCODE -eq 0) { Write-Host "OK -- index compiles clean" } else { Write-Warning "index.yar had compile problems (exit $LASTEXITCODE)" }
