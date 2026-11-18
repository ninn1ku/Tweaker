<#
.SYNOPSIS
    Runs PSScriptAnalyzer and the Pester 5 test suite (the same steps as CI).

.DESCRIPTION
    Development-only helper. Requires Pester 5.x and PSScriptAnalyzer. They are looked
    up in the normal module path and additionally in
    %LOCALAPPDATA%\TweakerDev\Modules (a private folder that keeps dev tools out of
    the system-wide module path). Use -InstallTools to install them for the current
    user from the PowerShell Gallery.

    Nothing in the test suite changes the system: every state-changing primitive is
    mocked.

.PARAMETER Analyze
    Run only PSScriptAnalyzer.

.PARAMETER Pester
    Run only Pester.

.PARAMETER InstallTools
    Install Pester 5 and PSScriptAnalyzer (CurrentUser scope) if missing.

.PARAMETER CI
    Write NUnit test results to TestResults.xml.
#>
[CmdletBinding()]
param(
    [switch]$Analyze,
    [switch]$Pester,
    [switch]$InstallTools,
    [switch]$CI
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Analyze -and -not $Pester) { $Analyze = $true; $Pester = $true }

$devModules = Join-Path $env:LOCALAPPDATA 'TweakerDev\Modules'
if ((Test-Path $devModules) -and ($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $devModules) {
    $env:PSModulePath = $devModules + [IO.Path]::PathSeparator + $env:PSModulePath
}

if ($InstallTools) {
    if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -eq 5 })) {
        Install-Module Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99 -Scope CurrentUser -Force -SkipPublisherCheck
    }
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
    }
}

$failed = $false

if ($Analyze) {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
    $settings = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'
    $results = @()
    foreach ($dir in 'src', 'build', 'tests') {
        $results += Invoke-ScriptAnalyzer -Path (Join-Path $repoRoot $dir) -Recurse -Settings $settings
    }
    if ($results.Count -gt 0) {
        $results | Format-Table -AutoSize Severity, RuleName, ScriptName, Line, Message | Out-String -Width 220 | Write-Host
        Write-Host "PSScriptAnalyzer: $($results.Count) issue(s)" -ForegroundColor Red
        $failed = $true
    } else {
        Write-Host 'PSScriptAnalyzer: no issues' -ForegroundColor Green
    }
}

if ($Pester) {
    $pesterModule = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -eq 5 } |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pesterModule) { throw 'Pester 5 is not installed. Run build/Test.ps1 -InstallTools.' }
    Import-Module $pesterModule.Path -Force
    $config = New-PesterConfiguration
    $config.Run.Path = Join-Path $repoRoot 'tests'
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Normal'
    if ($CI) {
        $config.TestResult.Enabled = $true
        $config.TestResult.OutputPath = Join-Path $repoRoot 'TestResults.xml'
    }
    $run = Invoke-Pester -Configuration $config
    if ($run.FailedCount -gt 0 -or $run.Result -ne 'Passed') { $failed = $true }
}

if ($failed) { exit 1 }
