param([Parameter(Mandatory)][string]$Executable)
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$document = Join-Path $repositoryRoot 'Examples/Windows.md'
$executablePath = (Resolve-Path $Executable).Path
# Avoid redirecting into or closing a user's existing instance.
if (Get-Process -Name SSMV -ErrorAction SilentlyContinue) {
    throw 'Close existing SSMV instances before running the isolated smoke test.'
}
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('ssmv-smoke-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $testDirectory > $null
$previousDataDirectory = $env:SSMV_DATA_DIR
$env:SSMV_DATA_DIR = Join-Path $testDirectory 'state'
$secondDocument = Join-Path $testDirectory 'Warm activation 한글.md'
[IO.File]::WriteAllText($secondDocument, "# Warm activation`n`nThe original process opens this second document.", [Text.UTF8Encoding]::new($false))
$startedProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()
$evidence = Join-Path $repositoryRoot 'dist/windows/smoke'
New-Item -ItemType Directory -Force $evidence > $null

function Write-CrashEvidence([Diagnostics.Process]$Target) {
    $Target.Refresh()
    if ($Target.HasExited) {
        Write-Host ("SSMV process {0} exited: decimal={1}; hex=0x{2:X8}" -f $Target.Id, $Target.ExitCode, $Target.ExitCode)
    }
    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 2; StartTime = (Get-Date).AddMinutes(-5) } -MaxEvents 30 -ErrorAction Stop |
            Where-Object { $_.Message -match '(?i)ssmv(?:\.exe)?' } | Select-Object -First 3
        foreach ($event in $events) { Write-Host ("Crash event {0} / {1}: {2}" -f $event.ProviderName, $event.Id, $event.Message) }
        if (!$events) { Write-Host 'No matching SSMV Application error events are available yet.' }
    } catch { Write-Host "Application crash events unavailable: $_" }

}

function Wait-DocumentWindow([Diagnostics.Process]$Target, [string]$Title) {
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $Target.Refresh()
        if ($Target.HasExited) { throw "SSMV exited before loading '$Title', code $($Target.ExitCode)." }
        if ($Target.MainWindowTitle -eq $Title) { return }
        if ($Target.MainWindowTitle -eq 'SSMV could not start') { throw 'SSMV reported a native startup error.' }
    }
    throw "The document window did not become ready. Expected: '$Title'; actual: '$($Target.MainWindowTitle)'."
}

function Close-DocumentWindow([Diagnostics.Process]$Target) {
    $Target.Refresh()
    if ($Target.HasExited) { throw 'SSMV exited before the orderly-close check.' }
    if (!$Target.CloseMainWindow()) { throw 'Could not close the document window normally.' }
    if (!$Target.WaitForExit(10000)) { throw 'SSMV did not exit after its window closed.' }
    if ($Target.ExitCode -ne 0) { throw "SSMV exited with code $($Target.ExitCode)." }
}

# UI Automation patterns exercise native controls without sending keyboard input.
function Wait-AutomationElement([int]$ProcessId, [string]$Value, [switch]$AutomationId) {
    $property = if ($AutomationId) { [Windows.Automation.AutomationElement]::AutomationIdProperty } else { [Windows.Automation.AutomationElement]::NameProperty }
    $identity = [Windows.Automation.PropertyCondition]::new($property, $Value)
    $condition = [Windows.Automation.AndCondition]::new(
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcessId), $identity)
    $deadline = (Get-Date).AddSeconds(15)
    do {
        $target = $startedProcesses | Where-Object { $_.Id -eq $ProcessId } | Select-Object -First 1
        if ($null -ne $target) {
            $target.Refresh()
            if ($target.HasExited) {
                Write-CrashEvidence $target
                throw "SSMV exited while waiting for '$Value'; exit code $($target.ExitCode)."
            }
        }
        $candidates = [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)
        foreach ($element in $candidates) {
            if ($element.Current.IsEnabled -and !$element.Current.IsOffscreen) { return $element }
        }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    if ($Value -eq 'menu.appearance' -or $Value -eq 'theme.dark') {
        try {
            $processCondition = [Windows.Automation.PropertyCondition]::new(
                [Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcessId)
            $elements = [Windows.Automation.AutomationElement]::RootElement.FindAll(
                [Windows.Automation.TreeScope]::Descendants, $processCondition)
            Write-Host "Menu diagnostics for '$Value' (up to 100 native controls):"
            $elements | Select-Object -First 100 | ForEach-Object {
                $current = $_.Current
                Write-Host ("  {0} id='{1}' name='{2}' offscreen={3} enabled={4} rect={5}" -f
                    $current.ControlType.ProgrammaticName, $current.AutomationId, $current.Name,
                    $current.IsOffscreen, $current.IsEnabled, $current.BoundingRectangle)
            }
            # This diagnostic is reached before the private warm-activation fixture.
            $target = Get-Process -Id $ProcessId
            if ($target.MainWindowTitle -eq 'Windows.md — SSMV') {
                Save-WindowEvidence $target 'window-menu-failure.png' -IncludePopup
            }
        } catch { Write-Host "Menu diagnostics failed: $_" }
    }
    throw "Native UI control was not available: '$Value' (process $ProcessId)."
}

function Invoke-AutomationElement($Element) {
    $pattern = $Element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
    $pattern.Invoke()
}

function Open-AutomationMenu([int]$ProcessId, [string]$AutomationId) {
    $menu = Wait-AutomationElement $ProcessId $AutomationId -AutomationId
    $expand = $null
    if ($menu.TryGetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$expand)) {
        if ($AutomationId -eq 'menu.view') { Write-Host "View menu before Expand: $($expand.Current.ExpandCollapseState)" }
        $expand.Expand()
        if ($AutomationId -eq 'menu.view') { Write-Host "View menu after Expand: $($expand.Current.ExpandCollapseState)" }
    } else { Invoke-AutomationElement $menu }
    return $menu
}

function Close-AutomationMenu($Menu) {
    $expand = $null
    if ($Menu.TryGetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$expand)) {
        $expand.Collapse()
    } else { Invoke-AutomationElement $Menu }
}

function Invoke-MenuCommand([int]$ProcessId, [string]$MenuId, [string]$CommandId) {
    $null = Open-AutomationMenu $ProcessId $MenuId
    Invoke-AutomationElement (Wait-AutomationElement $ProcessId $CommandId -AutomationId)
}

function Open-AppearanceMenu([int]$ProcessId) {
    $menu = Open-AutomationMenu $ProcessId 'menu.view'
    $null = Open-AutomationMenu $ProcessId 'menu.appearance'
    return $menu
}

function Assert-DarkTheme([int]$ProcessId) {
    $menu = Open-AppearanceMenu $ProcessId
    try {
        $dark = Wait-AutomationElement $ProcessId 'theme.dark' -AutomationId
        $pattern = $null
        if ($dark.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) {
            if ($pattern.Current.ToggleState -eq [Windows.Automation.ToggleState]::On) { return }
        } elseif ($dark.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
            if ($pattern.Current.IsSelected) { return }
        }
        throw 'The Appearance menu did not select or restore Dark.'
    } finally { Close-AutomationMenu $menu }
}

function Assert-DocumentTree([int]$ProcessId, [string[]]$ExpectedNames, [switch]$ExerciseExpansion) {
    $tree = Wait-AutomationElement $ProcessId 'DocumentTree' -AutomationId
    if ($tree.Current.ControlType -ne [Windows.Automation.ControlType]::Tree) {
        # WinUI exposes TreeView's internal TreeViewList as the Tree peer.
        $tree = $tree.FindFirst([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Tree))
        if ($null -eq $tree) { throw 'Documents must contain the native WinUI Tree peer.' }
    }
    $condition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::TreeItem)
    # Raw descendants can include headings: compare only the expected file identities.
    $rows = $tree.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)
    $fileRows = @($rows | Where-Object { $_.Current.Name -in $ExpectedNames })
    $actualNames = @($fileRows | ForEach-Object { $_.Current.Name })
    if (($actualNames -join '|') -ne ($ExpectedNames -join '|')) {
        throw "Document tree order differs. Expected '$($ExpectedNames -join ', ')'; found '$($actualNames -join ', ')'."
    }
    if ($ExerciseExpansion) {
        $expand = $fileRows[0].GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern)
        $expand.Expand()
        Assert-DocumentTree $ProcessId $ExpectedNames
        $first = $tree.FindAll([Windows.Automation.TreeScope]::Descendants, $condition) |
            Where-Object { $_.Current.Name -eq $ExpectedNames[0] } | Select-Object -First 1
        $first.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
        Assert-DocumentTree $ProcessId $ExpectedNames
        $first = $tree.FindAll([Windows.Automation.TreeScope]::Descendants, $condition) |
            Where-Object { $_.Current.Name -eq $ExpectedNames[0] } | Select-Object -First 1
        $first.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
        Assert-DocumentTree $ProcessId $ExpectedNames
    }
}

function Assert-NavigationHighlight([Diagnostics.Process]$Target, [switch]$Expired) {
    $reader = Wait-AutomationElement $Target.Id 'ReaderScroll' -AutomationId
    $deadline = (Get-Date).AddSeconds($(if ($Expired) { 4 } else { 1 }))
    do {
        $highlighted = $reader.Current.HelpText -eq 'Navigation target: 0'
        if ($highlighted -ne $Expired.IsPresent) { return }
        Start-Sleep -Milliseconds 50
    } while ((Get-Date) -lt $deadline)
    throw $(if ($Expired) { 'The outline navigation highlight did not expire.' } else { 'The activated heading did not receive a navigation highlight.' })
}

function Assert-URLDialogCancellation([Diagnostics.Process]$Target) {
    # Verify the real shortcut before File has ever been opened.
    Send-TestShortcut $Target 0x4C # Ctrl+L
    $input = Wait-AutomationElement $Target.Id 'URLInput' -AutomationId
    $input.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('https://example.invalid/document.md')
    $null = Wait-AutomationElement $Target.Id 'Open'
    Invoke-AutomationElement (Wait-AutomationElement $Target.Id 'Cancel')
    Wait-DocumentWindow $Target 'Windows.md — SSMV'
    Assert-DocumentTree $Target.Id @('Windows.md')
    $window = [Windows.Automation.AutomationElement]::FromHandle($Target.MainWindowHandle)
    $remaining = $window.FindAll([Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, 'URLInput'))
    if (@($remaining | Where-Object { !$_.Current.IsOffscreen }).Count) { throw 'Cancel did not dismiss the URL dialog.' }
    $menu = Open-AutomationMenu $Target.Id 'menu.file'
    try {
        foreach ($command in @(@('action.openURL', 'Ctrl+L'), @('action.exportPDF', 'Ctrl+P'))) {
            $item = Wait-AutomationElement $Target.Id $command[0] -AutomationId
            if ($item.Current.AcceleratorKey -ne $command[1]) {
                throw "Expected $($command[0]) to expose $($command[1]); found '$($item.Current.AcceleratorKey)'."
            }
        }
        Save-WindowEvidence $Target 'window-file-menu.png' -IncludePopup
    } finally { Close-AutomationMenu $menu }
    Write-Output 'Ctrl+L opened the URL dialog; cancellation preserved the document shelf. URL and PDF menu shortcuts are exposed.'
}

function Assert-RepeatedHeadingNavigation([Diagnostics.Process]$Target) {
    $ProcessId = $Target.Id
    $tree = Wait-AutomationElement $ProcessId 'DocumentTree' -AutomationId
    $condition = [Windows.Automation.AndCondition]::new(
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::TreeItem),
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, 'Markdown, at home on Windows.'))
    $deadline = (Get-Date).AddSeconds(15)
    do {
        $heading = $tree.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
        if ($null -ne $heading) { break }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    if ($null -eq $heading) {
        $tree.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition) | ForEach-Object { Write-Output ("Tree evidence: " + $_.Current.ControlType.ProgrammaticName + " / " + $_.Current.Name) }
        throw 'The public sample heading was not available in the document tree.'
    }
    $heading.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $heading.SetFocus()
    Send-TestShortcut $Target 0x0D -NoControl
    Assert-NavigationHighlight $Target
    Save-WindowEvidence $Target 'window-outline-highlight.png'
    Assert-NavigationHighlight $Target -Expired
    $reader = Wait-AutomationElement $ProcessId 'ReaderScroll' -AutomationId
    $scroll = $reader.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern)
    if (!$scroll.Current.VerticallyScrollable) { throw 'The public sample must scroll to exercise repeated heading navigation.' }
    $scroll.SetScrollPercent([Windows.Automation.ScrollPattern]::NoScroll, 100)
    $deadline = (Get-Date).AddSeconds(5)
    while ($scroll.Current.VerticalScrollPercent -lt 90 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if ($scroll.Current.VerticalScrollPercent -lt 90) { throw 'Could not move the reader away from the selected heading.' }
    # Activate the same selected heading again, with no selection change.
    $heading.SetFocus()
    Send-TestShortcut $Target 0x0D -NoControl
    Assert-NavigationHighlight $Target
    $deadline = (Get-Date).AddSeconds(5)
    while ($scroll.Current.VerticalScrollPercent -ge 10 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if ($scroll.Current.VerticalScrollPercent -ge 10) { throw 'Invoking the already-selected heading did not return to its content.' }
    Assert-NavigationHighlight $Target -Expired
    Write-Output 'Repeated heading activation returned to its content and reapplied the transient highlight; both highlights expired.'
}

function Assert-InactiveOutlineCollapse([Diagnostics.Process]$Target) {
    $tree = Wait-AutomationElement $Target.Id 'DocumentTree' -AutomationId
    $rowCondition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::TreeItem)
    $findRow = {
        param([string]$Name)
        $deadline = (Get-Date).AddSeconds(5)
        do {
            $row = $tree.FindAll([Windows.Automation.TreeScope]::Descendants, $rowCondition) |
                Where-Object { $_.Current.Name -eq $Name } | Select-Object -First 1
            if ($null -ne $row) { return $row }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $deadline)
        throw "Missing document tree row: $Name"
    }
    $first = & $findRow 'Windows.md'
    $first.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Wait-DocumentWindow $Target 'Windows.md — SSMV'
    $second = & $findRow 'Warm activation 한글.md'
    $second.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    $null = Wait-AutomationElement $Target.Id 'Warm activation'
    $heading = & $findRow 'Warm activation'
    # Keyboard selection alone must not navigate the reader to another document.
    $heading.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $Target.Refresh()
    if ($Target.MainWindowTitle -ne 'Windows.md — SSMV') { throw 'Selecting an inactive heading changed the active document before invocation.' }
    $second = & $findRow 'Warm activation 한글.md'
    $second.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
    $deadline = (Get-Date).AddSeconds(5)
    do {
        $first = & $findRow 'Windows.md'
        $selected = $first.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected
        if ($selected) { break }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    if (!$selected) {
        $Target.Refresh()
        Write-Host "Reader title after inactive collapse: $($Target.MainWindowTitle)"
        Save-WindowEvidence $Target 'inactive-collapse-failure.png'
        throw 'Collapsing an inactive outline did not restore selection to the active document.'
    }
    $Target.Refresh()
    if ($Target.MainWindowTitle -ne 'Windows.md — SSMV') { throw 'Collapsing the inactive outline switched the active document.' }
    $second = & $findRow 'Warm activation 한글.md'
    $second.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Wait-DocumentWindow $Target 'Warm activation 한글.md — SSMV'
    Write-Output 'Collapsing an inactive selected heading preserved the active reader and restored its root selection.'
}

function Save-WindowEvidence([Diagnostics.Process]$Target, [string]$Name, [switch]$IncludePopup) {
    Start-Sleep -Milliseconds 500
    $Target.Refresh()
    # GetWindowRect is DPI-virtualized and includes invisible resize borders;
    # DWM frame bounds provide visible physical pixels for screen captures.
    $previousDpi = [WindowCapture]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
    if ($previousDpi -eq [IntPtr]::Zero) { throw 'Could not establish physical-pixel screenshot coordinates.' }
    try {
        $rect = New-Object WindowCapture+RECT
        $measured = if ($IncludePopup) {
            [WindowCapture]::DwmGetWindowAttribute($Target.MainWindowHandle, 9, [ref]$rect, 16) -eq 0
        } else { [WindowCapture]::GetWindowRect($Target.MainWindowHandle, [ref]$rect) }
        if (!$measured) { throw 'Could not measure the screenshot window.' }
        $bitmap = [System.Drawing.Bitmap]::new(($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            if ($IncludePopup) {
                $foregroundProcess = [uint32]0
                $null = [WindowCapture]::GetWindowThreadProcessId([WindowCapture]::GetForegroundWindow(), [ref]$foregroundProcess)
                if ($foregroundProcess -ne $Target.Id) { throw 'Refusing screen capture: the isolated app is not foreground.' }
                # Copy only the app rectangle; the OS pointer is not painted by CopyFromScreen.
                $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
            } else {
                $dc = $graphics.GetHdc()
                try { $captured = [WindowCapture]::PrintWindow($Target.MainWindowHandle, $dc, 2) }
                finally { $graphics.ReleaseHdc($dc) }
                if (!$captured) { throw "Could not capture $Name evidence." }
            }
            $bitmap.Save((Join-Path $evidence $Name))
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
    } finally { $null = [WindowCapture]::SetThreadDpiAwarenessContext($previousDpi) }
}

# Real keystrokes target only the test-owned foreground process. UIA invocation
# alone cannot prove that menu accelerators work with all menus closed.
function Send-TestShortcut([Diagnostics.Process]$Target, [ushort]$Key, [switch]$Shift, [switch]$NoControl) {
    $Target.Refresh()
    if ($Target.HasExited) { throw 'Cannot send a shortcut to an exited test process.' }
    $null = [WindowCapture]::SetForegroundWindow($Target.MainWindowHandle)
    $deadline = (Get-Date).AddSeconds(5)
    do {
        $foregroundProcess = [uint32]0
        $null = [WindowCapture]::GetWindowThreadProcessId([WindowCapture]::GetForegroundWindow(), [ref]$foregroundProcess)
        if ($foregroundProcess -eq $Target.Id) {
            [WindowCapture]::SendShortcut($Key, $Shift.IsPresent, !$NoControl.IsPresent)
            # SendInput queues events; allow key-up and layout handlers to finish
            # before the next shortcut. Each action is still sent exactly once.
            Start-Sleep -Milliseconds 150
            return
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw 'Refusing to send keyboard input: the isolated SSMV window is not foreground.'
}

function Wait-SavedPreference([string]$Preference, $Expected) {
    $deadline = (Get-Date).AddSeconds(10)
    do {
        $sessionFile = Join-Path $env:SSMV_DATA_DIR 'session.bin'
        if (Test-Path $sessionFile -PathType Leaf) {
            $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($sessionFile))
            try {
                $null = $reader.ReadBytes(8)
                $preferences = @{
                    Theme = $reader.ReadUInt32()
                    FontSize = $reader.ReadDouble()
                    Outline = $reader.ReadBoolean()
                    Sidebar = $reader.ReadBoolean()
                }
                if ($preferences[$Preference] -eq $Expected) { return }
            } finally { $reader.Dispose() }
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    Write-Host "Preference failure: $Preference expected=$Expected; last saved state=$($preferences | ConvertTo-Json -Compress)"
    try {
        $target = $startedProcesses | Where-Object { !$_.HasExited -and $_.MainWindowTitle -eq 'Windows.md — SSMV' } | Select-Object -First 1
        if ($null -ne $target) { Save-WindowEvidence $target 'window-preference-failure.png' -IncludePopup }
    } catch { Write-Host "Preference screenshot failed: $_" }
    throw "Shortcut did not update $Preference to $Expected; last actual value: $($preferences[$Preference])."
}

function Read-SessionText([IO.BinaryReader]$Reader) {
    $length = $Reader.ReadUInt32()
    if ($length -gt 32768) { throw 'Invalid session path length.' }
    $bytes = $Reader.ReadBytes([int]$length)
    if ($bytes.Length -ne $length) { throw 'Truncated session path.' }
    return [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
}

function Assert-SavedSession {
    $sessionFile = Join-Path $env:SSMV_DATA_DIR 'session.bin'
    if (!(Test-Path $sessionFile -PathType Leaf)) { throw 'SSMV did not save its session in the isolated data directory.' }
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($sessionFile))
    try {
        if ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(8)) -ne 'SSMVSES1') { throw 'Unexpected session format.' }
        $savedTheme = $reader.ReadUInt32()
        $savedFontSize = $reader.ReadDouble()
        if ($savedTheme -ne 2 -or $savedFontSize -ne 18) {
            throw "Reading preferences were not saved: theme=$savedTheme, fontSize=$savedFontSize."
        }
        $null = $reader.ReadBoolean() # Outline
        $null = $reader.ReadBoolean() # Sidebar
        $selectedPath = Read-SessionText $reader
        if ([IO.Path]::GetFullPath($selectedPath) -ne [IO.Path]::GetFullPath($secondDocument)) {
            throw "The second document was not saved as selected: '$selectedPath'."
        }
        $count = $reader.ReadUInt32()
        if ($count -ne 2) { throw "Expected two saved documents; found $count." }
        $paths = @()
        for ($index = 0; $index -lt $count; $index++) {
            $paths += [IO.Path]::GetFullPath((Read-SessionText $reader))
            $null = $reader.ReadUInt32() # Body page
            $null = $reader.ReadDouble() # Scroll offset
        }
        if ($paths[0] -ne [IO.Path]::GetFullPath($document) -or $paths[1] -ne [IO.Path]::GetFullPath($secondDocument)) {
            throw 'Saved documents do not preserve the cold/warm open order.'
        }
    } finally { $reader.Dispose() }
}

try {
    $process = Start-Process -FilePath $executablePath -ArgumentList ('"' + $document + '"') -PassThru
    $startedProcesses.Add($process)
    Wait-DocumentWindow $process 'Windows.md — SSMV'
    # Capture only this public sample window for visual inspection of CI artifacts.
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WindowCapture {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", SetLastError = true)] static extern bool SystemParametersInfo(uint action, uint parameter, out RECT value, uint flags);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
    public static void PositionForCapture(IntPtr hwnd) {
        IntPtr previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        if (previous == IntPtr.Zero) throw new InvalidOperationException("Could not establish physical window placement.");
        try {
            RECT work;
            if (!SystemParametersInfo(0x0030, 0, out work, 0))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not read primary monitor work area.");
            int width = Math.Min(1000, work.Right - work.Left - 24);
            int height = Math.Min(720, work.Bottom - work.Top - 24);
            if (width < 640 || height < 480) throw new InvalidOperationException("CI desktop is too small for the native smoke window.");
            int x = work.Left + (work.Right - work.Left - width) / 2;
            int y = work.Top + (work.Bottom - work.Top - height) / 2;
            if (!SetWindowPos(hwnd, IntPtr.Zero, x, y, width, height, 0x0014))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not position the test window.");
            RECT actual;
            if (!GetWindowRect(hwnd, out actual) || actual.Left < work.Left || actual.Top < work.Top || actual.Right > work.Right || actual.Bottom > work.Bottom)
                throw new InvalidOperationException("The test window is not fully inside the desktop work area.");
        } finally { SetThreadDpiAwarenessContext(previous); }
    }
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, uint attribute, out RECT value, uint size);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public INPUTUNION data; }
    [StructLayout(LayoutKind.Explicit)] struct INPUTUNION {
        [FieldOffset(0)] public KEYBDINPUT keyboard;
        [FieldOffset(0)] public MOUSEINPUT mouse;
    }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT {
        public ushort key, scan; public uint flags, time; public UIntPtr extra;
    }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT {
        public int x, y; public uint mouseData, flags, time; public UIntPtr extra;
    }
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint count, INPUT[] inputs, int size);
    static INPUT Keyboard(ushort key, bool up) {
        return new INPUT { type = 1, data = new INPUTUNION {
            keyboard = new KEYBDINPUT { key = key, flags = up ? 2u : 0u }
        }};
    }
    public static void SendShortcut(ushort key, bool shift, bool control) {
        INPUT[] events = !control ? new[] { Keyboard(key, false), Keyboard(key, true) } : shift
            ? new[] { Keyboard(0x11, false), Keyboard(0x10, false), Keyboard(key, false), Keyboard(key, true), Keyboard(0x10, true), Keyboard(0x11, true) }
            : new[] { Keyboard(0x11, false), Keyboard(key, false), Keyboard(key, true), Keyboard(0x11, true) };
        if (SendInput((uint)events.Length, events, Marshal.SizeOf(typeof(INPUT))) != events.Length) {
            int error = Marshal.GetLastWin32Error();
            // Release modifiers even if Windows accepted only part of the sequence.
            INPUT[] release = { Keyboard(key, true), Keyboard(0x10, true), Keyboard(0x11, true) };
            SendInput((uint)release.Length, release, Marshal.SizeOf(typeof(INPUT)));
            throw new System.ComponentModel.Win32Exception(error, "Shortcut injection failed.");
        }
    }
}
'@
    $evidence = Join-Path $repositoryRoot 'dist/windows/smoke'
    New-Item -ItemType Directory -Force $evidence > $null
    try { Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes }
    catch {
        # PowerShell 7 may need the installed Windows Desktop Framework assemblies.
        $automationAssemblies = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/WPF'
        Add-Type -Path (Join-Path $automationAssemblies 'UIAutomationTypes.dll')
        Add-Type -Path (Join-Path $automationAssemblies 'UIAutomationClient.dll')
    }
    [WindowCapture]::PositionForCapture($process.MainWindowHandle)
    Save-WindowEvidence $process 'window-startup.png'
    $freshView = Open-AutomationMenu $process.Id 'menu.view'
    $null = Wait-AutomationElement $process.Id 'menu.appearance' -AutomationId
    Save-WindowEvidence $process 'window-view-initial.png' -IncludePopup
    Close-AutomationMenu $freshView
    Write-Output 'Fresh View menu opened before tree or keyboard interactions.'
    Assert-DocumentTree $process.Id @('Windows.md') -ExerciseExpansion
    Save-WindowEvidence $process 'window-expanded.png'
    Assert-RepeatedHeadingNavigation $process
    Assert-URLDialogCancellation $process
    Save-WindowEvidence $process 'window.png'
    # Verify registration before the Edit menu has ever been opened.
    Send-TestShortcut $process 0x46
    $null = Wait-AutomationElement $process.Id 'FindBox' -AutomationId
    Invoke-AutomationElement (Wait-AutomationElement $process.Id 'Close search')
    $editMenu = Open-AutomationMenu $process.Id 'menu.edit'
    $findCommand = Wait-AutomationElement $process.Id 'action.find' -AutomationId
    if ([string]::IsNullOrWhiteSpace($findCommand.Current.AcceleratorKey)) {
        throw 'Find must expose its keyboard shortcut through native accessibility.'
    }
    Save-WindowEvidence $process 'window-menu.png' -IncludePopup
    Invoke-AutomationElement $findCommand
    $findBox = Wait-AutomationElement $process.Id 'FindBox' -AutomationId
    $findBox.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('Hello from SSMV')
    Invoke-AutomationElement (Wait-AutomationElement $process.Id 'Next')
    $null = Wait-AutomationElement $process.Id '1 / 1 matching sections'
    $findBox.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('ssmv-no-match-7f6a4b2e')
    Invoke-AutomationElement (Wait-AutomationElement $process.Id 'Next')
    $null = Wait-AutomationElement $process.Id 'No matches'
    Invoke-AutomationElement (Wait-AutomationElement $process.Id 'Close search')
    Send-TestShortcut $process 0xBB -Shift # Ctrl+Shift+= on the standard keyboard.
    Wait-SavedPreference 'FontSize' 18
    Send-TestShortcut $process 0xBD # Ctrl+- uses the regular keyboard, not the keypad.
    Wait-SavedPreference 'FontSize' 16
    Send-TestShortcut $process 0xBB -Shift
    Wait-SavedPreference 'FontSize' 18
    Send-TestShortcut $process 0x4C -Shift
    Wait-SavedPreference 'Sidebar' $false
    Send-TestShortcut $process 0x4C -Shift
    Wait-SavedPreference 'Sidebar' $true
    $null = Wait-AutomationElement $process.Id 'DocumentTree' -AutomationId
    Send-TestShortcut $process 0x4F -Shift
    Wait-SavedPreference 'Outline' $false
    Send-TestShortcut $process 0x4F -Shift
    Wait-SavedPreference 'Outline' $true
    Assert-DocumentTree $process.Id @('Windows.md')
    Write-Output 'Real Ctrl+F, Ctrl+Shift+=, Ctrl+Shift+L, and Ctrl+Shift+O shortcuts passed with menus closed.'
    $null = Open-AppearanceMenu $process.Id
    $darkOption = Wait-AutomationElement $process.Id 'theme.dark' -AutomationId
    $darkOption.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
    Wait-SavedPreference 'Theme' 2
    Assert-DarkTheme $process.Id
    $reader = Wait-AutomationElement $process.Id 'ReaderScroll' -AutomationId
    $reader.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern).SetScrollPercent(-1, 0)
    Save-WindowEvidence $process 'window-dark.png'
    Write-Output 'Native Find (match and no match), text-size increase, and Dark theme selection passed.'

    $originalProcessId = $process.Id
    $forwarder = Start-Process -FilePath $executablePath -ArgumentList ('"' + $secondDocument + '"') -PassThru
    $startedProcesses.Add($forwarder)
    if (!$forwarder.WaitForExit(30000)) { throw 'The second process did not finish forwarding its activation.' }
    if ($forwarder.ExitCode -ne 0) { throw "Warm activation failed with exit code $($forwarder.ExitCode)." }
    Wait-DocumentWindow $process 'Warm activation 한글.md — SSMV'
    if ($process.Id -ne $originalProcessId) { throw 'Warm activation replaced the original process.' }
    Assert-DocumentTree $process.Id @('Windows.md', 'Warm activation 한글.md') -ExerciseExpansion
    Assert-InactiveOutlineCollapse $process
    Close-DocumentWindow $process
    Assert-SavedSession

    # A no-argument launch must restore both documents and the selected second file.
    $restored = Start-Process -FilePath $executablePath -PassThru
    $startedProcesses.Add($restored)
    Wait-DocumentWindow $restored 'Warm activation 한글.md — SSMV'
    Assert-DarkTheme $restored.Id
    Assert-DocumentTree $restored.Id @('Windows.md', 'Warm activation 한글.md') -ExerciseExpansion
    Close-DocumentWindow $restored
    Assert-SavedSession
    Write-Output 'Cold open, same-process warm activation, two-file session persistence, selected-document and reading-preference restoration, and orderly closes passed.'

    # Exercise the real async URL path only after the original two-file session checks.
    $remoteReader = Start-Process -FilePath $executablePath -PassThru
    $startedProcesses.Add($remoteReader)
    Wait-DocumentWindow $remoteReader 'Warm activation 한글.md — SSMV'
    Send-TestShortcut $remoteReader 0x4C
    $urlInput = Wait-AutomationElement $remoteReader.Id 'URLInput' -AutomationId
    $urlInput.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('https://github.com/raeseoklee/ssmv/blob/main/README.md')
    Invoke-AutomationElement (Wait-AutomationElement $remoteReader.Id 'Open')
    Wait-DocumentWindow $remoteReader 'README.md — SSMV'
    Assert-DocumentTree $remoteReader.Id @('Windows.md', 'Warm activation 한글.md', 'README.md')
    $remoteDirectory = Join-Path $env:SSMV_DATA_DIR 'remotes'
    $cachedDocuments = @(Get-ChildItem -LiteralPath $remoteDirectory -Filter README.md -Recurse -File)
    if ($cachedDocuments.Count -ne 1 -or $cachedDocuments[0].Length -eq 0) { throw 'URL open did not persist one nonempty README.md cache entry.' }
    $cachedPath = $cachedDocuments[0].FullName
    $metadataPath = $cachedPath + '.url'
    if (!(Test-Path -LiteralPath $metadataPath) -or [IO.File]::ReadAllText($metadataPath) -notmatch 'githubusercontent\.com/.+/README\.md') {
        throw 'The downloaded document did not preserve its normalized source URL.'
    }
    Close-DocumentWindow $remoteReader
    # A cache-only marker distinguishes restoration from downloading the remote README again.
    $cacheMarker = 'SSMV cached document restoration 9a7e2c'
    [IO.File]::WriteAllText($cachedPath, "# $cacheMarker`n`nThis content exists only in the isolated local cache.", [Text.UTF8Encoding]::new($false))
    $cachedReader = Start-Process -FilePath $executablePath -PassThru
    $startedProcesses.Add($cachedReader)
    Wait-DocumentWindow $cachedReader 'README.md — SSMV'
    $null = Wait-AutomationElement $cachedReader.Id $cacheMarker
    Assert-DocumentTree $cachedReader.Id @('Windows.md', 'Warm activation 한글.md', 'README.md')
    Send-TestShortcut $cachedReader 0x52 # Ctrl+R must refresh both disk and the displayed document.
    $deadline = (Get-Date).AddSeconds(30)
    $refreshed = $false
    do {
        $cachedReader.Refresh()
        if ($cachedReader.HasExited) { throw 'SSMV exited while refreshing the remote document.' }
        $diskRefreshed = ![IO.File]::ReadAllText($cachedPath).Contains($cacheMarker)
        $window = [Windows.Automation.AutomationElement]::FromHandle($cachedReader.MainWindowHandle)
        $reader = $window.FindFirst([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, 'ReaderScroll'))
        if ($diskRefreshed -and $null -ne $reader) {
            $oldContent = $reader.FindFirst([Windows.Automation.TreeScope]::Descendants,
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, $cacheMarker))
            if ($null -eq $oldContent) { $refreshed = $true; break }
        }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    if (!$refreshed) { throw 'Remote reload did not replace both cached Markdown and the in-memory reader content.' }
    Wait-DocumentWindow $cachedReader 'README.md — SSMV'
    Assert-DocumentTree $cachedReader.Id @('Windows.md', 'Warm activation 한글.md', 'README.md')
    Close-DocumentWindow $cachedReader
    Write-Output 'Ctrl+L downloaded a GitHub document, cached Markdown and source metadata, restored the selected document from local cache, and refreshed its displayed content without duplicating or reordering the shelf.'

} catch {
    foreach ($started in $startedProcesses) {
        $started.Refresh()
        if ($started.HasExited -and $started.ExitCode -ne 0) { Write-CrashEvidence $started }
    }
    throw
} finally {
    foreach ($started in $startedProcesses) {
        $started.Refresh()
        if (!$started.HasExited) { Stop-Process -Id $started.Id -Force; $null = $started.WaitForExit(10000) }
        $started.Dispose()
    }
    $env:SSMV_DATA_DIR = $previousDataDirectory
    Remove-Item -LiteralPath $testDirectory -Recurse -Force
}
