<#
.SYNOPSIS
    Tweaker - a safe, data-driven Windows tweaker (GUI + CLI).

.DESCRIPTION
    Development entry point. It dot-sources the engine from src/core and src/ui.
    build/Build.ps1 replaces the DevLoader region with the embedded code and
    resources to produce the single-file dist/Tweaker.ps1.
#>
[CmdletBinding(SupportsShouldProcess)]
param()

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

"Tweaker $script:TwVersion"
