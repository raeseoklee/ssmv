param(
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [ValidateSet('x64', 'ARM64')][string]$Platform = 'x64'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (!(Test-Path $vswhere)) { throw 'Install Visual Studio 2022 with Desktop development with C++ and Windows SDK 10.0.19041 or newer.' }
$msbuild = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if (!$msbuild) { throw 'MSBuild was not found.' }
& $msbuild (Join-Path $projectRoot 'SSMV.vcxproj') /restore /m /p:Configuration=$Configuration /p:Platform=$Platform
if ($LASTEXITCODE -ne 0) { throw "Windows build failed ($LASTEXITCODE)." }
Write-Output "Built dist/windows/$Platform/$Configuration/SSMV.exe. Keep the entire output directory together."

# Preserve dependency provenance beside development binaries, including transitive notices.
$assets = Get-Content (Join-Path $projectRoot 'obj/project.assets.json') -Raw | ConvertFrom-Json
$output = Join-Path (Split-Path $projectRoot -Parent) "dist/windows/$Platform/$Configuration"
foreach ($library in $assets.libraries.PSObject.Properties) {
    if ($library.Value.type -ne 'package') { continue }
    foreach ($folder in $assets.packageFolders.PSObject.Properties.Name) {
        $package = Join-Path $folder $library.Value.path
        if (!(Test-Path $package)) { continue }
        $noticeRoot = Join-Path $output ('ThirdPartyLicenses/' + $library.Name)
        Get-ChildItem $package -Recurse -File | Where-Object {
            $_.Name -match '^(?i:license|notice|thirdparty|third-party|copyright)' -or $_.Extension -eq '.nuspec'
        } | ForEach-Object {
            $relative = [System.IO.Path]::GetRelativePath($package, $_.FullName)
            $destination = Join-Path $noticeRoot $relative
            New-Item -ItemType Directory -Force (Split-Path $destination -Parent) > $null
            Copy-Item $_.FullName $destination
        }
        break
    }
}
