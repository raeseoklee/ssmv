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
        $element = [Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
        if ($null -ne $element -and $element.Current.IsEnabled -and !$element.Current.IsOffscreen) { return $element }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
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
        $expand.Expand()
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

function Assert-RepeatedHeadingNavigation([int]$ProcessId) {
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
    Invoke-AutomationElement $heading
    Start-Sleep -Milliseconds 300 # Let the first bring-into-view/layout complete.
    $reader = Wait-AutomationElement $ProcessId 'ReaderScroll' -AutomationId
    $scroll = $reader.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern)
    if (!$scroll.Current.VerticallyScrollable) { throw 'The public sample must scroll to exercise repeated heading navigation.' }
    $scroll.SetScrollPercent([Windows.Automation.ScrollPattern]::NoScroll, 100)
    $deadline = (Get-Date).AddSeconds(5)
    while ($scroll.Current.VerticalScrollPercent -lt 90 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if ($scroll.Current.VerticalScrollPercent -lt 90) { throw 'Could not move the reader away from the selected heading.' }
    # Invoke the same selected heading, without a selection change between calls.
    Invoke-AutomationElement $heading
    $deadline = (Get-Date).AddSeconds(5)
    while ($scroll.Current.VerticalScrollPercent -ge 10 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if ($scroll.Current.VerticalScrollPercent -ge 10) { throw 'Invoking the already-selected heading did not return to its content.' }
    Write-Output 'Repeated activation of the same selected heading returned the reader to its content.'
}

function Save-WindowEvidence([Diagnostics.Process]$Target, [string]$Name) {
    Start-Sleep -Milliseconds 500
    $Target.Refresh()
    $rect = New-Object WindowCapture+RECT
    if (![WindowCapture]::GetWindowRect($Target.MainWindowHandle, [ref]$rect)) { throw 'Could not measure the screenshot window.' }
    $bitmap = [System.Drawing.Bitmap]::new(($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $dc = $graphics.GetHdc()
        try { $captured = [WindowCapture]::PrintWindow($Target.MainWindowHandle, $dc, 2) }
        finally { $graphics.ReleaseHdc($dc) }
        if (!$captured) { throw "Could not capture $Name evidence." }
        $bitmap.Save((Join-Path $evidence $Name))
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}

# Real keystrokes target only the test-owned foreground process. UIA invocation
# alone cannot prove that menu accelerators work with all menus closed.
function Send-TestShortcut([Diagnostics.Process]$Target, [ushort]$Key, [switch]$Shift) {
    $Target.Refresh()
    if ($Target.HasExited) { throw 'Cannot send a shortcut to an exited test process.' }
    $null = [WindowCapture]::SetForegroundWindow($Target.MainWindowHandle)
    $deadline = (Get-Date).AddSeconds(5)
    do {
        $foregroundProcess = [uint32]0
        $null = [WindowCapture]::GetWindowThreadProcessId([WindowCapture]::GetForegroundWindow(), [ref]$foregroundProcess)
        if ($foregroundProcess -eq $Target.Id) {
            [WindowCapture]::SendShortcut($Key, $Shift.IsPresent)
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
    throw "Shortcut did not update $Preference to $Expected."
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
    public static void SendShortcut(ushort key, bool shift) {
        INPUT[] events = shift
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
    Save-WindowEvidence $process 'window-startup.png'
    Assert-DocumentTree $process.Id @('Windows.md') -ExerciseExpansion
    Save-WindowEvidence $process 'window-expanded.png'
    Assert-RepeatedHeadingNavigation $process.Id
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
    Save-WindowEvidence $process 'window-menu.png'
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
    Invoke-AutomationElement (Wait-AutomationElement $process.Id 'theme.dark' -AutomationId)
    Assert-DarkTheme $process.Id
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
} finally {
    foreach ($started in $startedProcesses) {
        $started.Refresh()
        if (!$started.HasExited) { Stop-Process -Id $started.Id -Force; $null = $started.WaitForExit(10000) }
        $started.Dispose()
    }
    $env:SSMV_DATA_DIR = $previousDataDirectory
    Remove-Item -LiteralPath $testDirectory -Recurse -Force
}
