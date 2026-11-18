# Tweaker launcher - one command, opens the GUI:
#
#   irm https://raw.githubusercontent.com/ninn1ku/Tweaker/main/launch.ps1 | iex
#
# Downloads the latest release of Tweaker.ps1 (falls back to the rolling "nightly"
# build of the main branch), saves it to %TEMP%\Tweaker and starts it in a new
# Windows PowerShell process with -ExecutionPolicy Bypass (this process only; the
# system policy is not changed). Administrator rights are requested through UAC.
# Kept ASCII-only on purpose: Russian messages are stored as Base64 UTF-8.

& {
    $ErrorActionPreference = 'Stop'
    $repo = 'ninn1ku/Tweaker'
    $urls = @(
        "https://github.com/$repo/releases/latest/download/Tweaker.ps1",
        "https://github.com/$repo/releases/download/nightly/Tweaker.ps1"
    )

    $ru = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -in 'ru', 'uk', 'be', 'kk'
    function Get-Text([string]$en, [string]$ruBase64) {
        if ($ru) { return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ruBase64)) }
        return $en
    }

    # Windows PowerShell 5.1 may default to TLS 1.0, which GitHub rejects.
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { Write-Verbose 'TLS 1.2 could not be enabled' }

    $dir = Join-Path ([System.IO.Path]::GetTempPath()) 'Tweaker'
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $file = Join-Path $dir 'Tweaker.ps1'

    Write-Host (Get-Text 'Downloading Tweaker...' '0JfQsNCz0YDRg9C20LDRjiBUd2Vha2VyLi4u') -ForegroundColor Cyan
    $ok = $false
    foreach ($url in $urls) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing -ErrorAction Stop
            $head = [System.IO.File]::ReadAllText($file)
            if ($head -match 'TweakerMain') { $ok = $true; break }
        } catch {
            Write-Verbose "Not available: $url"
        }
    }
    if (-not $ok) {
        Write-Host (Get-Text "Could not download Tweaker. Check your internet connection or open https://github.com/$repo/releases" ('0J3QtSDRg9C00LDQu9C+0YHRjCDRgdC60LDRh9Cw0YLRjCBUd2Vha2VyLiDQn9GA0L7QstC10YDRjNGC0LUg0LjQvdGC0LXRgNC90LXRgiDQuNC70Lgg0L7RgtC60YDQvtC50YLQtSA=') + "https://github.com/$repo/releases") -ForegroundColor Red
        return
    }

    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argList = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Minimized -File "{0}"' -f $file
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    try {
        if ($isAdmin) {
            Start-Process -FilePath $exe -ArgumentList $argList | Out-Null
        } else {
            Write-Host (Get-Text 'Requesting administrator rights (UAC)...' '0JfQsNC/0YDQsNGI0LjQstCw0Y4g0L/RgNCw0LLQsCDQsNC00LzQuNC90LjRgdGC0YDQsNGC0L7RgNCwIChVQUMpLi4u') -ForegroundColor Cyan
            Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs | Out-Null
        }
        Write-Host (Get-Text 'Tweaker window is opening.' '0J7QutC90L4gVHdlYWtlciDQvtGC0LrRgNGL0LLQsNC10YLRgdGPLg==') -ForegroundColor Green
    } catch {
        # UAC was declined: open in view-only mode instead of failing.
        Write-Host (Get-Text 'No administrator rights: opening in view-only mode.' '0J3QtdGCINC/0YDQsNCyINCw0LTQvNC40L3QuNGB0YLRgNCw0YLQvtGA0LA6INC+0YLQutGA0YvQstCw0Y4g0LIg0YDQtdC20LjQvNC1INC/0YDQvtGB0LzQvtGC0YDQsC4=') -ForegroundColor Yellow
        Start-Process -FilePath $exe -ArgumentList ($argList + ' -ReadOnly') | Out-Null
    }
}
