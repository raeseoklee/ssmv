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
function Wait-AutomationElement([int]$ProcessId, [string]$Value, [switch]$AutomationId, [switch]$ComboBox) {
    $property = if ($AutomationId) { [Windows.Automation.AutomationElement]::AutomationIdProperty } else { [Windows.Automation.AutomationElement]::NameProperty }
    $identity = if ($ComboBox) {
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ComboBox)
    } else { [Windows.Automation.PropertyCondition]::new($property, $Value) }
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

function Invoke-MoreCommand([int]$ProcessId, [string]$Command) {
    $more = Wait-AutomationElement $ProcessId 'More'
    $expand = $null
    if ($more.TryGetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$expand)) {
        $expand.Expand()
    } else { Invoke-AutomationElement $more }
    Invoke-AutomationElement (Wait-AutomationElement $ProcessId $Command)
}

function Assert-DarkTheme([int]$ProcessId) {
    $deadline = (Get-Date).AddSeconds(15)
    do {
        $combo = Wait-AutomationElement $ProcessId 'theme selector' -ComboBox
        $selection = $combo.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()
        if ($selection.Count -eq 1 -and $selection[0].Current.Name -eq 'Dark') { return }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    throw 'The theme selector did not select or restore Dark.'
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
}
'@
    $evidence = Join-Path $repositoryRoot 'dist/windows/smoke'
    New-Item -ItemType Directory -Force $evidence > $null
    $rect = New-Object WindowCapture+RECT
    if ([WindowCapture]::GetWindowRect($process.MainWindowHandle, [ref]$rect)) {
        $bitmap = [System.Drawing.Bitmap]::new(($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $dc = $graphics.GetHdc()
        try { $captured = [WindowCapture]::PrintWindow($process.MainWindowHandle, $dc, 2) }
        finally { $graphics.ReleaseHdc($dc) }
        if ($captured) { $bitmap.Save((Join-Path $evidence 'window.png')) }
        $graphics.Dispose()
        $bitmap.Dispose()
    }
    try { Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes }
    catch {
        # PowerShell 7 may need the installed Windows Desktop Framework assemblies.
        $automationAssemblies = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/WPF'
        Add-Type -Path (Join-Path $automationAssemblies 'UIAutomationTypes.dll')
        Add-Type -Path (Join-Path $automationAssemblies 'UIAutomationClient.dll')
    }
    Invoke-MoreCommand $process.Id 'Find…'
    $findBox = Wait-AutomationElement $process.Id 'FindBox' -AutomationId
    $findBox.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('Hello from SSMV')
    Invoke-AutomationElement (Wait-AutomationElement $process.Id 'Next')
    $null = Wait-AutomationElement $process.Id '1 / 1 matching sections'
    $findBox.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('ssmv-no-match-7f6a4b2e')
    Invoke-AutomationElement (Wait-AutomationElement $process.Id 'Next')
    $null = Wait-AutomationElement $process.Id 'No matches'
    Invoke-AutomationElement (Wait-AutomationElement $process.Id 'Close search')
    Invoke-MoreCommand $process.Id 'Increase Text Size'
    $themeSelector = Wait-AutomationElement $process.Id 'theme selector' -ComboBox
    $themeSelector.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    $dark = Wait-AutomationElement $process.Id 'Dark'
    $dark.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Assert-DarkTheme $process.Id
    Write-Output 'Native Find (match and no match), text-size increase, and Dark theme selection passed.'

    $originalProcessId = $process.Id
    $forwarder = Start-Process -FilePath $executablePath -ArgumentList ('"' + $secondDocument + '"') -PassThru
    $startedProcesses.Add($forwarder)
    if (!$forwarder.WaitForExit(30000)) { throw 'The second process did not finish forwarding its activation.' }
    if ($forwarder.ExitCode -ne 0) { throw "Warm activation failed with exit code $($forwarder.ExitCode)." }
    Wait-DocumentWindow $process 'Warm activation 한글.md — SSMV'
    if ($process.Id -ne $originalProcessId) { throw 'Warm activation replaced the original process.' }
    Close-DocumentWindow $process
    Assert-SavedSession

    # A no-argument launch must restore both documents and the selected second file.
    $restored = Start-Process -FilePath $executablePath -PassThru
    $startedProcesses.Add($restored)
    Wait-DocumentWindow $restored 'Warm activation 한글.md — SSMV'
    Assert-DarkTheme $restored.Id
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
