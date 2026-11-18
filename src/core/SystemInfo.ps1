# Operating system detection and the "System information" page.

function Get-TwOsInfo {
    <#
    .SYNOPSIS
        Returns build, UBR, edition and version of the running Windows.
    .EXAMPLE
        (Get-TwOsInfo).Build
    #>
    [CmdletBinding()]
    param()
    $ctx = Get-TwContext
    if ($ctx.Os) { return $ctx.Os }
    $cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int](Get-TwRegistryValue $cv 'CurrentBuildNumber').Value
    $ubr = (Get-TwRegistryValue $cv 'UBR').Value
    $display = (Get-TwRegistryValue $cv 'DisplayVersion').Value
    $edition = (Get-TwRegistryValue $cv 'EditionID').Value
    $product = (Get-TwRegistryValue $cv 'ProductName').Value
    # ProductName still says "Windows 10" on Windows 11; derive the family from the build.
    if ($build -ge 22000 -and $product) { $product = $product -replace 'Windows 10', 'Windows 11' }
    $ctx.Os = [pscustomobject]@{
        Build          = $build
        Ubr            = $ubr
        DisplayVersion = $display
        Edition        = $edition
        ProductName    = $product
        IsWindows11    = ($build -ge 22000)
        IsServer       = [bool]($edition -match 'Server')
        Supported      = ($build -eq 19045 -or $build -ge 22631)
    }
    return $ctx.Os
}

function Get-TwSystemInfo {
    <#
    .SYNOPSIS
        Collects hardware and OS information (read-only).
    .EXAMPLE
        Get-TwSystemInfo | Format-List
    #>
    [CmdletBinding()]
    param()
    $os = Get-TwOsInfo
    $cimOs = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $cpu = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue) | Select-Object -First 1
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name })
    $mediaTypes = @{}
    try {
        foreach ($pd in Get-PhysicalDisk -ErrorAction Stop) { $mediaTypes[[string]$pd.DeviceId] = [string]$pd.MediaType }
    } catch { Write-Verbose 'Get-PhysicalDisk is unavailable' }
    $disks = @()
    foreach ($vol in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction SilentlyContinue)) {
        $media = ''
        try {
            $part = Get-Partition -DriveLetter $vol.DeviceID.TrimEnd(':') -ErrorAction Stop | Select-Object -First 1
            if ($part -and $mediaTypes.ContainsKey([string]$part.DiskNumber)) { $media = $mediaTypes[[string]$part.DiskNumber] }
        } catch { Write-Verbose "No partition info for $($vol.DeviceID)" }
        $disks += [pscustomobject]@{
            Drive  = $vol.DeviceID
            Label  = $vol.VolumeName
            Media  = $media
            SizeGB = [math]::Round($vol.Size / 1GB, 1)
            FreeGB = [math]::Round($vol.FreeSpace / 1GB, 1)
        }
    }
    $uptime = $null
    if ($cimOs -and $cimOs.LastBootUpTime) { $uptime = (Get-Date) - $cimOs.LastBootUpTime }
    return [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        Os           = '{0} {1} (build {2}.{3})' -f $os.ProductName, $os.DisplayVersion, $os.Build, $os.Ubr
        Edition      = $os.Edition
        Architecture = if ($cimOs) { $cimOs.OSArchitecture } else { $env:PROCESSOR_ARCHITECTURE }
        Cpu          = if ($cpu) { ($cpu.Name -replace '\s+', ' ').Trim() } else { '' }
        Cores        = if ($cpu) { '{0} / {1}' -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors } else { '' }
        Gpu          = ($gpus | ForEach-Object { $_.Name }) -join '; '
        RamGB        = if ($cs) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) } else { 0 }
        Disks        = $disks
        Uptime       = $uptime
        Manufacturer = if ($cs) { '{0} {1}' -f $cs.Manufacturer, $cs.Model } else { '' }
    }
}

function Export-TwSystemReport {
    <#
    .SYNOPSIS
        Writes system information as a text report.
    .EXAMPLE
        Export-TwSystemReport -Path "$env:USERPROFILE\Desktop\system.txt"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    $info = Get-TwSystemInfo
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Tweaker $((Get-TwContext).Version) - $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    foreach ($p in 'ComputerName', 'Os', 'Edition', 'Architecture', 'Manufacturer', 'Cpu', 'Cores', 'Gpu', 'RamGB') {
        $lines.Add(('{0,-13}: {1}' -f $p, $info.$p))
    }
    if ($info.Uptime) { $lines.Add(('{0,-13}: {1:%d}d {1:hh}h {1:mm}m' -f 'Uptime', $info.Uptime)) }
    foreach ($d in $info.Disks) {
        $lines.Add(('Disk {0,-8}: {1} {2} GB free of {3} GB {4}' -f $d.Drive, $d.Media, $d.FreeGB, $d.SizeGB, $d.Label))
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Write system report')) {
        [System.IO.File]::WriteAllLines($Path, $lines, (New-Object System.Text.UTF8Encoding($true)))
    }
}
