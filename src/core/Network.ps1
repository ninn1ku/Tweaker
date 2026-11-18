# DNS presets per adapter, DNS cache flush and network stack reset.

function Get-TwDnsPreset {
    <#
    .SYNOPSIS
        DNS presets from config/dns.json.
    #>
    [CmdletBinding()]
    param([string]$Id)
    $all = @((Get-TwJsonResource -Path 'config/dns.json').presets)
    if ($Id) { return @($all | Where-Object { $_.id -eq $Id }) }
    return $all
}

function Get-TwNetworkAdapter {
    <#
    .SYNOPSIS
        Connected physical adapters with their current IPv4 DNS servers.
    #>
    [CmdletBinding()]
    param()
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    foreach ($a in $adapters) {
        $dns = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses })
        [pscustomobject]@{
            Index       = [int]$a.ifIndex
            Name        = $a.Name
            Description = $a.InterfaceDescription
            Dns         = @($dns | Where-Object { $_ })
        }
    }
}

function Test-TwDohSupported {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return ((Get-TwOsInfo).Build -ge 22000 -and [bool](Get-Command -Name Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue))
}

function Set-TwDnsServer {
    <#
    .SYNOPSIS
        Applies a DNS preset to one adapter (backing up the previous servers first).
    .DESCRIPTION
        "dhcp" returns the adapter to automatic DNS. On Windows 11 the DoH template of
        the preset is registered so the servers can be used over HTTPS (Settings ->
        Network -> DNS encryption). Previous servers are written to the backup and can
        be restored from the rollback manager.
    .EXAMPLE
        Set-TwDnsServer -InterfaceIndex 12 -Preset cloudflare -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][int]$InterfaceIndex,
        [Parameter(Mandatory)][string]$Preset
    )
    $p = Get-TwDnsPreset -Id $Preset | Select-Object -First 1
    if (-not $p) { throw "Unknown DNS preset: $Preset" }
    $v4 = @(Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object { $_.ServerAddresses })
    $v6 = @(Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses })
    $dhcp = $null
    try { $dhcp = (Get-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop).Dhcp } catch { Write-Verbose 'DHCP state unknown' }
    Add-TwBackupEntry -Entry @{ tweakId = 'network.dns'; kind = 'dns'; name = [string]$InterfaceIndex; ipv4 = @($v4); ipv6 = @($v6) }
    if ($PSCmdlet.ShouldProcess("adapter $InterfaceIndex", "Set DNS preset $Preset")) {
        if ($Preset -eq 'dhcp') {
            Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ResetServerAddresses -ErrorAction Stop
        } else {
            $servers = @($p.ipv4)
            if ($v6.Count -gt 0) { $servers += @($p.ipv6) }
            Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ServerAddresses $servers -ErrorAction Stop
            if ($p.doh -and (Test-TwDohSupported)) {
                foreach ($ip in @($p.ipv4) + @($p.ipv6)) {
                    if (-not (Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue)) {
                        try { Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $p.doh -AllowFallbackToUdp $true -AutoUpgrade $true -ErrorAction Stop | Out-Null }
                        catch { Write-TwLog -Level Warning -Message "DoH template for $ip not registered: $($_.Exception.Message)" }
                    }
                }
            }
        }
        Write-TwLog -Level Success -Message ("DNS of adapter {0}: {1} -> {2} (DHCP before: {3})" -f $InterfaceIndex, ($v4 -join ', '), $Preset, $dhcp)
    }
}

function Restore-TwDnsServer {
    <#
    .SYNOPSIS
        Puts back DNS servers saved by Set-TwDnsServer (empty list = automatic).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Entry)
    $index = [int]$Entry.name
    $servers = @(@(Get-TwObjectProperty $Entry 'ipv4' @()) + @(Get-TwObjectProperty $Entry 'ipv6' @()) | Where-Object { $_ })
    if ($PSCmdlet.ShouldProcess("adapter $index", 'Restore DNS servers')) {
        if ($servers.Count -eq 0) { Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses -ErrorAction Stop }
        else { Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $servers -ErrorAction Stop }
    }
}

function Clear-TwDnsCache {
    <#
    .SYNOPSIS
        Flushes the DNS resolver cache (ipconfig /flushdns).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('DNS cache', 'Clear')) {
        Clear-DnsClientCache
        Write-TwLog -Level Success -Message 'DNS cache cleared'
    }
}

function Reset-TwNetworkStack {
    <#
    .SYNOPSIS
        netsh winsock reset + netsh int ip reset (needs a restart).
    .DESCRIPTION
        Last-resort fix for broken networking. Removes custom Winsock providers (some
        VPN/antivirus software must be reinstalled afterwards) and resets TCP/IP.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param()
    $a = Invoke-TwNativeCommand -FilePath 'netsh.exe' -ArgumentList 'winsock', 'reset'
    $b = Invoke-TwNativeCommand -FilePath 'netsh.exe' -ArgumentList 'int', 'ip', 'reset'
    Write-TwLog -Level Success -Message "Network stack reset (winsock: $($a.ExitCode), ip: $($b.ExitCode)); restart required"
}
