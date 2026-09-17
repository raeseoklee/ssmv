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
