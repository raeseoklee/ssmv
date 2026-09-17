param([Parameter(Mandatory)][string]$Executable)
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$document = Join-Path $repositoryRoot 'Examples/Windows.md'
$process = Start-Process -FilePath (Resolve-Path $Executable) -ArgumentList ('"' + $document + '"') -PassThru
try {
    $deadline = (Get-Date).AddSeconds(30)
    $loaded = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $process.Refresh()
        if ($process.HasExited) { throw "SSMV exited during startup with code $($process.ExitCode)." }
        # The title changes only after the requested document was loaded and selected.
        if ($process.MainWindowTitle -eq 'Windows.md — SSMV') { $loaded = $true; break }
        if ($process.MainWindowTitle -eq 'SSMV could not start') { throw 'SSMV reported a native startup error.' }
    }
    if (!$loaded) { throw "The document window did not become ready. Title: $($process.MainWindowTitle)" }
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
    Start-Sleep -Seconds 2
    $process.Refresh()
    if ($process.HasExited) { throw 'SSMV exited after opening the document.' }
    if (!$process.CloseMainWindow()) { throw 'Could not close the document window normally.' }
    if (!$process.WaitForExit(10000)) { throw 'SSMV did not exit after its window closed.' }
    if ($process.ExitCode -ne 0) { throw "SSMV exited with code $($process.ExitCode)." }
    Write-Output 'Native startup, file-argument open, and orderly window close passed.'
} finally {
    $process.Refresh()
    if (!$process.HasExited) { Stop-Process -Id $process.Id -Force }
}
