BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $null = New-TwTestContext
}

Describe 'Built-in apps (Appx)' {
    It 'protects <_>' -ForEach @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.VCLibs.140.00', 'Microsoft.UI.Xaml.2.8',
        'Microsoft.NET.Native.Framework.2.2', 'Microsoft.SecHealthUI', 'Microsoft.MicrosoftEdge.Stable', 'Microsoft.Windows.ShellExperienceHost',
        'Microsoft.Windows.StartMenuExperienceHost', 'MicrosoftWindows.Client.CBS') {
        Test-TwAppxProtected -Name $_ | Should -BeTrue
    }

    It 'never lists a protected package as bloatware' {
        foreach ($b in (Get-TwAppxCatalog).bloatware) { Test-TwAppxProtected -Name $b.name | Should -BeFalse -Because $b.name }
    }

    It 'has unique bloatware names with ru/en titles' {
        $names = @((Get-TwAppxCatalog).bloatware.name)
        ($names | Select-Object -Unique).Count | Should -Be $names.Count
        foreach ($b in (Get-TwAppxCatalog).bloatware) { $b.title.ru | Should -Not -BeNullOrEmpty; $b.title.en | Should -Not -BeNullOrEmpty }
    }

    It 'refuses to remove a protected package' {
        Use-TwTripwire
        (Remove-TwAppx -Name 'Microsoft.WindowsStore').Status | Should -Be 'Skipped'
        Should -Invoke Remove-AppxPackage -Times 0 -Exactly
    }

    It 'removes nothing with -WhatIf' {
        Use-TwTripwire
        (Remove-TwAppx -Name 'Clipchamp.Clipchamp' -WhatIf).Status | Should -Be 'WhatIf'
        Should -Invoke Remove-AppxPackage -Times 0 -Exactly
    }
}

Describe 'WinGet catalog' {
    It 'has unique, well-formed ids' {
        $ids = @(Get-TwAppCatalog | ForEach-Object Id)
        $ids.Count | Should -BeGreaterThan 20
        ($ids | Select-Object -Unique).Count | Should -Be $ids.Count
        foreach ($id in $ids) { $id | Should -Match '^[A-Za-z0-9][A-Za-z0-9.+_-]*$' }
    }

    It 'rejects ids that could inject arguments' {
        { Install-TwWingetPackage -Id '--source evil' -WhatIf } | Should -Throw
    }
}

Describe 'Cleanup' {
    It 'has names and hints for every target' {
        Import-TwLanguage -Language ru
        foreach ($t in Get-TwCleanupTarget) {
            Get-TwString "cleanup.$($t.Id)" | Should -Not -Be "cleanup.$($t.Id)"
            Get-TwString "cleanup.$($t.Id).hint" | Should -Not -Be "cleanup.$($t.Id).hint"
        }
    }

    It 'deletes nothing with -WhatIf' {
        Use-TwTripwire
        Mock Remove-Item { throw 'Tripwire: Remove-Item' }
        Mock Measure-TwCleanupTarget { 1234 }
        (Invoke-TwCleanup -Id temp -WhatIf).Status | Should -Be 'WhatIf'
        Should -Invoke Remove-Item -Times 0 -Exactly
    }

    It 'formats sizes' {
        Format-TwSize 0 | Should -Match '^0 B$'
        Format-TwSize (1.5GB) | Should -Match '^1[.,]5 GB$'
        Format-TwSize $null | Should -Be '?'
    }
}

Describe 'DNS presets' {
    It 'has DHCP and public resolvers with valid addresses' {
        $presets = @(Get-TwDnsPreset)
        $presets.id | Should -Contain 'dhcp'
        foreach ($p in $presets | Where-Object id -ne 'dhcp') {
            foreach ($ip in $p.ipv4) { [System.Net.IPAddress]::Parse($ip).AddressFamily | Should -Be 'InterNetwork' }
            foreach ($ip in $p.ipv6) { [System.Net.IPAddress]::Parse($ip).AddressFamily | Should -Be 'InterNetworkV6' }
            $p.doh | Should -Match '^https://'
        }
    }
}

Describe 'Classic panels' {
    It 'have localized names' {
        Import-TwLanguage -Language en
        foreach ($p in Get-TwClassicPanel) { Get-TwString "panel.$($p.Id)" | Should -Not -Be "panel.$($p.Id)" }
    }
}
