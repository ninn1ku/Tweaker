# Tool pages (built in code): DNS panel, built-in apps, WinGet, cleanup, tools, system info.
# Every long operation runs through Start-TwUiJob; read-only mode disables actions.

function New-TwSection {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates UI objects only')]
    param([Parameter(Mandatory)]$Panel, [string]$Title, [string]$Text)
    $card = New-TwCard
    $stack = New-Object Windows.Controls.StackPanel
    if ($Title) { [void]$stack.Children.Add((New-TwText -Text $Title -Bold -Size 15 -Margin '0,0,0,4')) }
    if ($Text) { [void]$stack.Children.Add((New-TwText -Text $Text -Brush 'Tw.SubText' -Margin '0,0,0,10')) }
    $card.Child = $stack
    [void]$Panel.Children.Add($card)
    return $stack
}

function New-TwButtonRow {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates UI objects only')]
    param()
    $row = New-Object Windows.Controls.WrapPanel
    $row.Margin = '0,4,0,0'
    return $row
}

function Add-TwActionButton {
    <#
    .SYNOPSIS
        Adds a button to a row; disabled in read-only mode unless -Always.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Row, [string]$Text, [scriptblock]$OnClick, [string]$Style = 'Tw.Button', [switch]$Always, [string]$ToolTip)
    $b = New-TwButton -Text $Text -OnClick $OnClick -Style $Style -Margin '0,0,8,8' -ToolTip $ToolTip
    if ($script:TwUi.ReadOnly -and -not $Always) { $b.IsEnabled = $false }
    [void]$Row.Children.Add($b)
    return $b
}

function Confirm-TwAction {
    <#
    .SYNOPSIS
        Shows a confirmation dialog and runs -OnConfirm when accepted.
    #>
    [CmdletBinding()]
    param([string]$Title, [object[]]$Body, [string]$ConfirmText, [scriptblock]$OnConfirm, [switch]$Danger)
    $style = if ($Danger) { 'Tw.DangerButton' } else { 'Tw.AccentButton' }
    Show-TwDialog -Title $Title -Body $Body -Buttons @(
        @{ Text = $ConfirmText; Style = $style; Action = $OnConfirm },
        @{ Text = (Get-TwString 'ui.dlg.cancel') })
}

# --- DNS (network page) -------------------------------------------------------------

function Initialize-TwDnsPanel {
    [CmdletBinding()]
    param()
    $ui = $script:TwUi
    $border = $ui.Controls.DnsPanel
    $border.Visibility = 'Visible'
    $stack = New-Object Windows.Controls.StackPanel
    [void]$stack.Children.Add((New-TwText -Text (Get-TwString 'dns.title') -Bold -Size 15 -Margin '0,0,0,4'))
    $hint = Get-TwString 'dns.text'
    if (Test-TwDohSupported) { $hint += ' ' + (Get-TwString 'dns.doh') }
    [void]$stack.Children.Add((New-TwText -Text $hint -Brush 'Tw.SubText' -Margin '0,0,0,10'))

    $adapters = @(Get-TwNetworkAdapter)
    if ($adapters.Count -eq 0) {
        [void]$stack.Children.Add((New-TwText -Text (Get-TwString 'dns.noAdapters') -Brush 'Tw.Moderate'))
        $border.Child = $stack
        return
    }
    $row = New-TwButtonRow
    $adapterBox = New-Object Windows.Controls.ComboBox
    $adapterBox.SetResourceReference([Windows.FrameworkElement]::StyleProperty, 'Tw.ComboBox')
    $adapterBox.Width = 300; $adapterBox.Margin = '0,0,8,8'
    foreach ($a in $adapters) {
        $ci = New-Object Windows.Controls.ComboBoxItem
        $current = if ($a.Dns.Count) { $a.Dns -join ', ' } else { '-' }
        $ci.Content = '{0} ({1})' -f $a.Name, $current
        $ci.ToolTip = $a.Description
        $ci.Tag = $a.Index
        [void]$adapterBox.Items.Add($ci)
    }
    $adapterBox.SelectedIndex = 0
    $presetBox = New-Object Windows.Controls.ComboBox
    $presetBox.SetResourceReference([Windows.FrameworkElement]::StyleProperty, 'Tw.ComboBox')
    $presetBox.Width = 320; $presetBox.Margin = '0,0,8,8'
    foreach ($p in Get-TwDnsPreset) {
        $ci = New-Object Windows.Controls.ComboBoxItem
        $ci.Content = Get-TwLocalizedText $p.name
        $ci.Tag = $p.id
        [void]$presetBox.Items.Add($ci)
    }
    $presetBox.SelectedIndex = 1
    [void]$row.Children.Add($adapterBox)
    [void]$row.Children.Add($presetBox)
    $ui.DnsAdapterBox = $adapterBox
    $ui.DnsPresetBox = $presetBox
    $null = Add-TwActionButton -Row $row -Text (Get-TwString 'dns.apply') -Style 'Tw.AccentButton' -OnClick {
        $u = $script:TwUi
        $jobArgs = @{ Index = [int]$u.DnsAdapterBox.SelectedItem.Tag; Preset = [string]$u.DnsPresetBox.SelectedItem.Tag }
        Start-TwUiJob -Code '$null = Start-TwBackupSession; Set-TwDnsServer -InterfaceIndex $TwJobArgs.Index -Preset $TwJobArgs.Preset; Clear-TwDnsCache; "ok"' -Arguments $jobArgs -StatusText (Get-TwString 'dns.applying') -OnDone {
            param($output, $jobCtx, $err)
            $null = $jobCtx
            if ($output -contains 'ok') { Set-TwStatus -Text (Get-TwString 'dns.done') -Kind Ok; Initialize-TwDnsPanel }
            else { Set-TwStatus -Text (Get-TwString 'ui.status.failed' $err) -Kind Error }
        }
    }
    $null = Add-TwActionButton -Row $row -Text (Get-TwString 'dns.flush') -OnClick {
        Start-TwUiJob -Code 'Clear-TwDnsCache; "ok"' -StatusText (Get-TwString 'dns.flush') -OnDone { param($o, $c, $e) $null = $o, $c, $e; Set-TwStatus -Text (Get-TwString 'dns.flushed') -Kind Ok }
    }
    [void]$stack.Children.Add($row)
    [void]$stack.Children.Add((New-TwText -Text (Get-TwString 'dns.undoHint') -Brush 'Tw.Muted' -Size 12 -Margin '0,4,0,0'))
    $border.Child = $stack
}

# --- Built-in apps ------------------------------------------------------------------

function Initialize-TwDebloatPage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Panel)
    $ui = $script:TwUi
    $top = New-TwSection -Panel $Panel -Title (Get-TwString 'debloat.title') -Text (Get-TwString 'debloat.text')
    $row = New-TwButtonRow
    $null = Add-TwActionButton -Row $row -Text (Get-TwString 'debloat.markRecommended') -Always -OnClick {
        foreach ($c in $script:TwUi.AppxChecks) { if ($c.Recommended -and $c.Risk -eq 'safe') { $c.Box.IsChecked = $true } }
    }
    $null = Add-TwActionButton -Row $row -Text (Get-TwString 'debloat.remove') -Style 'Tw.AccentButton' -OnClick {
        $selected = @($script:TwUi.AppxChecks | Where-Object { $_.Box.IsChecked })
        if ($selected.Count -eq 0) { Set-TwStatus -Text (Get-TwString 'debloat.nothing') -Kind Warning; return }
        $body = @((Get-TwString 'debloat.confirmText')) + @($selected | ForEach-Object { [string][char]0x2022 + ' ' + $_.Title })
        $script:TwUi.AppxToRemove = @($selected | ForEach-Object { $_.Name })
        Confirm-TwAction -Title (Get-TwString 'debloat.confirmTitle' $selected.Count) -Body $body -ConfirmText (Get-TwString 'debloat.remove') -Danger -OnConfirm {
            Start-TwUiJob -Code 'foreach ($n in $TwJobArgs.Names) { Remove-TwAppx -Name $n -Confirm:$false }' -Arguments @{ Names = $script:TwUi.AppxToRemove } -StatusText (Get-TwString 'debloat.removing') -OnDone {
                param($output, $jobCtx, $err)
                $null = $jobCtx, $err
                $ok = @($output | Where-Object { $_.Status -eq 'Success' }).Count
                $failed = @($output | Where-Object { $_.Status -eq 'Failed' })
                $lines = @((Get-TwString 'debloat.result' $ok, $failed.Count)) + @($failed | ForEach-Object { $_.Name + ': ' + $_.Message })
                Show-TwDialog -Title (Get-TwString 'debloat.title') -Body $lines
                Show-TwPage -Nav $script:TwUi.Controls.NavList.SelectedItem
            }
        }
    }
    [void]$top.Children.Add($row)

    $listHost = New-Object Windows.Controls.StackPanel
    [void]$Panel.Children.Add($listHost)
    $ui.AppxHost = $listHost
    [void]$listHost.Children.Add((New-TwText -Text (Get-TwString 'debloat.loading') -Brush 'Tw.Muted'))

    $od = New-TwSection -Panel $Panel -Title (Get-TwString 'debloat.onedrive.title') -Text (Get-TwString 'debloat.onedrive.text')
    [void]$od.Children.Add((New-TwText -Text (Get-TwString 'debloat.onedrive.warning') -Brush 'Tw.Advanced'))
    $odRow = New-TwButtonRow
    $null = Add-TwActionButton -Row $odRow -Text (Get-TwString 'debloat.onedrive.button') -Style 'Tw.DangerButton' -OnClick {
        Confirm-TwAction -Title (Get-TwString 'debloat.onedrive.title') -Body @((Get-TwString 'debloat.onedrive.warning')) -ConfirmText (Get-TwString 'debloat.onedrive.button') -Danger -OnConfirm {
            Start-TwUiJob -Code 'Uninstall-TwOneDrive -Confirm:$false' -StatusText (Get-TwString 'debloat.removing') -OnDone {
                param($o, $c, $e)
                $null = $o, $c
                if ($e) { Set-TwStatus -Text (Get-TwString 'ui.status.failed' $e) -Kind Error } else { Set-TwStatus -Text (Get-TwString 'debloat.onedrive.done') -Kind Ok }
            }
        }
    }
    [void]$od.Children.Add($odRow)
    [void]$Panel.Children.Add((New-TwText -Text (Get-TwString 'debloat.edgeNote') -Brush 'Tw.Muted' -Size 12 -Margin '2,4,0,0'))

    Start-TwUiJob -Code 'Get-TwInstalledAppx' -StatusText (Get-TwString 'debloat.loading') -OnDone {
        param($output, $jobCtx, $err)
        $null = $jobCtx, $err
        $u = $script:TwUi
        $u.AppxHost.Children.Clear()
        $u.AppxChecks = New-Object System.Collections.ArrayList
        $apps = @($output | Where-Object { $_.PSObject.Properties['Protected'] -and -not $_.Protected })
        foreach ($grp in @(@{ Key = 'debloat.recommended'; Items = @($apps | Where-Object Recommended | Sort-Object Title) },
                @{ Key = 'debloat.other'; Items = @($apps | Where-Object { -not $_.Recommended } | Sort-Object Name) })) {
            if ($grp.Items.Count -eq 0) { continue }
            $sec = New-TwSection -Panel $u.AppxHost -Title (Get-TwString $grp.Key $grp.Items.Count)
            $wrap = New-Object Windows.Controls.WrapPanel
            foreach ($a in $grp.Items) {
                $cb = New-TwCheckBox -Text $a.Title -Checked $false -Margin '0,4,18,4'
                $cb.Width = 300
                $cb.ToolTip = '{0} {1}' -f $a.Name, $a.Version
                if ($u.ReadOnly) { $cb.IsEnabled = $false }
                [void]$wrap.Children.Add($cb)
                [void]$u.AppxChecks.Add([pscustomobject]@{ Name = $a.Name; Title = $a.Title; Recommended = $a.Recommended; Risk = $a.Risk; Box = $cb })
            }
            [void]$sec.Children.Add($wrap)
        }
        if ($apps.Count -eq 0) { [void]$u.AppxHost.Children.Add((New-TwText -Text (Get-TwString 'debloat.none') -Brush 'Tw.Muted')) }
        Set-TwStatus -Text (Get-TwString 'ui.status.ready') -Kind Ok
    }
}

# --- WinGet -------------------------------------------------------------------------

function Initialize-TwAppsPage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Panel)
    $ui = $script:TwUi
    if (-not (Test-TwWinget)) {
        $s = New-TwSection -Panel $Panel -Title (Get-TwString 'apps.noWinget.title') -Text (Get-TwString 'apps.noWinget.text')
        $r = New-TwButtonRow
        $null = Add-TwActionButton -Row $r -Text (Get-TwString 'apps.noWinget.button') -Always -OnClick { Start-Process 'ms-windows-store://pdp/?productid=9NBLGGH4NNS1' }
        [void]$s.Children.Add($r)
        return
    }
    $top = New-TwSection -Panel $Panel -Title (Get-TwString 'apps.title') -Text (Get-TwString 'apps.text')
    $row = New-TwButtonRow
    $null = Add-TwActionButton -Row $row -Text (Get-TwString 'apps.install') -Style 'Tw.AccentButton' -OnClick {
        $ids = @($script:TwUi.AppChecks | Where-Object { $_.Box.IsChecked } | ForEach-Object { $_.Id })
        if ($ids.Count -eq 0) { Set-TwStatus -Text (Get-TwString 'apps.nothing') -Kind Warning; return }
        $code = '$i = 0; foreach ($id in $TwJobArgs.Ids) { $i++; $TwSync.Progress = [int](100 * ($i - 1) / $TwJobArgs.Ids.Count); Install-TwWingetPackage -Id $id }'
        Start-TwUiJob -Code $code -Arguments @{ Ids = $ids } -StatusText (Get-TwString 'apps.installing' $ids.Count) -OnDone {
            param($output, $jobCtx, $err)
            $null = $jobCtx, $err
            $ok = @($output | Where-Object { $_.Status -eq 'Success' }).Count
            $failed = @($output | Where-Object { $_.Status -eq 'Failed' })
            $lines = @((Get-TwString 'apps.result' $ok, $failed.Count)) + @($failed | ForEach-Object { '{0}: winget {1}' -f $_.Id, $_.ExitCode })
            Show-TwDialog -Title (Get-TwString 'apps.title') -Body $lines
        }
    }
    $null = Add-TwActionButton -Row $row -Text (Get-TwString 'apps.updateAll') -OnClick {
        Start-TwUiJob -Code 'Update-TwWingetAll' -StatusText (Get-TwString 'apps.updating') -OnDone {
            param($o, $c, $e)
            $null = $c
            $code = @($o | Where-Object { $_.PSObject.Properties['ExitCode'] }) | Select-Object -Last 1
            Set-TwStatus -Text (Get-TwString 'apps.updated' $(if ($code) { $code.ExitCode } else { $e })) -Kind Ok
        }
    }
    [void]$top.Children.Add($row)
    $ui.AppChecks = New-Object System.Collections.ArrayList
    foreach ($g in (Get-TwAppCatalog | Group-Object Group)) {
        $sec = New-TwSection -Panel $Panel -Title $g.Group[0].GroupName
        $wrap = New-Object Windows.Controls.WrapPanel
        foreach ($a in $g.Group) {
            $cb = New-TwCheckBox -Text $a.Name -Checked $false -Margin '0,4,18,4'
            $cb.Width = 210
            $cb.ToolTip = $a.Id
            if ($ui.ReadOnly) { $cb.IsEnabled = $false }
            [void]$wrap.Children.Add($cb)
            [void]$ui.AppChecks.Add([pscustomobject]@{ Id = $a.Id; Box = $cb })
        }
        [void]$sec.Children.Add($wrap)
    }
}

# --- Cleanup ------------------------------------------------------------------------

function Initialize-TwCleanupPage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Panel)
    $ui = $script:TwUi
    $top = New-TwSection -Panel $Panel -Title (Get-TwString 'cleanup.title') -Text (Get-TwString 'cleanup.text')
    $ui.CleanupRows = New-Object System.Collections.ArrayList
    foreach ($t in Get-TwCleanupTarget) {
        $dock = New-Object Windows.Controls.DockPanel
        $dock.Margin = '0,4,0,6'
        $size = New-TwText -Text '...' -Brush 'Tw.SubText' -Margin '12,0,0,0'
        [Windows.Controls.DockPanel]::SetDock($size, 'Right')
        [void]$dock.Children.Add($size)
        $stack = New-Object Windows.Controls.StackPanel
        $cb = New-TwCheckBox -Text (Get-TwString "cleanup.$($t.Id)") -Checked ($t.Id -in 'temp', 'wucache', 'docache', 'thumbcache') -Margin '0'
        if ($ui.ReadOnly) { $cb.IsEnabled = $false }
        [void]$stack.Children.Add($cb)
        $brush = if ($t.Risk -eq 'advanced') { 'Tw.Advanced' } else { 'Tw.Muted' }
        [void]$stack.Children.Add((New-TwText -Text (Get-TwString "cleanup.$($t.Id).hint") -Brush $brush -Size 12 -Margin '26,2,0,0'))
        [void]$dock.Children.Add($stack)
        [void]$top.Children.Add($dock)
        [void]$ui.CleanupRows.Add([pscustomobject]@{ Id = $t.Id; Box = $cb; Size = $size; Risk = $t.Risk })
    }
    $row = New-TwButtonRow
    $row.Margin = '0,10,0,0'
    $null = Add-TwActionButton -Row $row -Text (Get-TwString 'cleanup.run') -Style 'Tw.AccentButton' -OnClick {
        $sel = @($script:TwUi.CleanupRows | Where-Object { $_.Box.IsChecked })
        if ($sel.Count -eq 0) { Set-TwStatus -Text (Get-TwString 'cleanup.nothing') -Kind Warning; return }
        $script:TwUi.CleanupIds = @($sel | ForEach-Object { $_.Id })
        $body = @($sel | ForEach-Object { [string][char]0x2022 + ' ' + (Get-TwString "cleanup.$($_.Id)") + '  ' + $_.Size.Text })
        if (@($sel | Where-Object Risk -eq 'advanced').Count) { $body += Get-TwString 'cleanup.dismresetbase.hint' }
        Confirm-TwAction -Title (Get-TwString 'cleanup.confirm') -Body $body -ConfirmText (Get-TwString 'cleanup.run') -OnConfirm {
            Start-TwUiJob -Code 'foreach ($id in $TwJobArgs.Ids) { Invoke-TwCleanup -Id $id -Confirm:$false }' -Arguments @{ Ids = $script:TwUi.CleanupIds } -StatusText (Get-TwString 'cleanup.running') -OnDone {
                param($output, $jobCtx, $err)
                $null = $jobCtx, $err
                $res = @($output | Where-Object { $_.PSObject.Properties['Freed'] })
                $total = ($res | Measure-Object -Property Freed -Sum).Sum
                $lines = @((Get-TwString 'cleanup.result' (Format-TwSize $total))) + @($res | ForEach-Object { '{0}: {1} {2}' -f (Get-TwString "cleanup.$($_.Id)"), (Format-TwSize $_.Freed), $_.Message })
                Show-TwDialog -Title (Get-TwString 'cleanup.title') -Body $lines
                Show-TwPage -Nav $script:TwUi.Controls.NavList.SelectedItem
            }
        }
    }
    [void]$top.Children.Add($row)
    Start-TwUiJob -Code 'foreach ($t in Get-TwCleanupTarget) { [pscustomobject]@{ Id = $t.Id; Bytes = (Measure-TwCleanupTarget -Id $t.Id) } }' -StatusText (Get-TwString 'cleanup.measuring') -OnDone {
        param($output, $jobCtx, $err)
        $null = $jobCtx, $err
        foreach ($m in @($output | Where-Object { $_.PSObject.Properties['Bytes'] })) {
            $r = $script:TwUi.CleanupRows | Where-Object Id -eq $m.Id
            if ($r) { $r.Size.Text = if ($null -eq $m.Bytes) { Get-TwString 'cleanup.unknownSize' } else { Format-TwSize $m.Bytes } }
        }
        Set-TwStatus -Text (Get-TwString 'ui.status.ready') -Kind Ok
    }
}

# --- Tools --------------------------------------------------------------------------

function Initialize-TwToolsPage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Panel)
    $repair = New-TwSection -Panel $Panel -Title (Get-TwString 'tools.repair.title') -Text (Get-TwString 'tools.repair.text')
    $row = New-TwButtonRow
    $null = Add-TwActionButton -Row $row -Text (Get-TwString 'tools.sfc') -OnClick {
        Start-TwUiJob -Code 'Invoke-TwSystemFileCheck' -StatusText (Get-TwString 'tools.running') -OnDone {
            param($o, $c, $e)
            $null = $c, $e
            $r = @($o) | Select-Object -Last 1
            Show-TwDialog -Title (Get-TwString 'tools.sfc') -Body @((Get-TwString 'tools.exitCode' $r.ExitCode), ($r.Output -split "`n" | Select-Object -Last 6) -join "`n")
        }
    }
    $null = Add-TwActionButton -Row $row -Text (Get-TwString 'tools.dism') -OnClick {
        Start-TwUiJob -Code 'Invoke-TwDismRestoreHealth' -StatusText (Get-TwString 'tools.running') -OnDone {
            param($o, $c, $e)
            $null = $c, $e
            $r = @($o) | Select-Object -Last 1
            Show-TwDialog -Title (Get-TwString 'tools.dism') -Body @((Get-TwString 'tools.exitCode' $r.ExitCode))
        }
    }
    $null = Add-TwActionButton -Row $row -Text (Get-TwString 'tools.wureset') -OnClick {
        Confirm-TwAction -Title (Get-TwString 'tools.wureset') -Body @((Get-TwString 'tools.wureset.text')) -ConfirmText (Get-TwString 'tools.wureset') -OnConfirm {
            Start-TwUiJob -Code 'Reset-TwWindowsUpdate -Confirm:$false' -StatusText (Get-TwString 'tools.running') -OnDone { param($o, $c, $e) $null = $o, $c, $e; Set-TwStatus -Text (Get-TwString 'tools.done') -Kind Ok }
        }
    }
    $null = Add-TwActionButton -Row $row -Text (Get-TwString 'tools.explorer') -OnClick { Restart-TwExplorer -Confirm:$false; Set-TwStatus -Text (Get-TwString 'cli.explorerRestarted') -Kind Ok }
    $null = Add-TwActionButton -Row $row -Text (Get-TwString 'tools.netreset') -Style 'Tw.DangerButton' -OnClick {
        Confirm-TwAction -Title (Get-TwString 'tools.netreset') -Body @((Get-TwString 'tools.netreset.text')) -ConfirmText (Get-TwString 'tools.netreset') -Danger -OnConfirm {
            Start-TwUiJob -Code 'Reset-TwNetworkStack -Confirm:$false' -StatusText (Get-TwString 'tools.running') -OnDone { param($o, $c, $e) $null = $o, $c, $e; Set-TwStatus -Text (Get-TwString 'tools.rebootNow') -Kind Warning }
        }
    }
    [void]$repair.Children.Add($row)

    $safety = New-TwSection -Panel $Panel -Title (Get-TwString 'tools.safety.title') -Text (Get-TwString 'tools.safety.text')
    $row2 = New-TwButtonRow
    $null = Add-TwActionButton -Row $row2 -Text (Get-TwString 'ui.restorePoint') -OnClick { Start-TwRestorePointJob }
    $null = Add-TwActionButton -Row $row2 -Text (Get-TwString 'ui.backups') -Always -OnClick { Show-TwBackupsDialog }
    $null = Add-TwActionButton -Row $row2 -Text (Get-TwString 'tools.logs') -Always -OnClick {
        $dir = (Get-TwContext).LogDir
        if (Test-Path -LiteralPath $dir) { Start-Process -FilePath 'explorer.exe' -ArgumentList $dir } else { Set-TwStatus -Text (Get-TwString 'tools.noLogs') -Kind Warning }
    }
    [void]$safety.Children.Add($row2)
    $rpHost = New-Object Windows.Controls.StackPanel
    [void]$safety.Children.Add($rpHost)
    $script:TwUi.RestorePointHost = $rpHost
    if (-not $script:TwUi.ReadOnly) {
        Start-TwUiJob -Code 'Get-TwRestorePoint' -StatusText (Get-TwString 'tools.loadingRp') -OnDone {
            param($o, $c, $e)
            $null = $c, $e
            $points = @($o | Where-Object { $_.PSObject.Properties['Sequence'] })
            $text = if ($points.Count) { (Get-TwString 'tools.rpList') + "`n" + (($points | Select-Object -First 8 | ForEach-Object { '{0:yyyy-MM-dd HH:mm}  {1}' -f $_.Created, $_.Description }) -join "`n") } else { Get-TwString 'tools.rpNone' }
            [void]$script:TwUi.RestorePointHost.Children.Add((New-TwText -Text $text -Brush 'Tw.SubText' -Size 12 -Margin '0,8,0,0'))
            Set-TwStatus -Text (Get-TwString 'ui.status.ready') -Kind Ok
        }
    }

    $panels = New-TwSection -Panel $Panel -Title (Get-TwString 'tools.panels.title')
    $row3 = New-TwButtonRow
    foreach ($p in Get-TwClassicPanel) {
        $b = Add-TwActionButton -Row $row3 -Text (Get-TwString "panel.$($p.Id)") -Always -OnClick { param($s, $e) $null = $e; Open-TwClassicPanel -Id $s.Tag }
        $b.Tag = $p.Id
    }
    [void]$panels.Children.Add($row3)
}

# --- System info --------------------------------------------------------------------

function Initialize-TwSysinfoPage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Panel)
    $sec = New-TwSection -Panel $Panel -Title (Get-TwString 'sysinfo.title')
    $script:TwUi.SysinfoHost = $sec
    [void]$sec.Children.Add((New-TwText -Text (Get-TwString 'sysinfo.loading') -Brush 'Tw.Muted'))
    Start-TwUiJob -Code 'Get-TwSystemInfo' -StatusText (Get-TwString 'sysinfo.loading') -OnDone {
        param($o, $c, $e)
        $null = $c, $e
        $info = @($o | Where-Object { $_.PSObject.Properties['Cpu'] }) | Select-Object -Last 1
        $host2 = $script:TwUi.SysinfoHost
        $host2.Children.Clear()
        [void]$host2.Children.Add((New-TwText -Text (Get-TwString 'sysinfo.title') -Bold -Size 15 -Margin '0,0,0,10'))
        if (-not $info) { [void]$host2.Children.Add((New-TwText -Text (Get-TwString 'ui.status.failed' $e) -Brush 'Tw.Advanced')); return }
        $grid = New-Object Windows.Controls.Grid
        [void]$grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::new(190) }))
        [void]$grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
        $rows = @(
            @('sysinfo.os', $info.Os), @('sysinfo.edition', $info.Edition), @('sysinfo.arch', $info.Architecture),
            @('sysinfo.device', $info.Manufacturer), @('sysinfo.cpu', $info.Cpu), @('sysinfo.cores', $info.Cores),
            @('sysinfo.gpu', $info.Gpu), @('sysinfo.ram', ('{0} GB' -f $info.RamGB)),
            @('sysinfo.uptime', $(if ($info.Uptime) { '{0}d {1}h {2}m' -f $info.Uptime.Days, $info.Uptime.Hours, $info.Uptime.Minutes } else { '-' })))
        foreach ($d in $info.Disks) { $rows += , @('sysinfo.disk', ('{0} {1} - {2} / {3} GB {4}' -f $d.Drive, $d.Media, $d.FreeGB, $d.SizeGB, $d.Label)) }
        $i = 0
        foreach ($r in $rows) {
            [void]$grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
            $k = New-TwText -Text (Get-TwString $r[0]) -Brush 'Tw.SubText' -Margin '0,3,12,3'
            $v = New-TwText -Text ([string]$r[1]) -Margin '0,3,0,3'
            $v.TextWrapping = 'Wrap'
            [Windows.Controls.Grid]::SetRow($k, $i); [Windows.Controls.Grid]::SetRow($v, $i); [Windows.Controls.Grid]::SetColumn($v, 1)
            [void]$grid.Children.Add($k); [void]$grid.Children.Add($v)
            $i++
        }
        [void]$host2.Children.Add($grid)
        $row = New-TwButtonRow
        $row.Margin = '0,12,0,0'
        $null = Add-TwActionButton -Row $row -Text (Get-TwString 'sysinfo.export') -Always -OnClick {
            $dlg = New-Object Microsoft.Win32.SaveFileDialog
            $dlg.FileName = 'system-info-{0}.txt' -f $env:COMPUTERNAME
            $dlg.Filter = 'Text (*.txt)|*.txt'
            if ($dlg.ShowDialog($script:TwUi.Window)) {
                Export-TwSystemReport -Path $dlg.FileName -Confirm:$false
                Set-TwStatus -Text (Get-TwString 'sysinfo.exported' $dlg.FileName) -Kind Ok
            }
        }
        [void]$host2.Children.Add($row)
        Set-TwStatus -Text (Get-TwString 'ui.status.ready') -Kind Ok
    }
}
