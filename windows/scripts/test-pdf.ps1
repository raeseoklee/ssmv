param([string]$OutputDirectory = "$PSScriptRoot/../../.build/windows-pdf-tests")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path $OutputDirectory).Path
$test = Join-Path $OutputDirectory 'PdfExportTests.exe'
# Run from an MSVC developer shell. Windows SDK C++/WinRT and the system PDF
# printer are the only runtime requirements; no downloaded PDF library is used.
& cl.exe /nologo /std:c++20 /EHsc /W4 /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX /DWIN32_LEAN_AND_MEAN "/Fe:$test" "/Fo:$OutputDirectory/" `
    "$root/Tests/PdfExportTests.cpp" "$root/App/PdfExport.cpp" "$root/Core/Markdown.cpp" /link windowsapp.lib gdi32.lib winspool.lib ole32.lib
if ($LASTEXITCODE -ne 0) { throw "PDF test compilation failed with exit code $LASTEXITCODE." }
& $test $OutputDirectory
if ($LASTEXITCODE -ne 0) { throw "PDF export tests failed with exit code $LASTEXITCODE. Ensure Microsoft Print to PDF is enabled in Windows Features." }
