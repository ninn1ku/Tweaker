# WPF user interface: main window, tweak cards, pending changes, background jobs.
# All UI text comes from config/lang via {tw:key} placeholders or Get-TwString.

function Get-TwViewModelSource {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace TweakerUI
{
    public class Bindable : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        public void Raise(string name)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(name));
        }
    }

    public class TweakItem : Bindable
    {
        public string Id { get; set; }
        public string Category { get; set; }
        public string Name { get; set; }
        public string Description { get; set; }
        public string Warning { get; set; }
        public string Risk { get; set; }
        public string RiskText { get; set; }
        public string UnverifiedText { get; set; }
        public string RebootText { get; set; }
        public string PendingText { get; set; }
        public string Details { get; set; }
        public string SearchText { get; set; }
        public bool Verified { get; set; }
        public bool RequiresReboot { get; set; }
        public bool Supported { get; set; }
        public bool ShowUnverified { get { return !Verified; } }
        public bool ShowReboot { get { return RequiresReboot; } }
        public bool HasWarning { get { return !String.IsNullOrEmpty(Warning); } }

        private bool _isOn;
        public bool IsOn
        {
            get { return _isOn; }
            set { if (_isOn == value) return; _isOn = value; Raise("IsOn"); Raise("IsPending"); }
        }

        private bool _isApplied;
        public bool IsApplied
        {
            get { return _isApplied; }
            set { if (_isApplied == value) return; _isApplied = value; Raise("IsApplied"); Raise("IsPending"); }
        }

        public bool IsPending { get { return _isOn != _isApplied; } }

        private string _state = "Unknown";
        public string State
        {
            get { return _state; }
            set { _state = value; Raise("State"); Raise("ShowState"); }
        }
        public bool ShowState { get { return _state == "Partial" || _state == "Unsupported" || _state == "Unknown"; } }

        private string _stateText = "";
        public string StateText
        {
            get { return _stateText; }
            set { _stateText = value; Raise("StateText"); }
        }

        private bool _canToggle;
        public bool CanToggle
        {
            get { return _canToggle; }
            set { _canToggle = value; Raise("CanToggle"); }
        }

        private bool _isVisible = true;
        public bool IsVisible
        {
            get { return _isVisible; }
            set { if (_isVisible == value) return; _isVisible = value; Raise("IsVisible"); }
        }
    }

    public class NavItem : Bindable
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string Icon { get; set; }
        public string Page { get; set; }

        private int _pending;
        public int PendingCount
        {
            get { return _pending; }
            set { _pending = value; Raise("PendingCount"); Raise("HasPending"); Raise("ShowCount"); }
        }
        public bool HasPending { get { return _pending > 0; } }

        private string _countText = "";
        public string CountText
        {
            get { return _countText; }
            set { _countText = value; Raise("CountText"); Raise("ShowCount"); }
        }
        public bool ShowCount { get { return _pending == 0 && !String.IsNullOrEmpty(_countText); } }
    }

    public static class Native
    {
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        public static void SetDarkTitleBar(IntPtr hwnd, bool dark)
        {
            int value = dark ? 1 : 0;
            try { DwmSetWindowAttribute(hwnd, 20, ref value, 4); } catch { }
        }
    }
}
'@
}

function Initialize-TwWpf {
    <#
    .SYNOPSIS
        Loads WPF assemblies and compiles the small view-model library once.
    #>
    [CmdletBinding()]
    param()
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    if (-not ('TweakerUI.TweakItem' -as [type])) {
        Add-Type -TypeDefinition (Get-TwViewModelSource) -Language CSharp
    }
}

function ConvertTo-TwXamlText {
    <#
    .SYNOPSIS
        Replaces {tw:key} placeholders with XML-escaped localized strings.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Xaml)
    return [regex]::Replace($Xaml, '\{tw:([a-zA-Z0-9_.]+)\}', {
            param($m)
            [System.Security.SecurityElement]::Escape((Get-TwString $m.Groups[1].Value))
        })
}

function Get-TwThemeDictionary {
    [CmdletBinding()]
    param([ValidateSet('Dark', 'Light')][string]$Theme)
    $text = Get-TwResourceText -Path "src/ui/themes/$Theme.xaml"
    return [Windows.Markup.XamlReader]::Parse($text)
}

function Resolve-TwTheme {
    <#
    .SYNOPSIS
        Maps Dark / Light / System to Dark or Light.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Theme = 'Dark')
    if ($Theme -eq 'System') {
        $v = Get-TwRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme'
        if ($v.Exists -and [int]$v.Value -eq 1) { return 'Light' }
        return 'Dark'
    }
    if ($Theme -eq 'Light') { return 'Light' }
    return 'Dark'
}

function Get-TwSystemAccentColor {
    <#
    .SYNOPSIS
        Windows accent colour (DWM AccentColor, stored as ABGR), or $null.
    #>
    [CmdletBinding()]
    param()
    $v = Get-TwRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'AccentColor'
    if (-not $v.Exists) { return $null }
    $n = [uint32]$v.Value
    $r = [byte]($n -band 0xFF); $g = [byte](($n -shr 8) -band 0xFF); $b = [byte](($n -shr 16) -band 0xFF)
    return [Windows.Media.Color]::FromRgb($r, $g, $b)
}

function Set-TwTheme {
    <#
    .SYNOPSIS
        Applies a theme (Dark, Light, System) to the main window.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Window,
        [ValidateSet('Dark', 'Light', 'System')][string]$Theme = 'Dark'
    )
    $resolved = Resolve-TwTheme -Theme $Theme
    $dict = Get-TwThemeDictionary -Theme $resolved
    $accent = Get-TwSystemAccentColor
    if ($accent) {
        # Keep readable contrast: lighten in dark mode, darken in light mode.
        $f = 1.0
        if ($resolved -eq 'Dark') { $f = 1.25 } else { $f = 0.85 }
        $c = [Windows.Media.Color]::FromRgb([byte][math]::Min(255, $accent.R * $f), [byte][math]::Min(255, $accent.G * $f), [byte][math]::Min(255, $accent.B * $f))
        $dict['Tw.Accent'] = New-Object Windows.Media.SolidColorBrush($c)
        $dict['Tw.AccentHover'] = New-Object Windows.Media.SolidColorBrush($c)
        $dict['Tw.AccentSoft'] = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromArgb(0x33, $c.R, $c.G, $c.B))
    }
    $merged = $Window.Resources.MergedDictionaries
    if ($PSCmdlet.ShouldProcess('window', "Theme $Theme")) {
        $merged[0] = $dict
        $ctx = Get-TwContext
        $ctx['Theme'] = $Theme
        try {
            $helper = New-Object System.Windows.Interop.WindowInteropHelper($Window)
            if ($helper.Handle -ne [IntPtr]::Zero) { [TweakerUI.Native]::SetDarkTitleBar($helper.Handle, $resolved -eq 'Dark') }
        } catch { Write-Verbose 'Title bar colour not changed' }
    }
}

function New-TwMainWindowObject {
    <#
    .SYNOPSIS
        Parses MainWindow.xaml (with theme and styles) and returns the window plus named controls.
    #>
    [CmdletBinding()]
    param([ValidateSet('Dark', 'Light', 'System')][string]$Theme = 'Dark')
    $resolved = Resolve-TwTheme -Theme $Theme
    $strip = { param($t) ($t -replace '(?s)^\s*<\?xml[^>]*\?>', '') }
    $themeText = & $strip (Get-TwResourceText -Path "src/ui/themes/$resolved.xaml")
    $stylesText = & $strip (Get-TwResourceText -Path 'src/ui/themes/Styles.xaml')
    $resources = "<ResourceDictionary><ResourceDictionary.MergedDictionaries>$themeText$stylesText</ResourceDictionary.MergedDictionaries></ResourceDictionary>"
    $xaml = (Get-TwResourceText -Path 'src/ui/MainWindow.xaml').Replace('<!--TW:RESOURCES-->', $resources)
    $xaml = ConvertTo-TwXamlText -Xaml $xaml
    $window = [Windows.Markup.XamlReader]::Parse($xaml)
    $controls = @{}
    foreach ($m in [regex]::Matches((Get-TwResourceText -Path 'src/ui/MainWindow.xaml'), 'x:Name="([A-Za-z0-9_]+)"')) {
        $name = $m.Groups[1].Value
        $controls[$name] = $window.FindName($name)
    }
    return [pscustomobject]@{ Window = $window; Controls = $controls }
}

function New-TwTweakItem {
    <#
    .SYNOPSIS
        Builds the bindable card model for a tweak definition.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Tweak, [bool]$ReadOnly)
    $item = New-Object TweakerUI.TweakItem
    $item.Id = $Tweak.id
    $item.Category = $Tweak.category
    $item.Name = Get-TwLocalizedText $Tweak.name
    $item.Description = Get-TwLocalizedText $Tweak.description
    $item.Warning = Get-TwLocalizedText (Get-TwObjectProperty $Tweak 'warning')
    $item.Risk = $Tweak.risk
    $item.RiskText = Get-TwString "risk.$($Tweak.risk)"
    $item.Verified = [bool]$Tweak.verified
    $item.UnverifiedText = Get-TwString 'ui.unverified'
    $item.RequiresReboot = [bool]$Tweak.requiresReboot
    $item.RebootText = Get-TwString 'ui.reboot'
    $item.PendingText = Get-TwString 'ui.pending'
    $item.Supported = Test-TwTweakSupported -Tweak $Tweak
    $item.CanToggle = $false
    $item.StateText = Get-TwString 'state.Unknown'
    $item.SearchText = ('{0} {1} {2} {3}' -f $item.Name, $item.Description, $Tweak.id, (Get-TwLocalizedText $Tweak.name)).ToLowerInvariant()

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($item.Name)
    $lines.Add('')
    $lines.Add((Get-TwString 'ui.details.id' $Tweak.id))
    $max = Get-TwObjectProperty $Tweak 'maxBuild'
    $builds = if ($max) { "$($Tweak.minBuild) - $max" } else { "$($Tweak.minBuild)+" }
    $lines.Add((Get-TwString 'ui.details.builds' $builds))
    $flags = @()
    if ($Tweak.requiresReboot) { $flags += Get-TwString 'docs.flag.reboot' }
    if ($Tweak.requiresSignOut) { $flags += Get-TwString 'docs.flag.signout' }
    if ($Tweak.requiresExplorerRestart) { $flags += Get-TwString 'docs.flag.explorer' }
    if ($flags.Count -gt 0) { $lines.Add((Get-TwString 'ui.details.requires' ($flags -join ', '))) }
    $lines.Add('')
    $lines.Add((Get-TwString 'ui.details.changes'))
    foreach ($r in @(Get-TwObjectProperty $Tweak 'registry' @())) {
        $n = if ($r.name) { $r.name } else { '(Default)' }
        $lines.Add(('  {0}\{1} = {2}' -f $r.path, $n, (ConvertTo-TwComparableRegistryValue -Type $r.type -Value $r.value)))
    }
    foreach ($s in @(Get-TwObjectProperty $Tweak 'services' @())) { $lines.Add(('  service {0}: {1}' -f $s.name, $s.startupType)) }
    foreach ($t in @(Get-TwObjectProperty $Tweak 'scheduledTasks' @())) { $lines.Add(('  task {0}: {1}' -f $t.path, $t.state)) }
    foreach ($f in @(Get-TwObjectProperty $Tweak 'optionalFeatures' @())) { $lines.Add(('  feature {0}: {1}' -f $f.name, $f.state)) }
    foreach ($c in @(Get-TwObjectProperty $Tweak 'commands' @())) { $lines.Add(('  command {0}' -f $c.name)) }
    $lines.Add('')
    $lines.Add((Get-TwString 'ui.details.source' $Tweak.source))
    $item.Details = $lines -join [Environment]::NewLine
    return $item
}

function Set-TwItemState {
    <#
    .SYNOPSIS
        Applies a detected state to a card (resets its pending flag).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][string]$State)
    if (-not $PSCmdlet.ShouldProcess($Item.Id, 'Update card state')) { return }
    $ui = $script:TwUi
    $Item.State = $State
    $Item.StateText = Get-TwString "state.$State"
    $applied = ($State -eq 'Applied')
    $Item.IsApplied = $applied
    $Item.IsOn = $applied
    $Item.CanToggle = (-not $ui.ReadOnly) -and $Item.Supported -and $State -ne 'Unsupported'
}

function Get-TwFunctionEntry {
    <#
    .SYNOPSIS
        Function definitions to copy into background runspaces.
    #>
    [CmdletBinding()]
    param()
    foreach ($f in Get-ChildItem -Path Function:\ | Where-Object { $_.Name -match '-Tw[A-Z]' }) {
        New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($f.Name, $f.Definition)
    }
}

function Start-TwUiJob {
    <#
    .SYNOPSIS
        Runs engine code in a background runspace so the window stays responsive.
    .DESCRIPTION
        The job gets a copy of the context whose log sink feeds a concurrent queue;
        the UI timer drains it into the log panel. OnDone runs on the UI thread with
        the job output and the context copy (to read flags such as RestorePointDone).
    .PARAMETER Code
        Script text. $TwJobArgs holds -Arguments, $TwSync the shared state.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Code,
        [hashtable]$Arguments = @{},
        [scriptblock]$OnDone,
        [string]$StatusText
    )
    $ui = $script:TwUi
    if (-not $PSCmdlet.ShouldProcess('background job', 'Start')) { return }
    $ctx = Get-TwContext
    $copy = @{}
    foreach ($k in @($ctx.Keys)) { if ($k -ne 'LogSink' -and $k -ne 'Tweaks') { $copy[$k] = $ctx[$k] } }

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($entry in $ui.FunctionEntries) { $iss.Commands.Add($entry) }
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Tw', $copy)
    $rs.SessionStateProxy.SetVariable('TwEmbedded', (Get-TwEmbeddedTable))
    $rs.SessionStateProxy.SetVariable('TwDevRoot', (Get-TwResourceRoot))
    $rs.SessionStateProxy.SetVariable('TwVersion', $ctx.Version)
    $rs.SessionStateProxy.SetVariable('TwSync', $ui.Sync)
    $rs.SessionStateProxy.SetVariable('TwJobArgs', $Arguments)
    $prefix = '$Tw.LogSink = { param($e) $TwSync.Log.Enqueue($e) }' + [Environment]::NewLine + '$ErrorActionPreference = "Continue"' + [Environment]::NewLine
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($prefix + $Code)
    $ui.Sync.Progress = -1
    $job = [pscustomobject]@{ PowerShell = $ps; Runspace = $rs; Handle = $ps.BeginInvoke(); OnDone = $OnDone; Context = $copy }
    [void]$ui.Jobs.Add($job)
    Set-TwBusy -Busy $true -Text $StatusText
}

function Set-TwBusy {
    [CmdletBinding(SupportsShouldProcess)]
    param([bool]$Busy, [string]$Text)
    $ui = $script:TwUi
    if (-not $PSCmdlet.ShouldProcess('window', 'Set busy state')) { return }
    $c = $ui.Controls
    $ui.Busy = $Busy
    foreach ($name in 'ApplyButton', 'DiscardButton', 'PresetBox', 'RestorePointButton', 'BackupsButton', 'LangButton', 'SelectAllButton') {
        if ($c[$name]) { $c[$name].IsEnabled = -not $Busy }
    }
    if ($c.TweakList) { $c.TweakList.IsEnabled = -not $Busy }
    if ($c.ToolPageContent) { $c.ToolPageContent.IsEnabled = -not $Busy }
    $c.Progress.Visibility = if ($Busy) { 'Visible' } else { 'Hidden' }
    if ($Text) { Set-TwStatus -Text $Text -Kind $(if ($Busy) { 'Busy' } else { 'Ok' }) }
    if (-not $Busy) { Update-TwPendingUi }
}

function Set-TwStatus {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Text, [ValidateSet('Ok', 'Busy', 'Warning', 'Error')][string]$Kind = 'Ok')
    $c = $script:TwUi.Controls
    if (-not $PSCmdlet.ShouldProcess('status bar', 'Update')) { return }
    $c.StatusText.Text = $Text
    $glyph = @{ Ok = [string][char]0xE930; Busy = [string][char]0xE895; Warning = [string][char]0xE7BA; Error = [string][char]0xEA39 }[$Kind]
    $brush = @{ Ok = 'Tw.Safe'; Busy = 'Tw.Accent'; Warning = 'Tw.Moderate'; Error = 'Tw.Advanced' }[$Kind]
    $c.StatusIcon.Text = $glyph
    $c.StatusIcon.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $brush)
}

function Add-TwLogLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Entry)
    $c = $script:TwUi.Controls
    $line = '{0}  {1,-7}  {2}' -f $Entry.Time.ToString('HH:mm:ss'), $Entry.Level.ToUpperInvariant(), $Entry.Message
    $c.LogBox.AppendText($line + [Environment]::NewLine)
    $c.LogBox.ScrollToEnd()
}

function Invoke-TwUiTimerTick {
    <#
    .SYNOPSIS
        UI timer: drains the background log queue, updates progress, completes jobs.
    #>
    [CmdletBinding()]
    param()
    $ui = $script:TwUi
    $entry = $null
    $last = $null
    while ($ui.Sync.Log.TryDequeue([ref]$entry)) {
        Add-TwLogLine -Entry $entry
        if ($entry.Level -ne 'Debug') { $last = $entry }
    }
    if ($last -and $ui.Busy) { $ui.Controls.StatusText.Text = $last.Message }
    $p = $ui.Sync.Progress
    if ($p -ge 0) { $ui.Controls.Progress.Value = $p }

    foreach ($job in @($ui.Jobs)) {
        if (-not $job.Handle.IsCompleted) { continue }
        $ui.Jobs.Remove($job)
        $output = $null
        $errorText = $null
        try {
            $output = $job.PowerShell.EndInvoke($job.Handle)
            if ($job.PowerShell.HadErrors -and $job.PowerShell.Streams.Error.Count -gt 0) {
                $errorText = ($job.PowerShell.Streams.Error | Select-Object -First 3 | ForEach-Object { $_.ToString() }) -join '; '
                Write-TwLog -Level Warning -Message "Background job reported: $errorText"
            }
        } catch {
            $errorText = $_.Exception.Message
            Write-TwLog -Level Error -Message "Background job failed: $errorText"
        } finally {
            $job.PowerShell.Dispose()
            $job.Runspace.Dispose()
        }
        while ($ui.Sync.Log.TryDequeue([ref]$entry)) { Add-TwLogLine -Entry $entry }
        Set-TwBusy -Busy $false
        $ui.Controls.Progress.Value = 0
        if ($job.OnDone) {
            try { & $job.OnDone $output $job.Context $errorText } catch {
                Write-TwLog -Level Error -Message "UI update failed: $($_.Exception.Message)"
                Set-TwStatus -Text $_.Exception.Message -Kind Error
            }
        }
    }
}

function Get-TwDetectJobCode {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return @'
$states = @{}
$all = @(Import-TwTweakCatalog)
$i = 0
foreach ($t in $all) {
    $i++
    $TwSync.Progress = [int](100 * $i / [math]::Max(1, $all.Count))
    $states[$t.id] = Get-TwTweakState -Tweak $t
}
$states
'@
}

function Update-TwStatesFromTable {
    [CmdletBinding()]
    param([hashtable]$States)
    $ui = $script:TwUi
    if (-not $States) { return }
    $ui.Suspend = $true
    try {
        foreach ($item in $ui.Items) {
            if ($States.ContainsKey($item.Id)) { Set-TwItemState -Item $item -State $States[$item.Id] }
        }
    } finally { $ui.Suspend = $false }
    Update-TwView
    Update-TwPendingUi
}

function Start-TwDetection {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess('tweaks', 'Detect state')) { return }
    Start-TwUiJob -Code (Get-TwDetectJobCode) -StatusText (Get-TwString 'ui.status.detecting') -OnDone {
        param($output, $jobCtx, $err)
        $null = $jobCtx
        $table = @($output | Where-Object { $_ -is [hashtable] }) | Select-Object -Last 1
        Update-TwStatesFromTable -States $table
        if ($err) { Set-TwStatus -Text $err -Kind Warning } else { Set-TwStatus -Text (Get-TwString 'ui.status.ready') -Kind Ok }
    }
}

function Update-TwView {
    <#
    .SYNOPSIS
        Recomputes which cards are visible (category, search, filters).
    #>
    [CmdletBinding()]
    param()
    $ui = $script:TwUi
    $c = $ui.Controls
    if (-not $c -or $ui.Suspend) { return }
    $search = ([string]$c.SearchBox.Text).Trim().ToLowerInvariant()
    $risk = 'all'
    if ($c.RiskFilter.SelectedItem) { $risk = $c.RiskFilter.SelectedItem.Tag }
    $onlyChanged = [bool]$c.OnlyChanged.IsChecked
    $hideUnsupported = [bool]$c.HideUnsupported.IsChecked
    $visible = 0
    foreach ($item in $ui.Items) {
        $show = $true
        if ($search) { $show = $item.SearchText.Contains($search) }
        else { $show = ($item.Category -eq $ui.Category) }
        if ($show -and $risk -ne 'all' -and $item.Risk -ne $risk) { $show = $false }
        if ($show -and $onlyChanged -and -not $item.IsPending) { $show = $false }
        if ($show -and $hideUnsupported -and $item.State -eq 'Unsupported' -and -not $search) { $show = $false }
        $item.IsVisible = $show
        if ($show) { $visible++ }
    }
    $c.EmptyText.Visibility = if ($visible -eq 0) { 'Visible' } else { 'Collapsed' }
    $c.CountText.Text = Get-TwString 'ui.count' $visible
    if ($search) {
        $c.PageTitle.Text = Get-TwString 'ui.searchTitle' $c.SearchBox.Text.Trim()
        $c.PageSubtitle.Text = Get-TwString 'ui.searchSubtitle'
        if ($c.ToolPage.Visibility -eq 'Visible') { Show-TwTweakPanel }
    }
}

function Update-TwPendingUi {
    [CmdletBinding()]
    param()
    $ui = $script:TwUi
    $c = $ui.Controls
    if (-not $c -or $ui.Suspend) { return }
    $pending = @($ui.Items | Where-Object { $_.IsPending })
    $c.ApplyText.Text = if ($pending.Count -gt 0) { Get-TwString 'ui.apply.count' $pending.Count } else { Get-TwString 'ui.apply' }
    $c.ApplyButton.IsEnabled = ($pending.Count -gt 0) -and -not $ui.ReadOnly -and -not $ui.Busy
    $c.DiscardButton.IsEnabled = ($pending.Count -gt 0) -and -not $ui.Busy
    foreach ($nav in $ui.Nav) {
        if ($nav.Page -ne 'tweaks') { continue }
        $catItems = @($ui.Items | Where-Object { $_.Category -eq $nav.Id })
        $nav.PendingCount = @($catItems | Where-Object { $_.IsPending }).Count
        $applied = @($catItems | Where-Object { $_.IsApplied }).Count
        $nav.CountText = '{0}/{1}' -f $applied, $catItems.Count
    }
}

function Show-TwTweakPanel {
    [CmdletBinding()]
    param()
    $c = $script:TwUi.Controls
    $c.TweaksPage.Visibility = 'Visible'
    $c.ToolPage.Visibility = 'Collapsed'
    $c.FilterBar.Visibility = 'Visible'
}

function Show-TwPage {
    <#
    .SYNOPSIS
        Switches the content area to a category.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Nav)
    $ui = $script:TwUi
    $c = $ui.Controls
    $ui.Category = $Nav.Id
    $c.PageTitle.Text = $Nav.Name
    $c.PageSubtitle.Text = Get-TwString "ui.category.desc.$($Nav.Id)"
    if ($Nav.Page -eq 'tweaks') {
        if ($c.SearchBox.Text) { $ui.Suspend = $true; $c.SearchBox.Text = ''; $ui.Suspend = $false }
        Show-TwTweakPanel
        $c.DnsPanel.Visibility = 'Collapsed'
        if ($Nav.Id -eq 'network' -and (Get-Command -Name Initialize-TwDnsPanel -ErrorAction SilentlyContinue)) { Initialize-TwDnsPanel }
        Update-TwView
        $c.TweaksPage.ScrollToTop()
    } else {
        $c.TweaksPage.Visibility = 'Collapsed'
        $c.FilterBar.Visibility = 'Collapsed'
        $c.ToolPage.Visibility = 'Visible'
        $c.ToolPageContent.Children.Clear()
        $builder = 'Initialize-Tw{0}Page' -f ((Get-Culture).TextInfo.ToTitleCase($Nav.Page))
        if (Get-Command -Name $builder -ErrorAction SilentlyContinue) { & $builder -Panel $c.ToolPageContent }
        else {
            $tb = New-Object Windows.Controls.TextBlock
            $tb.Text = Get-TwString 'ui.page.soon'
            $tb.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Tw.Muted')
            [void]$c.ToolPageContent.Children.Add($tb)
        }
        $c.ToolPage.ScrollToTop()
    }
}

# --- small element factories used by dialogs and tool pages ------------------------

function New-TwText {
    [CmdletBinding()]
    param(
        [string]$Text,
        [string]$Brush = 'Tw.Text',
        [double]$Size = 13,
        [switch]$Bold,
        [string]$Margin = '0,0,0,6',
        [switch]$Icon
    )
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.TextWrapping = 'Wrap'
    $tb.FontSize = $Size
    $tb.Margin = $Margin
    if ($Bold) { $tb.FontWeight = 'SemiBold' }
    if ($Icon) { $tb.SetResourceReference([Windows.Controls.TextBlock]::FontFamilyProperty, 'Tw.IconFont') }
    $tb.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $Brush)
    return $tb
}

function New-TwButton {
    [CmdletBinding()]
    param(
        [string]$Text,
        [scriptblock]$OnClick,
        [ValidateSet('Tw.Button', 'Tw.AccentButton', 'Tw.DangerButton', 'Tw.IconButton')][string]$Style = 'Tw.Button',
        [string]$Margin = '8,0,0,0',
        [string]$ToolTip
    )
    $b = New-Object Windows.Controls.Button
    $b.Content = $Text
    $b.Margin = $Margin
    $b.SetResourceReference([Windows.FrameworkElement]::StyleProperty, $Style)
    if ($ToolTip) { $b.ToolTip = $ToolTip }
    if ($OnClick) { $b.Add_Click($OnClick) }
    return $b
}

function New-TwCheckBox {
    [CmdletBinding()]
    param([string]$Text, [bool]$Checked, [string]$Margin = '0,4,0,4', [switch]$Toggle)
    $cb = New-Object Windows.Controls.CheckBox
    $cb.Content = $Text
    $cb.IsChecked = $Checked
    $cb.Margin = $Margin
    $style = if ($Toggle) { 'Tw.Toggle' } else { 'Tw.Check' }
    $cb.SetResourceReference([Windows.FrameworkElement]::StyleProperty, $style)
    return $cb
}

function New-TwCard {
    [CmdletBinding()]
    param([string]$Margin = '0,0,0,10')
    $b = New-Object Windows.Controls.Border
    $b.SetResourceReference([Windows.FrameworkElement]::StyleProperty, 'Tw.Card')
    $b.Margin = $Margin
    return $b
}

function Show-TwDialog {
    <#
    .SYNOPSIS
        Shows the in-window modal overlay.
    .PARAMETER Buttons
        Hashtables: @{ Text; Style; Action (scriptblock, return $false to keep open) }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [object[]]$Body = @(),
        [object[]]$Buttons = @()
    )
    $c = $script:TwUi.Controls
    $c.DialogTitle.Text = $Title
    $c.DialogBody.Children.Clear()
    foreach ($b in $Body) {
        if ($b -is [string]) { [void]$c.DialogBody.Children.Add((New-TwText -Text $b -Brush 'Tw.SubText')) }
        elseif ($b) { [void]$c.DialogBody.Children.Add($b) }
    }
    $c.DialogButtons.Children.Clear()
    if ($Buttons.Count -eq 0) { $Buttons = @(@{ Text = (Get-TwString 'ui.dlg.ok'); Style = 'Tw.AccentButton' }) }
    foreach ($spec in $Buttons) {
        $btn = New-TwButton -Text $spec.Text -Style $(if ($spec.Style) { $spec.Style } else { 'Tw.Button' })
        $btn.Tag = $spec.Action
        $btn.Add_Click({
                param($sender, $e)
                $null = $e
                $keepOpen = $false
                if ($sender.Tag -is [scriptblock]) { $keepOpen = ((& $sender.Tag) -eq $false) }
                if (-not $keepOpen) { Hide-TwDialog }
            })
        [void]$c.DialogButtons.Children.Add($btn)
    }
    $c.Overlay.Visibility = 'Visible'
}

function Hide-TwDialog {
    [CmdletBinding()]
    param()
    $script:TwUi.Controls.Overlay.Visibility = 'Collapsed'
}

# --- apply flow ------------------------------------------------------------------

function Show-TwApplyDialog {
    [CmdletBinding()]
    param()
    $ui = $script:TwUi
    $byId = @{}
    foreach ($t in Import-TwTweakCatalog) { $byId[$t.id] = $t }
    $toApply = @($ui.Items | Where-Object { $_.IsPending -and $_.IsOn })
    $toUndo = @($ui.Items | Where-Object { $_.IsPending -and -not $_.IsOn })
    if (($toApply.Count + $toUndo.Count) -eq 0) { return }

    $body = New-Object System.Collections.Generic.List[object]
    foreach ($group in @(@{ Key = 'ui.dlg.apply.toApply'; Items = $toApply }, @{ Key = 'ui.dlg.apply.toUndo'; Items = $toUndo })) {
        if ($group.Items.Count -eq 0) { continue }
        $body.Add((New-TwText -Text (Get-TwString $group.Key $group.Items.Count) -Bold -Margin '0,4,0,6'))
        foreach ($i in $group.Items) {
            $brush = switch ($i.Risk) { 'advanced' { 'Tw.Advanced' } 'moderate' { 'Tw.Moderate' } default { 'Tw.SubText' } }
            $body.Add((New-TwText -Text ([string][char]0x2022 + ' ' + $i.Name + '  (' + $i.RiskText + ')') -Brush $brush -Margin '8,0,0,3'))
        }
    }
    $advanced = @($toApply | Where-Object { $_.Risk -eq 'advanced' })
    if ($advanced.Count -gt 0) {
        $body.Add((New-TwText -Text (Get-TwString 'ui.dlg.apply.advanced') -Brush 'Tw.Advanced' -Bold -Margin '0,12,0,4'))
        foreach ($i in $advanced) { if ($i.Warning) { $body.Add((New-TwText -Text ($i.Name + ': ' + $i.Warning) -Brush 'Tw.Advanced' -Margin '8,0,0,4')) } }
    }
    $all = @($toApply) + @($toUndo)
    $needs = @()
    if (@($all | Where-Object { $byId[$_.Id].requiresReboot }).Count) { $needs += Get-TwString 'ui.dlg.apply.reboot' }
    if (@($all | Where-Object { $byId[$_.Id].requiresSignOut }).Count) { $needs += Get-TwString 'ui.dlg.apply.signout' }
    if (@($all | Where-Object { $byId[$_.Id].requiresExplorerRestart }).Count) { $needs += Get-TwString 'ui.dlg.apply.explorer' }
    foreach ($n in $needs) { $body.Add((New-TwText -Text $n -Brush 'Tw.Moderate' -Margin '0,10,0,0')) }

    $ctx = Get-TwContext
    $rp = New-TwCheckBox -Text (Get-TwString 'ui.dlg.apply.restorePoint') -Checked (-not $ctx.RestorePointDone) -Margin '0,14,0,0'
    if ($ctx.RestorePointDone) { $rp.IsEnabled = $false; $rp.Content = Get-TwString 'ui.dlg.apply.rpDone' }
    $body.Add($rp)
    $body.Add((New-TwText -Text (Get-TwString 'ui.dlg.apply.backupNote') -Brush 'Tw.Muted' -Size 12 -Margin '0,10,0,0'))

    $applyIds = @($toApply | ForEach-Object { $_.Id })
    $undoIds = @($toUndo | ForEach-Object { $_.Id })
    $ui.PendingRequest = @{ Apply = $applyIds; Undo = $undoIds; RestorePoint = $rp }
    Show-TwDialog -Title (Get-TwString 'ui.dlg.apply.title' $all.Count) -Body $body.ToArray() -Buttons @(
        @{ Text = (Get-TwString 'ui.dlg.applyNow'); Style = 'Tw.AccentButton'; Action = { Start-TwApplyJob } },
        @{ Text = (Get-TwString 'ui.dlg.cancel') }
    )
}

function Start-TwApplyJob {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $ui = $script:TwUi
    $req = $ui.PendingRequest
    if (-not $req -or -not $PSCmdlet.ShouldProcess('tweaks', 'Apply pending changes')) { return }
    $code = @'
$progress = { param($i, $n, $t, $a) $TwSync.Progress = [int](100 * ($i - 1) / [math]::Max(1, $n)) }
$report = Invoke-TwTweakBatch -Apply $TwJobArgs.Apply -Undo $TwJobArgs.Undo -NoRestorePoint:(-not $TwJobArgs.RestorePoint) -OnProgress $progress
$states = @{}
foreach ($t in @(Import-TwTweakCatalog)) { $states[$t.id] = Get-TwTweakState -Tweak $t }
@{ Report = $report; States = $states }
'@
    $jobArgs = @{ Apply = $req.Apply; Undo = $req.Undo; RestorePoint = [bool]$req.RestorePoint.IsChecked }
    Start-TwUiJob -Code $code -Arguments $jobArgs -StatusText (Get-TwString 'ui.status.applying') -OnDone {
        param($output, $jobCtx, $err)
        $result = @($output | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('Report') }) | Select-Object -Last 1
        if ($jobCtx.RestorePointDone) { (Get-TwContext).RestorePointDone = $true }
        if (-not $result) {
            Set-TwStatus -Text (Get-TwString 'ui.status.failed' $err) -Kind Error
            Show-TwDialog -Title (Get-TwString 'ui.dlg.result.title') -Body @((Get-TwString 'ui.status.failed' $err))
            return
        }
        Update-TwStatesFromTable -States $result.States
        Show-TwResultDialog -Report $result.Report
    }
}

function Show-TwResultDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Report)
    $results = @($Report.Results)
    $ok = @($results | Where-Object { $_.Status -in 'Success', 'NoChange' }).Count
    $failed = @($results | Where-Object { $_.Status -eq 'Failed' })
    $skipped = @($results | Where-Object { $_.Status -eq 'Skipped' }).Count
    $body = New-Object System.Collections.Generic.List[object]
    $body.Add((New-TwText -Text (Get-TwString 'ui.dlg.result.summary' $ok, $skipped, $failed.Count) -Bold))
    if ($Report.RestorePoint -and -not $Report.RestorePoint.Success) {
        $body.Add((New-TwText -Text (Get-TwString 'cli.restorePointFailed' $Report.RestorePoint.Message) -Brush 'Tw.Moderate'))
    }
    foreach ($f in $failed) { $body.Add((New-TwText -Text ($f.Name + ': ' + $f.Message) -Brush 'Tw.Advanced' -Margin '8,0,0,4')) }
    if ($Report.ExplorerRestarted) { $body.Add((New-TwText -Text (Get-TwString 'cli.explorerRestarted') -Brush 'Tw.SubText')) }
    if (@($Report.SignOutRequired).Count) { $body.Add((New-TwText -Text (Get-TwString 'cli.signOutNeeded' (@($Report.SignOutRequired) -join ', ')) -Brush 'Tw.Moderate')) }
    if (@($Report.RebootRequired).Count) { $body.Add((New-TwText -Text (Get-TwString 'cli.rebootNeeded' (@($Report.RebootRequired) -join ', ')) -Brush 'Tw.Moderate')) }
    $kind = if ($failed.Count) { 'Warning' } else { 'Ok' }
    Set-TwStatus -Text (Get-TwString 'ui.dlg.result.summary' $ok, $skipped, $failed.Count) -Kind $kind
    Show-TwDialog -Title (Get-TwString 'ui.dlg.result.title') -Body $body.ToArray()
}

# --- restore points and backups ---------------------------------------------------

function Start-TwRestorePointJob {
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$EnableProtection)
    if (-not $PSCmdlet.ShouldProcess('system', 'Create restore point')) { return }
    $code = @'
if ($TwJobArgs.Enable) { Enable-TwSystemRestore -Confirm:$false }
if (-not (Test-TwSystemRestoreEnabled)) { @{ Disabled = $true } } else {
    $r = New-TwRestorePoint -Description ('Tweaker ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
    @{ Disabled = $false; Result = $r }
}
'@
    Start-TwUiJob -Code $code -Arguments @{ Enable = [bool]$EnableProtection } -StatusText (Get-TwString 'ui.rp.creating') -OnDone {
        param($output, $jobCtx, $err)
        $null = $jobCtx
        $res = @($output | Where-Object { $_ -is [hashtable] }) | Select-Object -Last 1
        if (-not $res) { Set-TwStatus -Text (Get-TwString 'ui.rp.failed' $err) -Kind Error; return }
        if ($res.Disabled) {
            Show-TwDialog -Title (Get-TwString 'ui.rp.disabled.title') -Body @((Get-TwString 'ui.rp.disabled.text')) -Buttons @(
                @{ Text = (Get-TwString 'ui.rp.enable'); Style = 'Tw.AccentButton'; Action = { Start-TwRestorePointJob -EnableProtection } },
                @{ Text = (Get-TwString 'ui.dlg.cancel') })
            return
        }
        if ($res.Result.Success) {
            (Get-TwContext).RestorePointDone = $true
            Set-TwStatus -Text (Get-TwString 'ui.rp.ok') -Kind Ok
        } else {
            Set-TwStatus -Text (Get-TwString 'ui.rp.failed' $res.Result.Message) -Kind Warning
            Show-TwDialog -Title (Get-TwString 'ui.restorePoint') -Body @((Get-TwString 'ui.rp.failed' $res.Result.Message))
        }
    }
}

function Start-TwRestoreJob {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$SessionId, [switch]$Full)
    if (-not $PSCmdlet.ShouldProcess('backup', 'Restore')) { return }
    $code = @'
if ($TwJobArgs.Full) { $r = Restore-TwFullBackup } else { $r = Restore-TwBackupSession -Id $TwJobArgs.Id }
$states = @{}
foreach ($t in @(Import-TwTweakCatalog)) { $states[$t.id] = Get-TwTweakState -Tweak $t }
@{ Results = @($r); States = $states }
'@
    Start-TwUiJob -Code $code -Arguments @{ Id = $SessionId; Full = [bool]$Full } -StatusText (Get-TwString 'ui.status.restoring') -OnDone {
        param($output, $jobCtx, $err)
        $null = $jobCtx
        $res = @($output | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('States') }) | Select-Object -Last 1
        if (-not $res) { Set-TwStatus -Text (Get-TwString 'ui.status.failed' $err) -Kind Error; return }
        Update-TwStatesFromTable -States $res.States
        $failed = @($res.Results | Where-Object { $_.Status -eq 'Failed' }).Count
        $text = Get-TwString 'cli.restoreSummary' @($res.Results).Count, $failed
        Set-TwStatus -Text $text -Kind $(if ($failed) { 'Warning' } else { 'Ok' })
        Show-TwDialog -Title (Get-TwString 'ui.backups.title') -Body @($text, (Get-TwString 'ui.backups.restartHint'))
    }
}

function Show-TwBackupsDialog {
    [CmdletBinding()]
    param()
    $ui = $script:TwUi
    $sessions = @(Get-TwBackupSession)
    $body = New-Object System.Collections.Generic.List[object]
    if ($sessions.Count -eq 0) { $body.Add((New-TwText -Text (Get-TwString 'ui.backups.empty') -Brush 'Tw.SubText')) }
    foreach ($s in $sessions | Select-Object -First 30) {
        $row = New-Object Windows.Controls.DockPanel
        $row.Margin = '0,0,0,8'
        $created = $s.id
        try { $created = ([datetime]$s.created).ToString('yyyy-MM-dd HH:mm') } catch { Write-Verbose 'bad date' }
        $tweaks = @($s.entries | ForEach-Object { $_.tweakId } | Select-Object -Unique)
        $btnRestore = New-TwButton -Text (Get-TwString 'ui.backups.restore') -Margin '8,0,0,0'
        $btnRestore.Tag = $s.id
        $btnRestore.IsEnabled = -not $ui.ReadOnly
        $btnRestore.Add_Click({ param($sender, $e) $null = $e; Hide-TwDialog; Start-TwRestoreJob -SessionId $sender.Tag })
        $btnDelete = New-TwButton -Text (Get-TwString 'ui.backups.delete') -Style 'Tw.DangerButton' -Margin '8,0,0,0'
        $btnDelete.Tag = $s.id
        $btnDelete.IsEnabled = -not $ui.ReadOnly
        $btnDelete.Add_Click({ param($sender, $e) $null = $e; Remove-TwBackupSession -Id $sender.Tag -Confirm:$false; Show-TwBackupsDialog })
        [Windows.Controls.DockPanel]::SetDock($btnDelete, 'Right')
        [Windows.Controls.DockPanel]::SetDock($btnRestore, 'Right')
        [void]$row.Children.Add($btnDelete)
        [void]$row.Children.Add($btnRestore)
        $info = New-Object Windows.Controls.StackPanel
        [void]$info.Children.Add((New-TwText -Text (Get-TwString 'ui.backups.session' $created, @($s.entries).Count) -Bold -Margin '0'))
        [void]$info.Children.Add((New-TwText -Text (($tweaks | Select-Object -First 6) -join ', ') -Brush 'Tw.Muted' -Size 11 -Margin '0,2,0,0'))
        [void]$row.Children.Add($info)
        $body.Add($row)
    }
    $body.Add((New-TwText -Text (Get-TwString 'ui.backups.folder' (Get-TwContext).BackupDir) -Brush 'Tw.Muted' -Size 11 -Margin '0,10,0,0'))
    $buttons = @()
    if ($sessions.Count -gt 0 -and -not $ui.ReadOnly) {
        $buttons += @{ Text = (Get-TwString 'ui.backups.full'); Style = 'Tw.DangerButton'; Action = {
                Show-TwDialog -Title (Get-TwString 'ui.backups.full') -Body @((Get-TwString 'ui.backups.fullConfirm')) -Buttons @(
                    @{ Text = (Get-TwString 'ui.backups.full'); Style = 'Tw.DangerButton'; Action = { Start-TwRestoreJob -Full } },
                    @{ Text = (Get-TwString 'ui.dlg.cancel') })
                return $false
            }
        }
    }
    $buttons += @{ Text = (Get-TwString 'ui.dlg.close'); Style = 'Tw.AccentButton' }
    Show-TwDialog -Title (Get-TwString 'ui.backups.title') -Body $body.ToArray() -Buttons $buttons
}

# --- window ---------------------------------------------------------------------

function Initialize-TwMainWindow {
    <#
    .SYNOPSIS
        Creates the window, models and event handlers (does not show it).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Dark', 'Light', 'System')][string]$Theme = 'Dark',
        [string]$Category = 'privacy'
    )
    Initialize-TwWpf
    $ctx = Get-TwContext
    $parts = New-TwMainWindowObject -Theme $Theme
    $c = $parts.Controls
    $script:TwUi = @{
        Window          = $parts.Window
        Controls        = $c
        Items           = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
        Nav             = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
        Jobs            = New-Object System.Collections.ArrayList
        Sync            = [hashtable]::Synchronized(@{ Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'; Progress = -1 })
        FunctionEntries = @(Get-TwFunctionEntry)
        ReadOnly        = [bool]$ctx.ReadOnly
        Category        = $Category
        Busy            = $false
        Suspend         = $false
        Theme           = $Theme
        PendingRequest  = $null
    }
    $ui = $script:TwUi
    $ctx['Theme'] = $Theme
    $ctx.LogSink = { param($e) if ($script:TwUi -and $script:TwUi.Controls) { Add-TwLogLine -Entry $e } }

    $os = Get-TwOsInfo
    $c.OsText.Text = Get-TwString 'ui.osText' $os.ProductName, $os.DisplayVersion, $os.Build, $os.Ubr
    $c.VersionText.Text = Get-TwString 'ui.version' $ctx.Version

    $banner = @()
    if ($ui.ReadOnly) { $banner += Get-TwString 'ui.readOnlyBanner' }
    if (-not $os.Supported) { $banner += Get-TwString 'cli.osUnsupported' $os.Build }
    if ($ctx.TargetUserSid) { $banner += Get-TwString 'cli.hkcuRedirect' }
    if ($banner.Count -gt 0) { $c.BannerText.Text = $banner -join '  '; $c.Banner.Visibility = 'Visible' }

    foreach ($cat in @((Get-TwJsonResource 'config/categories.json').categories | Sort-Object { [int]$_.order })) {
        $nav = New-Object TweakerUI.NavItem
        $nav.Id = $cat.id
        $nav.Name = Get-TwString "category.$($cat.id)"
        $nav.Icon = [string][char][Convert]::ToInt32($cat.icon, 16)
        $nav.Page = $cat.page
        $ui.Nav.Add($nav)
    }
    $c.NavList.ItemsSource = $ui.Nav

    foreach ($t in Import-TwTweakCatalog) {
        $item = New-TwTweakItem -Tweak $t -ReadOnly $ui.ReadOnly
        $item.add_PropertyChanged({
                param($sender, $e)
                $null = $sender
                if ($e.PropertyName -eq 'IsPending') {
                    Update-TwPendingUi
                    if ($script:TwUi.Controls.OnlyChanged.IsChecked) { Update-TwView }
                }
            })
        $ui.Items.Add($item)
    }
    $c.TweakList.ItemsSource = $ui.Items

    foreach ($r in 'all', 'safe', 'moderate', 'advanced') {
        $ci = New-Object Windows.Controls.ComboBoxItem
        $ci.Content = if ($r -eq 'all') { Get-TwString 'ui.risk.all' } else { Get-TwString "risk.$r" }
        $ci.Tag = $r
        [void]$c.RiskFilter.Items.Add($ci)
    }
    $c.RiskFilter.SelectedIndex = 0

    $placeholder = New-Object Windows.Controls.ComboBoxItem
    $placeholder.Content = Get-TwString 'ui.preset.placeholder'
    $placeholder.Tag = ''
    [void]$c.PresetBox.Items.Add($placeholder)
    foreach ($p in Get-TwPreset) {
        $ci = New-Object Windows.Controls.ComboBoxItem
        $ci.Content = Get-TwLocalizedText $p.name
        $ci.ToolTip = Get-TwLocalizedText $p.description
        $ci.Tag = $p.id
        [void]$c.PresetBox.Items.Add($ci)
    }
    $c.PresetBox.SelectedIndex = 0
    if ($ui.ReadOnly) { $c.PresetBox.IsEnabled = $false; $c.RestorePointButton.IsEnabled = $false; $c.SelectAllButton.IsEnabled = $false }

    # --- events ---
    $c.NavList.Add_SelectionChanged({ if ($script:TwUi.Controls.NavList.SelectedItem) { Show-TwPage -Nav $script:TwUi.Controls.NavList.SelectedItem } })
    $c.SearchBox.Add_TextChanged({ if (-not $script:TwUi.Suspend) { if (-not $script:TwUi.Controls.SearchBox.Text) { $n = $script:TwUi.Controls.NavList.SelectedItem; if ($n) { Show-TwPage -Nav $n } } else { Update-TwView } } })
    $c.RiskFilter.Add_SelectionChanged({ Update-TwView })
    $c.OnlyChanged.Add_Click({ Update-TwView })
    $c.HideUnsupported.Add_Click({ Update-TwView })
    $c.ApplyButton.Add_Click({ Show-TwApplyDialog })
    $c.DiscardButton.Add_Click({
            foreach ($i in $script:TwUi.Items) { $i.IsOn = $i.IsApplied }
            $script:TwUi.Controls.PresetBox.SelectedIndex = 0
            Update-TwView
        })
    $c.SelectAllButton.Add_Click({ foreach ($i in $script:TwUi.Items) { if ($i.IsVisible -and $i.CanToggle) { $i.IsOn = $true } } })
    $c.PresetBox.Add_SelectionChanged({
            $sel = $script:TwUi.Controls.PresetBox.SelectedItem
            if (-not $sel -or -not $sel.Tag) { return }
            $ids = @(Resolve-TwPresetTweakId -Name $sel.Tag)
            $marked = 0
            foreach ($i in $script:TwUi.Items) {
                if ($ids -contains $i.Id -and $i.CanToggle -and -not $i.IsOn) { $i.IsOn = $true; $marked++ }
            }
            Set-TwStatus -Text (Get-TwString 'ui.preset.marked' $marked, $sel.Content) -Kind Ok
        })
    $c.RestorePointButton.Add_Click({ Start-TwRestorePointJob })
    $c.BackupsButton.Add_Click({ Show-TwBackupsDialog })
    $c.ThemeButton.Add_Click({
            $next = @{ Dark = 'Light'; Light = 'System'; System = 'Dark' }[$script:TwUi.Theme]
            $script:TwUi.Theme = $next
            Set-TwTheme -Window $script:TwUi.Window -Theme $next
            Set-TwStatus -Text (Get-TwString "ui.theme.$next") -Kind Ok
            if (Get-Command -Name Save-TwUserSetting -ErrorAction SilentlyContinue) { Save-TwUserSetting -Name Theme -Value $next }
        })
    $c.LangButton.Add_Click({
            $ctx2 = Get-TwContext
            $ctx2['RestartWithLanguage'] = if ($ctx2.Language -eq 'ru') { 'en' } else { 'ru' }
            if (Get-Command -Name Save-TwUserSetting -ErrorAction SilentlyContinue) { Save-TwUserSetting -Name Language -Value $ctx2['RestartWithLanguage'] }
            $script:TwUi.Window.Close()
        })
    $c.LogToggle.Add_Click({
            $p = $script:TwUi.Controls.LogPanel
            $p.Visibility = if ($p.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }
        })
    $parts.Window.Add_SourceInitialized({ Set-TwTheme -Window $script:TwUi.Window -Theme $script:TwUi.Theme })
    $parts.Window.Add_KeyDown({
            param($sender, $e)
            $null = $sender
            if ($e.Key -eq 'Escape' -and $script:TwUi.Controls.Overlay.Visibility -eq 'Visible') { Hide-TwDialog }
            if ($e.Key -eq 'F' -and ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)) { [void]$script:TwUi.Controls.SearchBox.Focus() }
        })
    $parts.Window.Add_Closing({
            param($sender, $e)
            $null = $sender
            if ($script:TwUi.Busy) { $e.Cancel = $true; Set-TwStatus -Text (Get-TwString 'ui.busy') -Kind Warning }
        })

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $timer.Add_Tick({ Invoke-TwUiTimerTick })
    $ui.Timer = $timer

    $start = @($ui.Nav | Where-Object { $_.Id -eq $Category }) | Select-Object -First 1
    if (-not $start) { $start = $ui.Nav[0] }
    $c.NavList.SelectedItem = $start
    Set-TwStatus -Text (Get-TwString 'ui.status.ready') -Kind Ok
    Update-TwPendingUi
    return $ui
}

function Save-TwWindowImage {
    <#
    .SYNOPSIS
        Renders the window content to a PNG without showing it (docs screenshots, tests).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path, [int]$Width = 1200, [int]$Height = 800)
    $ui = $script:TwUi
    $root = $ui.Window.Content
    $root.Measure((New-Object Windows.Size($Width, $Height)))
    $root.Arrange((New-Object Windows.Rect(0, 0, $Width, $Height)))
    $root.UpdateLayout()
    $null = $ui.Window.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::Background)
    $root.UpdateLayout()
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap($Width, $Height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bg = New-Object Windows.Shapes.Rectangle
    $bg.Width = $Width; $bg.Height = $Height
    $bg.Fill = $ui.Window.Background
    $bg.Measure((New-Object Windows.Size($Width, $Height)))
    $bg.Arrange((New-Object Windows.Rect(0, 0, $Width, $Height)))
    $bmp.Render($bg)
    $bmp.Render($root)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    if ($PSCmdlet.ShouldProcess($Path, 'Write PNG')) {
        $Path = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
        $fs = [System.IO.File]::Create($Path)
        try { $enc.Save($fs) } finally { $fs.Dispose() }
    }
}

function Show-TwMainWindow {
    <#
    .SYNOPSIS
        Opens the GUI. Returns the exit code.
    .PARAMETER RenderPath
        Render to a PNG instead of showing the window (state detected synchronously).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string]$RenderPath,
        [ValidateSet('Dark', 'Light', 'System')][string]$Theme,
        [string]$Category = 'privacy'
    )
    if (-not $Theme) {
        $Theme = 'Dark'
        if (Get-Command -Name Get-TwUserSetting -ErrorAction SilentlyContinue) {
            $saved = Get-TwUserSetting -Name Theme
            if ($saved -in 'Dark', 'Light', 'System') { $Theme = $saved }
        }
    }
    while ($true) {
        $ui = Initialize-TwMainWindow -Theme $Theme -Category $Category
        if ($RenderPath) {
            $states = @{}
            foreach ($t in Import-TwTweakCatalog) { $states[$t.id] = Get-TwTweakState -Tweak $t }
            Update-TwStatesFromTable -States $states
            Set-TwTheme -Window $ui.Window -Theme $Theme
            Save-TwWindowImage -Path $RenderPath
            $ui.Window.Close()
            return 0
        }
        $ui.Timer.Start()
        Start-TwDetection
        $null = $ui.Window.ShowDialog()
        $ui.Timer.Stop()
        $ctx = Get-TwContext
        $next = Get-TwObjectProperty $ctx 'RestartWithLanguage'
        if (-not $next) { break }
        $ctx['RestartWithLanguage'] = $null
        Import-TwLanguage -Language $next
        $Theme = $ui.Theme
        $Category = $ui.Category
    }
    return 0
}
