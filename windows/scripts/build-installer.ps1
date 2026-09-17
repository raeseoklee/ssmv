param(
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [ValidateSet('x64', 'ARM64')][string]$Platform = 'x64',
    [string]$Makensis
)
$ErrorActionPreference = 'Stop'
if ($Configuration -ne 'Release') { throw 'Only Release binaries may be redistributed.' }
$repository = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source = Join-Path $repository "dist/windows/$Platform/$Configuration"
if (!(Test-Path (Join-Path $source 'SSMV.exe'))) { throw 'Build the Release app with build.ps1 before packaging.' }
if (!$Makensis) {
    $command = Get-Command makensis.exe -ErrorAction SilentlyContinue
    if ($command) { $Makensis = $command.Source }
    else { $Makensis = Join-Path ${env:ProgramFiles(x86)} 'NSIS/makensis.exe' }
}
if (!(Test-Path -LiteralPath $Makensis)) { throw 'Install NSIS 3.12, or pass -Makensis with its executable path.' }
$nsisVersion = (& $Makensis /VERSION | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $nsisVersion -notmatch '^v3\.12(?:\D|$)') { throw "NSIS 3.12 is required; found '$nsisVersion'." }

$stage = Join-Path $repository "windows/.build/installer/$Platform"
if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
$payload = Join-Path $stage 'payload'
New-Item -ItemType Directory -Force $payload > $null
if (Get-ChildItem -LiteralPath $source -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
    throw 'The app payload must not contain symbolic links or junctions.'
}
Copy-Item -Path (Join-Path $source '*') -Destination $payload -Recurse
Copy-Item (Join-Path $repository 'LICENSE'), (Join-Path $repository 'THIRD_PARTY_NOTICES.md'), (Join-Path $repository 'windows/README.md') $payload
Copy-Item (Join-Path $repository 'Examples/Windows.md') $payload

# Only use Microsoft's designated redistributable directory, never System32 or
# a developer's debug runtime. App-local DLLs keep this a per-user installation.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (!(Test-Path $vswhere)) { throw 'Visual Studio 2022 redistributable files were not found.' }
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$visualStudio) { throw 'Visual Studio C++ build tools are required for packaging.' }
$redistRoot = Join-Path $visualStudio 'VC/Redist/MSVC'
$crt = Get-ChildItem -LiteralPath $redistRoot -Directory | Where-Object { $_.Name -match '^14\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending | ForEach-Object {
        $candidate = Join-Path $_.FullName ($Platform.ToLowerInvariant() + '/Microsoft.VC143.CRT')
        if (Test-Path $candidate) { $candidate }
    } | Select-Object -First 1
if (!$crt) { throw "Release VC143 CRT files for $Platform were not found in Visual Studio's redist directory." }
$runtimeFiles = @(Get-ChildItem -LiteralPath $crt -Filter '*.dll' -File)
foreach ($required in @('msvcp140.dll', 'vcruntime140.dll')) {
    if ($required -notin $runtimeFiles.Name) { throw "Missing redistributable runtime: $required" }
}
foreach ($file in $runtimeFiles) { Copy-Item -LiteralPath $file.FullName -Destination $payload }
$runtimeFiles | ForEach-Object {
    [ordered]@{ file = $_.Name; version = $_.VersionInfo.FileVersion; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $payload 'VC-RUNTIME-PROVENANCE.json') -Encoding utf8

function Quote-Nsis([string]$Value) { return '"' + $Value.Replace('$', '$$').Replace('"', '$\"') + '"' }
$files = @(Get-ChildItem -LiteralPath $payload -Recurse -File | Sort-Object FullName)
$install = [Collections.Generic.List[string]]::new()
$uninstall = [Collections.Generic.List[string]]::new()
$install.Add('!macro InstallPayload')
$uninstall.Add('!macro UninstallPayload')
$uninstall.Add('  StrCpy $R9 0')
foreach ($file in $files) {
    $relative = [IO.Path]::GetRelativePath($payload, $file.FullName)
    $directory = [IO.Path]::GetDirectoryName($relative)
    $target = if ($directory) { '$INSTDIR\' + $directory } else { '$INSTDIR' }
    # $INSTDIR is intentional NSIS syntax; escape only generated path components.
    $install.Add('  SetOutPath "' + $target.Replace('$INSTDIR', '').Replace('$', '$$').Insert(0, '$INSTDIR') + '"')
    $install.Add('  File ' + (Quote-Nsis $file.FullName))
    $uninstall.Add('  IfFileExists "$INSTDIR\' + $relative.Replace('$', '$$').Replace('"', '$\"') + '" 0 +5')
    $uninstall.Add('  ClearErrors')
    $uninstall.Add('  Delete "$INSTDIR\' + $relative.Replace('$', '$$').Replace('"', '$\"') + '"')
    $uninstall.Add('  IfErrors 0 +2')
    $uninstall.Add('  StrCpy $R9 1')
}
Get-ChildItem -LiteralPath $payload -Directory -Recurse | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
    $relative = [IO.Path]::GetRelativePath($payload, $_.FullName)
    $uninstall.Add('  RMDir "$INSTDIR\' + $relative.Replace('$', '$$') + '"')
}
$install.Add('!macroend'); $uninstall.Add('!macroend')
$installInclude = Join-Path $stage 'install-files.nsh'
$uninstallInclude = Join-Path $stage 'uninstall-files.nsh'
[IO.File]::WriteAllLines($installInclude, $install, [Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllLines($uninstallInclude, $uninstall, [Text.UTF8Encoding]::new($true))
[xml]$manifest = Get-Content (Join-Path $repository 'windows/app.manifest') -Raw
$version = $manifest.assembly.assemblyIdentity.version
$revision = (& git -C $repository rev-parse --short HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $revision -notmatch '^[0-9a-f]+$') { throw 'A source Git revision is required for development installer provenance.' }
$output = Join-Path $repository "dist/SSMV-windows-$Platform-setup.exe"
$arguments = @('/V3', '/INPUTCHARSET', 'UTF8', "/DPAYLOAD_DIR=$payload", "/DOUTPUT_FILE=$output", "/DPRODUCT_VERSION=$version",
    "/DBUILD_LABEL=development.$revision", "/DARCH=$Platform", "/DINSTALL_FILES=$installInclude", "/DUNINSTALL_FILES=$uninstallInclude",
    (Join-Path $repository 'windows/Installer/SSMV.nsi'))
& $Makensis @arguments
if ($LASTEXITCODE -ne 0) { throw "NSIS compilation failed ($LASTEXITCODE)." }
[ordered]@{ commit = (& git -C $repository rev-parse HEAD).Trim(); architecture = $Platform; nsis = $nsisVersion;
    file = [IO.Path]::GetFileName($output); sha256 = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash } |
    ConvertTo-Json | Set-Content -LiteralPath ($output + '.json') -Encoding utf8
Write-Output "Built $output"
