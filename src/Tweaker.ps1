<#
.SYNOPSIS
    Tweaker - a safe, data-driven Windows tweaker (GUI + CLI).

.DESCRIPTION
    Without CLI parameters the WPF window opens (administrator rights are requested;
    use -ReadOnly or -NoElevate to only look at the current state).
    Every change is backed up first (real original value) to
    %ProgramData%\Tweaker\backups and can be rolled back per tweak, per session or
    completely. A restore point is created before the first change of a session.

    Exit codes: 0 OK, 1 some steps failed, 2 invalid arguments, 3 administrator
    rights required, 4 GUI not available, 5 unexpected error.

.PARAMETER Preset
    Apply a preset: minimal, recommended, gaming, privacy-max.
.PARAMETER Apply
    Tweak ids to apply (comma separated).
.PARAMETER Undo
    Tweak ids to undo, or All (full rollback), or Last (last session).
.PARAMETER List
    List tweaks (optionally of one -Category).
.PARAMETER Category
    Category filter for -List / -Status.
.PARAMETER Status
    Show the current state of each tweak.
.PARAMETER Export
    Save the ids of currently applied tweaks to a JSON file.
.PARAMETER Import
    Apply the tweaks listed in a file written by -Export.
.PARAMETER Silent
    Print errors only.
.PARAMETER Lang
    Interface language: ru (default) or en.
.PARAMETER NoElevate
    Do not request administrator rights (the GUI opens read-only).
.PARAMETER ReadOnly
    View-only mode: nothing is applied.
.PARAMETER NoRestorePoint
    Do not create a restore point before applying.
.PARAMETER DefaultUser
    Also write per-user (HKCU) tweaks to the Default profile used for new accounts.

.EXAMPLE
    .\Tweaker.ps1 -List
.EXAMPLE
    .\Tweaker.ps1 -Status -Category privacy
.EXAMPLE
    .\Tweaker.ps1 -Preset recommended -WhatIf
.EXAMPLE
    .\Tweaker.ps1 -Apply privacy.disable-telemetry,interface.show-file-extensions
.EXAMPLE
    .\Tweaker.ps1 -Undo Last
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Preset,
    [string[]]$Apply,
    [string[]]$Undo,
    [switch]$List,
    [string]$Category,
    [switch]$Status,
    [string]$Export,
    [string]$Import,
    [switch]$Silent,
    [ValidateSet('ru', 'en')]
    [string]$Lang,
    [switch]$NoElevate,
    [switch]$ReadOnly,
    [switch]$NoRestorePoint,
    [switch]$DefaultUser
)

$script:TwVersion = '0.1.0-dev'

#region DevLoader
# Development mode: load engine files and read resources from disk.
$script:TwEmbedded = $null
$script:TwDevRoot = Split-Path -Parent $PSScriptRoot
foreach ($dir in 'core', 'ui') {
    $path = Join-Path $PSScriptRoot $dir
    if (Test-Path $path) {
        foreach ($file in Get-ChildItem -Path $path -Filter '*.ps1' -File | Sort-Object Name) {
            . $file.FullName
        }
    }
}
#endregion DevLoader

# When this program runs as "irm ... | iex" there is no file to relaunch elevated;
# the built script wraps everything in $TweakerMain so its text can be saved first.
$selfText = $null
$mainBlock = Get-Variable -Name TweakerMain -ValueOnly -ErrorAction SilentlyContinue
if ($mainBlock -is [scriptblock]) { $selfText = $mainBlock.ToString() }

$exitCode = 5
try {
    $exitCode = Start-TwMain -Options $PSBoundParameters -ScriptPath $PSCommandPath -ScriptText $selfText
} catch {
    Write-Host ("Tweaker: {0}" -f $_.Exception.Message) -ForegroundColor Red
    try { Write-TwLog -Level Error -Message ("Fatal: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace) } catch { Write-Verbose 'log unavailable' }
    $exitCode = 5
}

if ($PSCommandPath) { exit $exitCode }
Set-Variable -Name LASTEXITCODE -Value $exitCode -Scope Global
