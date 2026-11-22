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

Describe 'Folder sweep' {
    # Runs on real files, but only inside Pester's own TestDrive folder.
    BeforeEach {
        $script:Root = Join-Path $TestDrive ('sweep-' + [guid]::NewGuid().ToString('N'))
        $script:Outside = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().ToString('N'))
        $old = (Get-Date).AddDays(-3)
        foreach ($rel in 'a.tmp', 'sub\b.tmp', 'sub\deep\c.tmp', 'ro.tmp') {
            $p = Join-Path $script:Root $rel
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $p)
            [System.IO.File]::WriteAllBytes($p, (New-Object byte[] 100))
            (Get-Item -LiteralPath $p).LastWriteTime = $old
        }
        (Get-Item -LiteralPath (Join-Path $script:Root 'ro.tmp')).IsReadOnly = $true
        [System.IO.File]::WriteAllBytes((Join-Path $script:Root 'fresh.tmp'), (New-Object byte[] 50))
        foreach ($d in 'sub\deep', 'sub') { (Get-Item -LiteralPath (Join-Path $script:Root $d)).LastWriteTime = $old }
        $null = New-Item -ItemType Directory -Path $script:Outside
        [System.IO.File]::WriteAllBytes((Join-Path $script:Outside 'keep.txt'), (New-Object byte[] 10))
        $null = cmd.exe /c mklink /J "$(Join-Path $script:Root 'link')" "$script:Outside"
    }

    It 'measures without deleting and never follows junctions' {
        $r = Invoke-TwFolderSweep -Path $script:Root
        $r.Files | Should -Be 5
        $r.Bytes | Should -Be 450
        Test-Path (Join-Path $script:Root 'a.tmp') | Should -BeTrue
    }

    It 'deletes old files (read-only too), keeps fresh ones, removes emptied folders' {
        $r = Invoke-TwFolderSweep -Path $script:Root -OlderThan (Get-Date).AddHours(-24) -Delete
        $r.Files | Should -Be 4
        $r.Bytes | Should -Be 400
        $r.Failed | Should -Be 0
        Test-Path (Join-Path $script:Root 'fresh.tmp') | Should -BeTrue
        Test-Path (Join-Path $script:Root 'sub') | Should -BeFalse
        Test-Path $script:Root | Should -BeTrue
        Test-Path (Join-Path $script:Outside 'keep.txt') | Should -BeTrue
    }

    It 'counts files in use as failed instead of stopping' {
        $locked = [System.IO.File]::Open((Join-Path $script:Root 'a.tmp'), 'Open', 'Read', 'None')
        try {
            $r = Invoke-TwFolderSweep -Path $script:Root -Delete
        } finally { $locked.Dispose() }
        $r.Failed | Should -Be 1
        Test-Path (Join-Path $script:Root 'a.tmp') | Should -BeTrue
        Test-Path (Join-Path $script:Root 'fresh.tmp') | Should -BeFalse
    }

    It 'returns zeros for a missing folder' {
        $r = Invoke-TwFolderSweep -Path (Join-Path $TestDrive 'nope')
        $r.Files | Should -Be 0
        $r.Bytes | Should -Be 0
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
        Mock Invoke-TwFolderSweep { throw 'Tripwire: Invoke-TwFolderSweep' } -ParameterFilter { $Delete }
        Mock Measure-TwCleanupTarget { 1234 }
        $r = Invoke-TwCleanup -Id temp -WhatIf
        $r.Status | Should -Be 'WhatIf'
        $r.Estimated | Should -Be 1234
        Should -Invoke Remove-Item -Times 0 -Exactly
        Should -Invoke Invoke-TwFolderSweep -Times 0 -Exactly -ParameterFilter { $Delete }
    }

    It 'counts the bytes it deletes and skips the separate measuring pass' {
        Use-TwTripwire
        Mock Measure-TwCleanupTarget { throw 'should not measure before cleaning' }
        Mock Invoke-TwCleanupSweep { [pscustomobject]@{ Bytes = [int64]4096; Files = 2; Failed = 1 } }
        $r = Invoke-TwCleanup -Id temp -Confirm:$false
        $r.Freed | Should -Be 4096
        $r.Message | Should -Match '1 file'
        Should -Invoke Invoke-TwCleanupSweep -Times 1 -Exactly -ParameterFilter { $Delete }
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
