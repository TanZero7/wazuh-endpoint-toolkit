<#
.SYNOPSIS
    Endpoint pre-install step: create local "admin" account with
    administrator rights, demote every other local account to Standard
    User, and disable the built-in Administrator account.

.DESCRIPTION
    Run this ONCE on each PC, BEFORE installing the Wazuh agent or any of
    the other kits in this repo. Don't run this .ps1 directly  -  double-click
    Run-Setup.cmd one folder up; it elevates automatically and then
    calls this script.

    What it does, in this order (order matters  -  it never leaves a PC
    with zero local administrators):
      1. Prompts for a password for the "admin" account (typed twice to
         confirm, at least 12 characters). The password is never written
         to disk, logged, or transmitted anywhere  -  it lives in memory
         only for the seconds this script needs it.
      2. Creates the local "admin" account if it doesn't exist yet, or
         resets its password and re-enables it if it already does.
      3. Adds "admin" to the local Administrators group.
      4. ONLY THEN removes every OTHER local user account from
         Administrators. Those accounts are NOT deleted or disabled  - 
         people keep logging in exactly as before, they just lose admin
         rights. Windows system accounts (Guest, DefaultAccount,
         WDAGUtilityAccount) are left alone; the built-in Administrator
         account is handled separately in step 5.
      5. Disables the built-in Administrator account, even if someone
         had previously turned it on.
      6. Prints the resulting Administrators group membership and every
         local account's admin status, so you can confirm on screen
         before moving on to the Wazuh agent install.

.NOTES
    Pilot this on one or two non-critical PCs first before running it
    across every endpoint in the fleet. If a step fails partway through, the
    script stops (non-zero exit code)  -  read the on-screen error before
    re-running.

    Recovery if something goes wrong: log in as "admin" (that account is
    always created/enabled before anything else is touched), then use
    Computer Management > Local Users and Groups, or
    Add-LocalGroupMember -Group Administrators -Member <name>, to restore
    another account's admin rights, and Enable-LocalUser -Name
    Administrator to re-enable the built-in account if you ever need it.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$AdminAccountName   = 'admin'
$MinPasswordLength  = 12
$SkipNames          = @($AdminAccountName, 'Guest', 'DefaultAccount', 'WDAGUtilityAccount')

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host "== $Text ==" -ForegroundColor Cyan
}

function Assert-RunningAsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must run elevated. Use Run-Setup.cmd, which requests admin rights automatically."
    }
}

function Get-AdministratorsGroup {
    # Well-known SID S-1-5-32-544 = Administrators on every Windows machine,
    # regardless of what the group's display name is in a localized Windows build.
    Get-LocalGroup -SID 'S-1-5-32-544'
}

function Read-ConfirmedPassword {
    param([string]$Prompt)
    while ($true) {
        $first  = Read-Host -Prompt $Prompt -AsSecureString
        $second = Read-Host -Prompt "Re-enter to confirm" -AsSecureString
        $bstr1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($first)
        $bstr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($second)
        try {
            $plain1     = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr1)
            $plain2     = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr2)
            $match      = ($plain1 -ceq $plain2)
            $longEnough = ($plain1.Length -ge $MinPasswordLength)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2)
            $plain1 = $null; $plain2 = $null
        }
        if (-not $match) {
            Write-Host "Passwords did not match  -  try again." -ForegroundColor Yellow
            continue
        }
        if (-not $longEnough) {
            Write-Host "Password must be at least $MinPasswordLength characters  -  try again." -ForegroundColor Yellow
            continue
        }
        return $first
    }
}

try {
    Assert-RunningAsAdministrator

    Write-Section "Endpoint pre-install: local admin setup on $env:COMPUTERNAME"

    $adminsGroup     = Get-AdministratorsGroup
    $adminsGroupName = $adminsGroup.Name

    # ---- 1. Create or reset the "admin" account ---------------------------
    Write-Section "Local account '$AdminAccountName'"

    $securePw = Read-ConfirmedPassword -Prompt "Enter a password for the '$AdminAccountName' account"

    $existingAdmin = Get-LocalUser -Name $AdminAccountName -ErrorAction SilentlyContinue
    if ($existingAdmin) {
        Write-Host "Account already exists  -  resetting its password and making sure it's enabled."
        Set-LocalUser -Name $AdminAccountName -Password $securePw -PasswordNeverExpires $true
        if (-not $existingAdmin.Enabled) { Enable-LocalUser -Name $AdminAccountName }
    } else {
        Write-Host "Creating account '$AdminAccountName'."
        New-LocalUser -Name $AdminAccountName -Password $securePw `
            -FullName 'Local Administrator' `
            -Description 'Standard local admin account' `
            -PasswordNeverExpires -AccountNeverExpires | Out-Null
    }
    $securePw = $null

    $isMember = Get-LocalGroupMember -Group $adminsGroupName -ErrorAction SilentlyContinue |
        Where-Object { ($_.Name -split '\\')[-1] -eq $AdminAccountName }
    if (-not $isMember) {
        Add-LocalGroupMember -Group $adminsGroupName -Member $AdminAccountName
        Write-Host "Added '$AdminAccountName' to '$adminsGroupName'."
    } else {
        Write-Host "'$AdminAccountName' is already a member of '$adminsGroupName'."
    }

    # ---- 2. Demote every other local account -------------------------------
    Write-Section "Demoting every other local account to Standard User"

    $members = Get-LocalGroupMember -Group $adminsGroupName -ErrorAction SilentlyContinue
    foreach ($m in $members) {
        $shortName = ($m.Name -split '\\')[-1]
        if ($SkipNames -contains $shortName) { continue }
        if ($m.SID.Value -like '*-500') { continue }   # built-in Administrator  -  handled in step 3
        if ($m.ObjectClass -ne 'User') {
            Write-Host "Skipping non-user member of Administrators: $($m.Name) ($($m.ObjectClass))  -  review manually." -ForegroundColor Yellow
            continue
        }
        try {
            Remove-LocalGroupMember -Group $adminsGroupName -Member $m.Name
            Write-Host "Removed '$($m.Name)' from '$adminsGroupName'  -  now a standard user, account itself untouched."
        } catch {
            Write-Host "Could not remove '$($m.Name)': $_" -ForegroundColor Yellow
        }
    }

    # ---- 3. Disable the built-in Administrator account ----------------------
    Write-Section "Built-in Administrator account"

    $builtIn = Get-LocalUser | Where-Object { $_.SID.Value -like '*-500' }
    if ($builtIn) {
        if ($builtIn.Enabled) {
            Disable-LocalUser -Name $builtIn.Name
            Write-Host "Disabled '$($builtIn.Name)' (it was enabled)."
        } else {
            Write-Host "'$($builtIn.Name)' was already disabled  -  nothing to do."
        }
    } else {
        Write-Host "Could not locate the built-in Administrator account by SID (-500)  -  check manually with Get-LocalUser." -ForegroundColor Yellow
    }

    # ---- 4. Summary -----------------------------------------------------------
    Write-Section "Administrators group membership now"
    Get-LocalGroupMember -Group $adminsGroupName | Select-Object Name, ObjectClass, PrincipalSource | Format-Table -AutoSize

    Write-Section "All local accounts and admin status"
    $adminShortNames = Get-LocalGroupMember -Group $adminsGroupName | ForEach-Object { ($_.Name -split '\\')[-1] }
    Get-LocalUser |
        Select-Object Name, Enabled, @{Name = 'IsAdmin'; Expression = { $adminShortNames -contains $_.Name } } |
        Format-Table -AutoSize

    Write-Host ""
    Write-Host "Done on $env:COMPUTERNAME. Confirm the tables above before installing the Wazuh agent." -ForegroundColor Green
    exit 0
}
catch {
    Write-Host ""
    Write-Host "FAILED: $_" -ForegroundColor Red
    exit 1
}
