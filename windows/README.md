# SSMV for Windows

[한국어](README.ko.md) · [Project overview](../README.md)

The Windows port uses C++20, C++/WinRT and WinUI 3. It is a development build,
not a published release or a replacement for the macOS app. It uses native text
controls; there is no embedded browser or background server.

## Build

On Windows, install Visual Studio 2022 with **Desktop development with C++**,
the Windows SDK (10.0.19041 or newer), and C++ ARM64 build tools if targeting ARM64.
NuGet restores the pinned Microsoft Windows App SDK and C++/WinRT packages.

```powershell
./windows/scripts/build.ps1
./windows/scripts/build.ps1 -Platform ARM64
```

You can also open `SSMV.vcxproj` in Visual Studio. Output goes to
`dist/windows/<architecture>/Release/` at the repository root. Keep that entire
folder together: this is an unpackaged, self-contained Windows App SDK app, not
a standalone executable. The matching Microsoft Visual C++ Redistributable is
required. Builds are unsigned; installation and signing are not configured yet.

## Initial scope

- Open local `.md`, `.markdown` and `.mdown` files with the picker, file arguments,
  or drag and drop.
- Switch documents in a collapsible sidebar; browse headings, sort by name, and
  remove individual entries or clear the list after confirmation.
- Display headings, paragraphs, lists, quotes, separators and fenced code using
  native controls, with system, light and dark themes.
- Read UTF-8 files up to 16 MiB. Removing entries never deletes source files.

This first renderer is a Markdown subset. Full inline formatting, tables, images,
PDF export, remote URLs, LLM/CLI handoff, session persistence, installer file
associations and automatic update checks remain porting work. The macOS version
continues to provide its existing features. Do not use the 16 MiB input limit as a
performance guarantee; Windows large-document measurements are still required.

## Tests

The parser and document library have no Windows UI dependencies. Run their tests
on macOS, Windows or Linux:

```sh
cmake -S windows -B windows/.build/core
cmake --build windows/.build/core --config Release
ctest --test-dir windows/.build/core -C Release --output-on-failure
```

GitHub Actions builds the Windows app for x64 and ARM64 and runs core tests.
A successful compile does not validate native interaction: before a release,
check file-picker cancellation, Explorer and desktop drops, Korean paths, keyboard
navigation, sidebar/outline behavior, theme switching, display scaling, Narrator,
and large-document responsiveness on a Windows machine.

## Layout

- `App/`: WinUI application and native document UI.
- `Core/`: portable parser and document library.
- `Tests/`: core regression tests.
- `scripts/build.ps1`: Windows build entry point.

The Windows and macOS apps share project documentation and example documents,
not platform UI code. See [Microsoft's deployment documentation](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/unpackage-winui-app)
for the unpackaged deployment model.
