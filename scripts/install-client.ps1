<#
.SYNOPSIS
    Set up the broom closet client on Windows.

.DESCRIPTION
    Installs client.py under %LOCALAPPDATA%\broom-closet, saves the shared
    passphrase with an ACL that only you can read, and creates a "closet"
    command on your PATH with the server address already filled in.

    Everything lives in your user profile. Nothing system-wide, no admin
    rights needed. Undo it all with uninstall-client.ps1.

.PARAMETER ServerHost
    Address of the machine running the room: a 100.x.y.z Tailscale address,
    or a LAN IP.

.PARAMETER Port
    TCP port. Defaults to 7777.

.PARAMETER Secret
    The shared passphrase. Omit it and you will be prompted, with the input
    hidden. Passing it here means it lands in your PowerShell history, so
    prefer the prompt.

.PARAMETER NoTailscale
    Skip the Tailscale check. Only sensible if the server is on your LAN.

.PARAMETER Trace
    Print every statement as it runs, for debugging.

.EXAMPLE
    .\install-client.ps1 -ServerHost 100.101.102.103

.EXAMPLE
    .\install-client.ps1 -ServerHost 192.168.1.50 -NoTailscale
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ServerHost,

    [int] $Port = 7777,

    [string] $Secret,

    [switch] $NoTailscale,

    [switch] $Trace
)

# Stop on the first error rather than limping onward with a half-install.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Trace) { Set-PSDebug -Trace 1 }

$LibDir   = Join-Path $env:LOCALAPPDATA 'broom-closet'
$ClientPy = Join-Path $LibDir 'client.py'
$SecretFile = Join-Path $LibDir 'secret'
$Launcher = Join-Path $LibDir 'closet.cmd'

function Write-Step { param([string] $Text) Write-Host "`n==> $Text" -ForegroundColor White }
function Write-Info { param([string] $Text) Write-Host "    $Text" }
function Write-Warn { param([string] $Text) Write-Host "    ! $Text" -ForegroundColor Yellow }

function Stop-WithMessage {
    param([string] $Text, [string[]] $Hints = @())
    Write-Host ""
    Write-Host "!! install failed" -ForegroundColor Red
    Write-Host "   $Text"
    foreach ($h in $Hints) { Write-Host "   $h" }
    exit 1
}

# ---------------------------------------------------------------- python ----
function Find-Python {
    # Returns a hashtable @{ Exe; Prefix; Version } or $null.
    # Windows ships no Python; "python" is often a Microsoft Store stub that
    # prints nothing and exits non-zero, so probe by actually running it.
    $candidates = @(
        @{ Exe = 'py';      Prefix = @('-3') },
        @{ Exe = 'python';  Prefix = @() },
        @{ Exe = 'python3'; Prefix = @() }
    )
    $probe = 'import sys; print("%d.%d.%d" % sys.version_info[:3])'

    foreach ($c in $candidates) {
        if (-not (Get-Command $c.Exe -ErrorAction SilentlyContinue)) { continue }
        $out = $null
        try {
            $argv = @()
            if ($c.Prefix.Count -gt 0) { $argv += $c.Prefix }
            $argv += @('-c', $probe)
            $out = & $c.Exe @argv 2>$null
        } catch { continue }
        if ($LASTEXITCODE -ne 0 -or -not $out) { continue }

        $text = ($out | Out-String).Trim()
        if ($text -notmatch '^\d+\.\d+\.\d+$') { continue }
        $version = [version] $text
        if ($version -lt [version] '3.9.0') {
            Write-Warn "found Python $version via '$($c.Exe)', but 3.9+ is required"
            continue
        }
        return @{ Exe = $c.Exe; Prefix = $c.Prefix; Version = $version }
    }
    return $null
}

Write-Step 'Checking Python'
$py = Find-Python
if (-not $py) {
    Stop-WithMessage 'No usable Python 3.9+ was found.' @(
        '',
        'Windows does not ship Python, and typing "python" often just opens',
        'the Microsoft Store. Install the real thing:',
        '',
        '    https://www.python.org/downloads/windows/',
        '',
        'During setup, TICK "Add python.exe to PATH". Then open a NEW',
        'PowerShell window and run this script again.',
        '',
        'Or, if you have winget:   winget install --id Python.Python.3.12'
    )
}
$pyDisplay = (@($py.Exe) + $py.Prefix) -join ' '
Write-Info "using $pyDisplay (Python $($py.Version))"
Write-Info 'no pip packages needed; the client is standard library only'

# ------------------------------------------------------------ client.py ----
Write-Step 'Installing the client'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = $null
foreach ($candidate in @((Join-Path $here 'client.py'),
                         (Join-Path (Split-Path -Parent $here) 'client.py'))) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $source = $candidate; break }
}
if (-not $source) {
    Stop-WithMessage 'Cannot find client.py.' @(
        "Looked next to this script and one directory up.",
        "Copy client.py into $here and run this again."
    )
}

New-Item -ItemType Directory -Force -Path $LibDir | Out-Null
Copy-Item -LiteralPath $source -Destination $ClientPy -Force
Write-Info "installed $ClientPy"

# ------------------------------------------------------------ passphrase ----
Write-Step 'Shared passphrase'
if (Test-Path -LiteralPath $SecretFile -PathType Leaf) {
    Write-Info "already saved at $SecretFile - keeping it"
    Write-Info 'delete that file and re-run if the passphrase changed'
} else {
    $plain = $Secret
    if (-not $plain) {
        $secure = Read-Host -Prompt '    paste the passphrase (hidden)' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
    if (-not $plain) {
        Write-Warn 'nothing entered; you will be prompted each time you connect'
    } else {
        # No trailing newline: the server compares the file's exact bytes.
        [IO.File]::WriteAllText($SecretFile, $plain, [Text.UTF8Encoding]::new($false))

        # The rough equivalent of chmod 600: break inheritance, owner only.
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        & icacls.exe $SecretFile /inheritance:r /grant:r "${me}:(R,W)" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "could not tighten permissions on $SecretFile"
            Write-Warn 'other users on this PC may be able to read it'
        } else {
            Write-Info "saved to $SecretFile (readable only by $me)"
        }
        $plain = $null
    }
}

# -------------------------------------------------------------- launcher ----
Write-Step "Creating the 'closet' command"
$secretArg = ''
if (Test-Path -LiteralPath $SecretFile -PathType Leaf) {
    $secretArg = " --secret-file `"$SecretFile`""
}
$pyInvoke = (@($py.Exe) + $py.Prefix) -join ' '
$cmdBody = @"
@echo off
rem Generated by install-client.ps1 - edit the line below if details change.
$pyInvoke "$ClientPy" $ServerHost $Port$secretArg %*
"@
# ASCII keeps cmd.exe happy regardless of the console code page.
[IO.File]::WriteAllText($Launcher, $cmdBody, [Text.ASCIIEncoding]::new())
Write-Info "installed $Launcher -> ${ServerHost}:${Port}"

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
$entries = $userPath.Split(';') | Where-Object { $_ }
if ($entries -notcontains $LibDir) {
    $newPath = (@($entries) + $LibDir) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Info "added $LibDir to your user PATH"
    Write-Warn 'open a NEW terminal before "closet" is recognized'
} else {
    Write-Info "$LibDir is already on your user PATH"
}

# ------------------------------------------------------------- tailscale ----
if (-not $NoTailscale) {
    Write-Step 'Tailscale'
    $ts = Get-Command tailscale -ErrorAction SilentlyContinue
    if (-not $ts) {
        $guess = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
        if (Test-Path -LiteralPath $guess -PathType Leaf) { $ts = $guess }
    }
    if ($ts) {
        Write-Info 'already installed'
        Write-Info 'make sure it is logged into the SAME account as the server'
    } else {
        Write-Warn 'Tailscale is not installed. Get it from:'
        Write-Warn '    https://tailscale.com/download/windows'
        Write-Warn '  or:  winget install --id Tailscale.Tailscale'
        Write-Warn 'Then sign in with the SAME account as the server.'
    }
} else {
    Write-Step 'Skipping Tailscale (LAN mode)'
    Write-Info "you must be able to reach ${ServerHost}:${Port} on the local network"
}

# ------------------------------------------------------------------ done ----
Write-Step 'Done'
Write-Info 'Open a new terminal, then join the room with:'
Write-Info '    closet'
Write-Info 'Override the nick with:'
Write-Info '    closet --nick yourname'
Write-Info ''
Write-Info 'Check you can reach the server:'
Write-Info "    $pyInvoke -c ""import socket;socket.create_connection(('$ServerHost',$Port),5);print('reachable')"""
Write-Info ''
Write-Info 'Note: native Windows gets a simpler client - you type a line and'
Write-Info 'press Enter, with no pinned input line or arrow-key history. For'
Write-Info 'the full experience, run the bash installer inside WSL instead.'
