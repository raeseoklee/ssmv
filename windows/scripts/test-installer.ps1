param(
    [Parameter(Mandatory)][string]$Installer,
    [switch]$FullReaderSmoke
)
$ErrorActionPreference = 'Stop'
if (!$IsWindows) { throw 'The installer smoke test requires Windows.' }
$installerPath = (Resolve-Path $Installer).Path
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs/SSMV'
$classes = 'HKCU:\Software\Classes'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SSMV'
$extensions = @('.md', '.markdown', '.mdown')
$capabilitiesKey = 'HKCU:\Software\SSMV\Capabilities'
$registeredApplications = 'HKCU:\Software\RegisteredApplications'
$ownedKeys = @("$classes\SSMV.Markdown", "$classes\Applications\SSMV.exe", $uninstallKey, $capabilitiesKey)
foreach ($extension in $extensions) { $ownedKeys += "$classes\SystemFileAssociations\$extension\shell\SSMV" }
# This test changes shell registrations. Never run it over an existing installation.
if ((Test-Path $installRoot) -or (Get-Process SSMV -ErrorAction SilentlyContinue)) {
    throw 'Close SSMV and remove the existing per-user installation before testing the installer.'
}
foreach ($key in $ownedKeys) {
    if (Test-Path $key) { throw "Existing SSMV registration must not be modified by this test: $key" }
}
$registered = Get-Item $registeredApplications -ErrorAction SilentlyContinue
if ($registered -and $registered.GetValueNames().Contains('SSMV')) {
    throw 'Existing SSMV RegisteredApplications value must not be modified by this test.'
}
foreach ($extension in $extensions) {
    $key = Get-Item "$classes\$extension\OpenWithProgids" -ErrorAction SilentlyContinue
    if ($key -and $key.GetValueNames().Contains('SSMV.Markdown')) { throw "Existing SSMV Open With registration: $extension" }
}
$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$evidence = Join-Path $repositoryRoot 'dist/windows/installer-smoke'
New-Item -ItemType Directory -Force $evidence > $null
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ssmv-installer-' + [Guid]::NewGuid().ToString('N'))
$foreignProgId = 'SSMVInstallerTest.' + [Guid]::NewGuid().ToString('N')
$seeded = @()
$target = $null
$previousDataDirectory = $env:SSMV_DATA_DIR
$unrelated = Join-Path $installRoot 'installer-test-unrelated.txt'
$dataRoot = Join-Path $env:LOCALAPPDATA 'SSMV'
$dataSentinel = Join-Path $dataRoot ($foreignProgId + '.txt')
$uninstaller = Join-Path $installRoot 'Uninstall.exe'

function Assert-True([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}
function Read-Default([string]$Key) {
    $item = Get-Item $Key -ErrorAction SilentlyContinue
    if ($item) { return $item.GetValue('') }
    return $null
}
function Run-Installer([string]$Path, [string]$Arguments, [bool]$ExpectedSuccess) {
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru
    if (!$process.WaitForExit(60000)) { $process.Kill(); throw "Installer process timed out: $Path" }
    Write-Host "$Path $Arguments -> $($process.ExitCode)"
    Assert-True (($process.ExitCode -eq 0) -eq $ExpectedSuccess) 'Installer exit code did not match the expected outcome.'
}
function Assert-Registration {
    $command = '"' + (Join-Path $installRoot 'SSMV.exe') + '" "%1"'
    foreach ($key in @("$classes\SSMV.Markdown\shell\open\command", "$classes\Applications\SSMV.exe\shell\open\command")) {
        Assert-True ((Read-Default $key) -eq $command) "Incorrect quoted open command: $key"
    }
    foreach ($extension in $extensions) {
        $key = Get-Item "$classes\$extension\OpenWithProgids"
        Assert-True ($key.GetValueNames().Contains('SSMV.Markdown')) "Missing Open With entry: $extension"
        Assert-True ((Read-Default "$classes\SystemFileAssociations\$extension\shell\SSMV\command") -eq $command) "Incorrect Explorer verb: $extension"
    }
    Assert-True (Test-Path $uninstallKey) 'Installed Apps registration is missing.'
    Assert-True (Test-Path $capabilitiesKey) 'Default Apps capabilities are missing.'
    Assert-True ((Get-Item $registeredApplications).GetValue('SSMV') -eq 'Software\SSMV\Capabilities') 'Default Apps registration is incorrect.'
}
function Assert-ForeignState {
    foreach ($extension in $extensions) {
        Assert-True ((Read-Default "$classes\$extension") -eq $foreignProgId) "The installer changed a foreign default: $extension"
        $key = Get-Item "$classes\$extension\OpenWithProgids"
        Assert-True ($key.GetValueNames().Contains($foreignProgId)) "The installer removed a foreign Open With entry: $extension"
    }
    Assert-True ((Get-Content $dataSentinel -Raw) -eq 'Preserve user data.') 'User data was modified or removed.'
}

Start-Transcript -Path (Join-Path $evidence 'installer-test.log') -Force > $null
try {
    $operatingSystem = Get-CimInstance Win32_OperatingSystem
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    Write-Host ("Host: {0}; version={1}; build={2}; native architecture={3}; full reader smoke={4}" -f $operatingSystem.Caption, $operatingSystem.Version, $operatingSystem.BuildNumber, $architecture, $FullReaderSmoke)
    New-Item -ItemType Directory $fixture > $null
    New-Item -ItemType Directory -Force $dataRoot > $null
    [IO.File]::WriteAllText($dataSentinel, 'Preserve user data.')
    $env:SSMV_DATA_DIR = Join-Path $fixture 'state'
    foreach ($extension in $extensions) {
        $path = "$classes\$extension"
        $old = Get-Item $path -ErrorAction SilentlyContinue
        $hadDefault = $old -and $old.GetValueNames().Contains('')
        $seeded += @{ Path = $path; Existed = [bool]$old; HadDefault = [bool]$hadDefault; Default = $(if ($hadDefault) { $old.GetValue('') }); Kind = $(if ($hadDefault) { $old.GetValueKind('') }) }
        if (!(Test-Path $path)) { New-Item $path -Force > $null }
        (Get-Item $path).SetValue('', $foreignProgId, [Microsoft.Win32.RegistryValueKind]::String)
        if (!(Test-Path "$path\OpenWithProgids")) { New-Item "$path\OpenWithProgids" -Force > $null }
        (Get-Item "$path\OpenWithProgids").SetValue($foreignProgId, '', [Microsoft.Win32.RegistryValueKind]::String)
    }
    Run-Installer $installerPath '/S' $true
    foreach ($file in @('SSMV.exe', 'Microsoft.UI.Xaml.dll', 'vcruntime140.dll', 'msvcp140.dll', 'Uninstall.exe')) {
        Assert-True (Test-Path (Join-Path $installRoot $file)) "Missing installed payload: $file"
    }
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead((Join-Path $installRoot 'SSMV.exe')))
    try {
        Assert-True ($reader.ReadUInt16() -eq 0x5A4D) 'Installed executable has no DOS signature.'
        $reader.BaseStream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        $reader.BaseStream.Position = $peOffset
        Assert-True ($reader.ReadUInt32() -eq 0x00004550) 'Installed executable has no PE signature.'
        $machine = $reader.ReadUInt16()
    } finally { $reader.Dispose() }
    $expectedMachine = switch ($architecture.ToString()) { 'X64' { 0x8664 }; 'Arm64' { 0xAA64 }; default { throw "Unsupported native test architecture: $architecture" } }
    Write-Host ('Installed SSMV.exe PE machine=0x{0:X4}; expected native machine=0x{1:X4}' -f $machine, $expectedMachine)
    Assert-True ($machine -eq $expectedMachine) 'Installed app does not match the native OS architecture.'
    Assert-Registration
    Assert-ForeignState
    if ($FullReaderSmoke) {
        & (Join-Path $PSScriptRoot 'smoke-test.ps1') -Executable (Join-Path $installRoot 'SSMV.exe')
        if (!$?) { throw 'Full reader smoke failed for the installed application.' }
        Write-Host 'Full reader smoke passed for the installed native application.'
    }
    [IO.File]::WriteAllText($unrelated, 'Preserve unrelated files.')
    Run-Installer $installerPath '/S' $true
    Assert-Registration
    Assert-ForeignState
    Assert-True ((Get-Content $unrelated -Raw) -eq 'Preserve unrelated files.') 'Reinstall removed an unrelated file.'
    Write-Host 'Silent install, reinstall, app-local runtime, and registration checks passed.'

    $document = Join-Path $fixture 'Explorer activation 한글 document.md'
    [IO.File]::WriteAllText($document, "# Explorer activation`n`nOpened by the registered shell verb.", [Text.UTF8Encoding]::new($false))
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $document
    $start.UseShellExecute = $true
    $start.Verb = 'SSMV'
    $target = [Diagnostics.Process]::Start($start)
    Assert-True ($null -ne $target) 'The registered shell verb did not return an application process.'
    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 200
        $target.Refresh()
        Assert-True (!$target.HasExited) 'SSMV exited during Explorer activation.'
        if ($target.MainWindowTitle -eq 'Explorer activation 한글 document.md — SSMV') { break }
    } while ((Get-Date) -lt $deadline)
    Assert-True ($target.MainWindowTitle -eq 'Explorer activation 한글 document.md — SSMV') "Explorer activation did not open the expected file: $($target.MainWindowTitle)"
    Assert-True ($target.Path -eq (Join-Path $installRoot 'SSMV.exe')) 'The Explorer verb launched a different application path.'
    Write-Host 'Explorer SSMV verb opened the Korean filename with spaces.'
    Run-Installer $installerPath '/S' $false
    # _?= suppresses NSIS's detached temporary copy so the guard exit code is observable.
    Run-Installer $uninstaller ('/S _?=' + $installRoot) $false
    Assert-Registration
    Assert-True ($target.CloseMainWindow()) 'Could not close the installed application normally.'
    Assert-True ($target.WaitForExit(10000)) 'Installed application did not exit.'
    Assert-True ($target.ExitCode -eq 0) 'Installed application exited unsuccessfully.'
    $target = $null
    Write-Host 'Running-application install and uninstall guards passed.'

    Run-Installer $uninstaller '/S' $true
    $deadline = (Get-Date).AddSeconds(30)
    do {
        $remaining = @($ownedKeys | Where-Object { Test-Path $_ })
        if (!$remaining.Count -and !(Test-Path (Join-Path $installRoot 'SSMV.exe')) -and !(Test-Path $uninstaller)) { break }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    foreach ($key in $ownedKeys) { Assert-True (!(Test-Path $key)) "Uninstall left an owned registry key: $key" }
    $registered = Get-Item $registeredApplications -ErrorAction SilentlyContinue
    Assert-True (!$registered -or !$registered.GetValueNames().Contains('SSMV')) 'Uninstall left its RegisteredApplications value.'
    Assert-True (!(Test-Path (Join-Path $installRoot 'SSMV.exe'))) 'Uninstall left the app executable.'
    Assert-True (!(Test-Path $uninstaller)) 'Uninstall left its executable.'
    foreach ($extension in $extensions) {
        $key = Get-Item "$classes\$extension\OpenWithProgids"
        Assert-True (!$key.GetValueNames().Contains('SSMV.Markdown')) "Uninstall left its Open With value: $extension"
    }
    Assert-ForeignState
    Assert-True ((Get-Content $unrelated -Raw) -eq 'Preserve unrelated files.') 'Uninstall removed an unrelated file.'
    Write-Host 'Uninstall removed owned files and registrations while preserving user data and foreign associations.'
} finally {
    if ($target) { $target.Refresh(); if (!$target.HasExited) { $target.Kill(); $target.WaitForExit() } }
    $env:SSMV_DATA_DIR = $previousDataDirectory
    # Restore only the values seeded by this test; never recursively erase classes or user data.
    foreach ($entry in $seeded) {
        $key = Get-Item $entry.Path -ErrorAction SilentlyContinue
        if ($key) {
            if ($entry.HadDefault) { $key.SetValue('', $entry.Default, $entry.Kind) }
            elseif ($key.GetValue('') -eq $foreignProgId) { $key.DeleteValue('', $false) }
        }
        $openWith = Get-Item ($entry.Path + '\OpenWithProgids') -ErrorAction SilentlyContinue
        if ($openWith) { $openWith.DeleteValue($foreignProgId, $false) }
    }
    foreach ($file in @($unrelated, $dataSentinel)) { if (Test-Path $file) { Remove-Item -LiteralPath $file -Force } }
    if (Test-Path $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    if ((Test-Path $installRoot) -and !(Get-ChildItem $installRoot -Force)) { Remove-Item $installRoot }
    Stop-Transcript > $null
}
