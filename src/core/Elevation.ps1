# Administrator rights, STA thread, and "whose HKCU is this?" detection.

function Test-TwAdministrator {
    <#
    .SYNOPSIS
        True when the current process runs elevated as an administrator.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-TwStaThread {
    <#
    .SYNOPSIS
        True when the current thread is single-threaded apartment (required by WPF).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA)
}

function Get-TwCurrentUserSid {
    <#
    .SYNOPSIS
        SID of the account the process runs as.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-TwInteractiveUserSid {
    <#
    .SYNOPSIS
        SID of the user signed in to the current session (owner of explorer.exe).
    .DESCRIPTION
        When an administrator elevates with a different account (standard user +
        admin credentials), HKCU in the elevated process belongs to the admin, not to
        the person at the keyboard. The owner of explorer.exe in our session tells us
        who that person is. Returns $null when it cannot be determined.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try {
        $sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        $explorers = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction Stop |
                Where-Object { $_.SessionId -eq $sessionId })
        foreach ($proc in $explorers) {
            $owner = Invoke-CimMethod -InputObject $proc -MethodName GetOwnerSid -ErrorAction Stop
            if ($owner -and $owner.Sid) { return [string]$owner.Sid }
        }
    } catch {
        Write-Verbose "Interactive user lookup failed: $($_.Exception.Message)"
    }
    return $null
}

function Resolve-TwTargetUser {
    <#
    .SYNOPSIS
        Decides which user hive HKCU tweaks are written to.
    .DESCRIPTION
        Returns an object with CurrentSid, InteractiveSid, Mismatch and TargetSid.
        On mismatch, HKCU paths are redirected to HKEY_USERS\<interactive SID> when
        that hive is loaded, so tweaks reach the person who actually uses the desktop.
    .EXAMPLE
        $u = Resolve-TwTargetUser; if ($u.Mismatch) { 'redirecting HKCU' }
    #>
    [CmdletBinding()]
    param()
    $current = Get-TwCurrentUserSid
    $interactive = Get-TwInteractiveUserSid
    $mismatch = [bool]($interactive -and $interactive -ne $current)
    $target = $null
    if ($mismatch -and (Test-Path -LiteralPath ("Registry::HKEY_USERS\$interactive"))) { $target = $interactive }
    return [pscustomobject]@{
        CurrentSid     = $current
        InteractiveSid = $interactive
        Mismatch       = $mismatch
        TargetSid      = $target
    }
}

function Get-TwPowerShellExecutable {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($exe -and $exe -match '(powershell|pwsh)\.exe$') { return $exe }
    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function ConvertTo-TwArgumentString {
    <#
    .SYNOPSIS
        Converts bound parameters back into a command-line argument string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Parameters)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter] -or $value -is [bool]) {
            if ([bool]$value) { $parts.Add("-$key") }
            continue
        }
        # -File passes every argument as a plain string, so arrays travel as "a,b"
        # and the entry point splits them again.
        $joined = (@($value) | ForEach-Object { [string]$_ }) -join ','
        $parts.Add("-$key")
        $parts.Add('"' + $joined.Replace('"', '\"') + '"')
    }
    return ($parts -join ' ')
}

function Start-TwElevated {
    <#
    .SYNOPSIS
        Relaunches Tweaker elevated (and in STA), preserving parameters.
    .DESCRIPTION
        When started from a file, that file is relaunched. When started through
        "irm | iex" there is no file, so the script text is first saved to
        %TEMP%\Tweaker\Tweaker.ps1 (UTF-8 with BOM) and that copy is launched.
    .PARAMETER ScriptPath
        Path of the running script, if any.
    .PARAMETER ScriptText
        Source text to save when there is no script file.
    .PARAMETER Parameters
        Bound parameters to forward.
    .PARAMETER NoElevate
        Only ensure STA, do not request administrator rights.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ScriptPath,
        [string]$ScriptText,
        [System.Collections.IDictionary]$Parameters = @{},
        [switch]$NoElevate,
        [switch]$Minimized
    )
    if (-not $ScriptPath -or -not (Test-Path -LiteralPath $ScriptPath)) {
        if (-not $ScriptText) { throw 'Cannot relaunch: no script path and no script text.' }
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) 'Tweaker'
        if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false }
        $ScriptPath = Join-Path $dir 'Tweaker.ps1'
        [System.IO.File]::WriteAllText($ScriptPath, $ScriptText, (New-Object System.Text.UTF8Encoding($true)))
    }
    # The console of the relaunched GUI process stays minimised: users only see the window.
    $style = ''
    if ($Minimized) { $style = '-WindowStyle Minimized ' }
    $argString = '-NoProfile -ExecutionPolicy Bypass -STA {0}-File "{1}" {2}' -f $style, $ScriptPath, (ConvertTo-TwArgumentString $Parameters)
    $exe = Get-TwPowerShellExecutable
    if ($PSCmdlet.ShouldProcess($exe, "Start $argString")) {
        if ($NoElevate) {
            Start-Process -FilePath $exe -ArgumentList $argString | Out-Null
        } else {
            Start-Process -FilePath $exe -ArgumentList $argString -Verb RunAs | Out-Null
        }
    }
}
