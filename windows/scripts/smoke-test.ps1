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
        $null = $reader.ReadUInt32() # Theme
        $null = $reader.ReadDouble() # Font size
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
    Close-DocumentWindow $restored
    Assert-SavedSession
    Write-Output 'Cold open, same-process warm activation, two-file session persistence, selected-document restoration, and orderly closes passed.'
} finally {
    foreach ($started in $startedProcesses) {
        $started.Refresh()
        if (!$started.HasExited) { Stop-Process -Id $started.Id -Force; $null = $started.WaitForExit(10000) }
        $started.Dispose()
    }
    $env:SSMV_DATA_DIR = $previousDataDirectory
    Remove-Item -LiteralPath $testDirectory -Recurse -Force
}
