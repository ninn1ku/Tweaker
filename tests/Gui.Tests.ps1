BeforeDiscovery {
    $script:NoSta = [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA'
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'GUI (read-only, rendered off-screen)' -Skip:$script:NoSta {
    BeforeAll {
        $script:DataRoot = New-TwTestContext
        (Get-TwContext).ReadOnly = $true
        $null = Use-TwFakeSystem
        Set-TwFakeRegistry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 'DWord' 0
        $script:Png = Join-Path ([System.IO.Path]::GetTempPath()) ('tweaker-gui-' + [guid]::NewGuid().ToString('N') + '.png')
    }
    AfterAll {
        Remove-Item $script:Png -Force -ErrorAction SilentlyContinue
    }

    It 'parses all XAML resources' {
        Initialize-TwWpf
        foreach ($p in 'src/ui/themes/Dark.xaml', 'src/ui/themes/Light.xaml', 'src/ui/themes/Styles.xaml') {
            { [Windows.Markup.XamlReader]::Parse((Get-TwResourceText -Path $p)) } | Should -Not -Throw
        }
    }

    It 'renders the window and shows the detected state' {
        Show-TwMainWindow -RenderPath $script:Png -Theme Dark -Category interface | Should -Be 0
        (Get-Item $script:Png).Length | Should -BeGreaterThan 10000
        $item = $script:TwUi.Items | Where-Object Id -eq 'interface.show-file-extensions'
        $item.State | Should -Be 'Applied'
        $item.IsOn | Should -BeTrue
        $item.CanToggle | Should -BeFalse   # read-only
        $other = $script:TwUi.Items | Where-Object Id -eq 'interface.show-hidden-files'
        $other.IsOn | Should -BeFalse
    }

    It 'marks pending changes and counts them' {
        Show-TwMainWindow -RenderPath $script:Png -Theme Light | Should -Be 0
        $item = $script:TwUi.Items | Where-Object Id -eq 'interface.show-hidden-files'
        $item.IsOn = $true
        $item.IsPending | Should -BeTrue
        @($script:TwUi.Items | Where-Object IsPending).Count | Should -Be 1
    }

    It 'filters by search text across categories' {
        $script:TwUi.Controls.SearchBox.Text = 'DiagTrack'
        Update-TwView
        @($script:TwUi.Items | Where-Object IsVisible | ForEach-Object Id) | Should -Contain 'privacy.disable-telemetry'
    }

    It 'never changed the system' {
        @($script:Fake.Calls | Where-Object { $_ -notlike 'WHATIF*' }).Count | Should -Be 0
    }
}
