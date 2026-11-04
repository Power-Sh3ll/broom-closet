<#
.SYNOPSIS
    Undo install-client.ps1.

.DESCRIPTION
    Removes the "closet" command, the installed client, the saved passphrase,
    and the PATH entry this project added. Tailscale is left alone unless you
    ask for it, since other things may depend on it.

    Needs no admin rights: everything it touches is in your user profile.

.PARAMETER KeepSecret
    Leave the saved passphrase in place.

.PARAMETER Tailscale
    Also attempt to uninstall Tailscale.

.PARAMETER Yes
    Do not ask for confirmation.

.PARAMETER Trace
    Print every statement as it runs, for debugging.

.EXAMPLE
    .\uninstall-client.ps1

.EXAMPLE
    .\uninstall-client.ps1 -Tailscale -Yes
#>
[CmdletBinding()]
param(
    [switch] $KeepSecret,
    [switch] $Tailscale,
    [switch] $Yes,
    [switch] $Trace
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Trace) { Set-PSDebug -Trace 1 }

$LibDir     = Join-Path $env:LOCALAPPDATA 'broom-closet'
$SecretFile = Join-Path $LibDir 'secret'

function Write-Step { param([string] $Text) Write-Host "`n==> $Text" -ForegroundColor White }
function Write-Info { param([string] $Text) Write-Host "    $Text" }
function Write-Warn { param([string] $Text) Write-Host "    ! $Text" -ForegroundColor Yellow }

function Confirm-Action {
    param([string] $Question)
    if ($Yes) { return $true }
    $reply = Read-Host -Prompt "    $Question [y/N]"
    return ($reply -match '^[yY]')
}

# ------------------------------------------------------------- passphrase ----
# Handled first, because removing the directory would take it along silently.
Write-Step 'Saved passphrase'
if (Test-Path -LiteralPath $SecretFile -PathType Leaf) {
    if ($KeepSecret) {
        $stash = Join-Path $env:USERPROFILE '.closet-secret'
        Move-Item -LiteralPath $SecretFile -Destination $stash -Force
        Write-Info "moved to $stash so it survives this uninstall"
    } elseif (Confirm-Action "delete $SecretFile?") {
        Remove-Item -LiteralPath $SecretFile -Force
        Write-Info 'deleted'
    } else {
        $stash = Join-Path $env:USERPROFILE '.closet-secret'
        Move-Item -LiteralPath $SecretFile -Destination $stash -Force
        Write-Info "kept, moved to $stash"
    }
} else {
    Write-Info 'no saved passphrase - nothing to do'
}

# ---------------------------------------------------------- files and PATH ----
Write-Step 'Client files and the "closet" command'
if (Test-Path -LiteralPath $LibDir -PathType Container) {
    Remove-Item -LiteralPath $LibDir -Recurse -Force
    Write-Info "removed $LibDir"
} else {
    Write-Info "nothing at $LibDir"
}

Write-Step 'PATH entry'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
$entries = $userPath.Split(';') | Where-Object { $_ }
if ($entries -contains $LibDir) {
    $kept = $entries | Where-Object { $_ -ne $LibDir }
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
    Write-Info "removed $LibDir from your user PATH"
    Write-Warn 'already-open terminals keep the old PATH until reopened'
} else {
    Write-Info 'not on your user PATH - nothing to do'
}

# -------------------------------------------------------------- tailscale ----
Write-Step 'Tailscale'
if (-not $Tailscale) {
    Write-Info 'left installed - pass -Tailscale to remove it'
} elseif (-not (Get-Command tailscale -ErrorAction SilentlyContinue) -and
          -not (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'))) {
    Write-Info 'not installed - nothing to do'
} elseif (Confirm-Action 'uninstall Tailscale? other things may rely on it') {
    $done = $false
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        # winget returns non-zero for "not installed by winget", which is fine.
        & winget uninstall --id Tailscale.Tailscale --silent 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $done = $true }
    }
    if ($done) {
        Write-Info 'removed via winget'
    } else {
        Write-Warn 'could not remove it automatically. Do it by hand:'
        Write-Warn '    Settings > Apps > Installed apps > Tailscale > Uninstall'
    }
    Write-Info 'Also delete this machine from the admin console:'
    Write-Info '    https://login.tailscale.com/admin/machines'
} else {
    Write-Info 'kept'
}

Write-Step 'Done'
Write-Info 'Python is left installed; remove it yourself if you only got it for this.'
