<#
.SYNOPSIS
    Read-only check: reports whether this PC's local admin setup matches
    the hardening standard (only "admin" is a local administrator; the
    built-in Administrator account is disabled).

.DESCRIPTION
    Safe to run any time, on any PC, as many times as you like  -  it never
    changes anything, it only reads and reports. Use it to spot-check a
    machine without having to re-enter the "admin" password (which
    Setup-Local-Admin.ps1 would ask for again).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-AdministratorsGroup {
    Get-LocalGroup -SID 'S-1-5-32-544'
}

$adminsGroup     = Get-AdministratorsGroup
$adminsGroupName = $adminsGroup.Name

Write-Host ""
Write-Host "== Administrators group membership on $env:COMPUTERNAME ==" -ForegroundColor Cyan
Get-LocalGroupMember -Group $adminsGroupName | Select-Object Name, ObjectClass, PrincipalSource | Format-Table -AutoSize

Write-Host "== All local accounts and admin status ==" -ForegroundColor Cyan
$adminShortNames = Get-LocalGroupMember -Group $adminsGroupName | ForEach-Object { ($_.Name -split '\\')[-1] }
Get-LocalUser |
    Select-Object Name, Enabled, @{Name = 'IsAdmin'; Expression = { $adminShortNames -contains $_.Name } } |
    Format-Table -AutoSize

$builtIn         = Get-LocalUser | Where-Object { $_.SID.Value -like '*-500' }
$adminAccountOk  = $adminShortNames -contains 'admin'
$builtInDisabled = $builtIn -and (-not $builtIn.Enabled)
$extraAdmins     = $adminShortNames | Where-Object { $_ -ne 'admin' -and $_ -ne $builtIn.Name }

Write-Host ""
if ($adminAccountOk -and $builtInDisabled -and -not $extraAdmins) {
    Write-Host "PASS: 'admin' is the only enabled local administrator; built-in Administrator is disabled." -ForegroundColor Green
} else {
    Write-Host "REVIEW NEEDED on $env:COMPUTERNAME  -  see tables above. Details:" -ForegroundColor Yellow
    if (-not $adminAccountOk)  { Write-Host "  - 'admin' account is missing or not an administrator." -ForegroundColor Yellow }
    if (-not $builtInDisabled) { Write-Host "  - built-in Administrator account is still enabled." -ForegroundColor Yellow }
    if ($extraAdmins)          { Write-Host "  - unexpected admin(s): $($extraAdmins -join ', ')" -ForegroundColor Yellow }
}
