# SSMV for Windows

[한국어](README.ko.md) · [Project overview](../README.md)

The Windows port uses C++20, C++/WinRT and WinUI 3. It is a development build,
not a published release or a replacement for the macOS app. It uses native text
controls; there is no embedded browser or background server.

![SSMV Windows development build reading a local Markdown document](../docs/images/ssmv-windows-native-ui.png)

Native x64 interface at `6c0d9c3`. [Dark appearance](../docs/images/ssmv-windows-native-ui-dark.png) ·
[Menu shortcuts](../docs/images/ssmv-windows-native-ui-menu.png)

## Install and open from Explorer

Use `SSMV-windows-x64-setup.exe` on an x64 PC or
`SSMV-windows-ARM64-setup.exe` on an ARM64 PC. These are unsigned development
installers for Windows 10 build 19041 or newer, including Windows 11. Check
**Settings → System → About → System type** to choose the architecture. These are
not a published Windows release. Windows may display an unknown
publisher warning.

Close SSMV before installing or upgrading, then run the installer under your normal
Windows account. It installs for that account without administrator privileges to
`%LOCALAPPDATA%\Programs\SSMV` and adds a Start menu shortcut. The installer
includes the Windows App SDK files and app-local Microsoft Visual C++ runtime;
no separate Visual C++ download is needed for this installation.

After installation, right-click a `.md`, `.markdown` or `.mdown` file and select
**Open with SSMV**. On Windows 11, this command may appear under **Show more options**.
SSMV also appears in **Open with**. To open files by double-clicking, choose SSMV
as the default app yourself through Windows **Open with** or **Settings → Apps →
Default apps**. Setup does not replace your current default or modify `UserChoice`.

Run a newer installer to update the installed copy. To remove it, use Windows
**Settings → Apps → Installed apps → So Simple Markdown Viewer → Uninstall**. Uninstall removes the
installed app, shortcuts and SSMV's file registrations. It preserves original
Markdown files and `%LOCALAPPDATA%\SSMV`, including the document list, preferences,
imports and remote cache. Other applications' registrations remain intact.

## Build

On Windows, install Visual Studio 2022 with **Desktop development with C++**,
the Windows SDK (10.0.19041 or newer), and C++ ARM64 build tools if targeting ARM64.
NuGet restores the pinned Windows App SDK WinUI component and C++/WinRT packages.
The project references the UI component directly to avoid unused AI/ML components.

```powershell
./windows/scripts/build.ps1
./windows/scripts/build.ps1 -Platform ARM64
```

You can also open `SSMV.vcxproj` in Visual Studio. Output goes to
`dist/windows/<architecture>/Release/` at the repository root. Keep that entire
folder together: this is an unpackaged, self-contained Windows App SDK app, not
a standalone executable. The matching Microsoft Visual C++ Redistributable is
required for this portable output. Builds are unsigned.

To build an installer, install [NSIS 3.12](https://nsis.sourceforge.io/Download)
and build the app first:

```powershell
./windows/scripts/build.ps1 -Platform x64
./windows/scripts/build-installer.ps1 -Platform x64
# Use -Platform ARM64 for both commands when building the ARM64 installer.
```

Output is `dist/SSMV-windows-<architecture>-setup.exe` at the repository root.
The installer build stages a separate copy of the app with matching release CRT
DLLs from Visual Studio's redistributable directory. It does not change the portable
build's runtime prerequisites. See [third-party notices](../THIRD_PARTY_NOTICES.md)
for the runtime and installer license sources.

## Reading features

See the [parity checklist](../docs/WINDOWS-PARITY.md) for remaining work and the
verification boundaries of this development build.

The window uses **File**, **Edit** and **View** menus, with shortcuts shown beside
commands. **View → Appearance** selects System, Light or Dark. The sidebar uses a
native document tree with document icons and nested headings. Compact add, remove
and outline buttons sit beside **Documents**; hover over an icon for its label and
shortcut. Right-click the remove button for **Remove All Documents…**.

- Jump from the outline or an in-document anchor to a briefly highlighted section.
- Open local `.md`, `.markdown` and `.mdown` files through a picker, arguments or
  drops. Forward absolute file paths to the running app. Relative arguments work
  on a cold launch but are rejected when forwarding to an existing instance.
- Switch documents in a collapsible sidebar, browse headings, sort by name and
  remove entries. Clearing the list requires confirmation and never deletes sources.
- Read headings, lists, quotes, code, emphasis, strikethrough, links and aligned
  tables with native text controls. This remains a Markdown subset.
- Find matching **sections** with Ctrl+F and F3/Shift+F3. Search navigates between
  blocks; it does not highlight or count individual occurrences. Large tables may
  require their own page controls after navigating to the table.
- Change text size with Ctrl++/Ctrl+- and reset with Ctrl+0. Selection is per block;
  **Edit → Copy Document Text** copies the full document's plain text.
- Reload with Ctrl+R, save the original Markdown bytes with Ctrl+Shift+S, reveal
  a file in Explorer and enter/leave full screen with F11.
- Import Markdown with **File → Open from Clipboard**, and restore the shelf, selected document,
  reading position, expanded outlines, text size and appearance on restart.

Windows uses Ctrl for common commands that use Command on macOS. The menus show
the full shortcut list; these are useful starting points:

| Action | Shortcut |
| --- | --- |
| Open files | Ctrl+O |
| Open Markdown URL | Ctrl+L |
| Export PDF | Ctrl+P |
| Open clipboard Markdown | Ctrl+Shift+V |
| Find | Ctrl+F |
| Save a copy | Ctrl+Shift+S |
| Full screen | F11 |

## URL documents and PDF export

[File menu](../docs/images/ssmv-windows-file-menu.png) · [Outline navigation highlight](../docs/images/ssmv-windows-outline-highlight.png)

Use **File → Open URL…** (Ctrl+L) for a raw HTTPS Markdown URL or a GitHub
`blob` file URL. Downloads accept UTF-8 text up to 16 MiB, follow at most five
HTTPS redirects and enforce network timeouts. Credentials and HTML responses are
rejected. Cached documents reopen offline; **Reload** fetches the source again.
Relative links resolve against the remote source, never the cache directory.
The remote cache lives under `%LOCALAPPDATA%\SSMV\remotes` with a 256 MiB limit.
Removing a document from the sidebar preserves its cached file.

Use **File → Export PDF…** (Ctrl+P) to save the complete selected document,
including parts outside the visible page. The export captures a snapshot before
showing the save dialog. **File → Cancel Current Operation** cancels a download
or export. Cancelling an export preserves an existing destination file.

PDF export requires **Microsoft Print to PDF** in Windows Features. It creates
light-background pages with Unicode text, headings, lists, code and tables.
Safe web/email destinations appear as text; clickable PDF links and inline
emphasis are not retained. Tables too wide for readable cells report an error.
PDF formatting is not yet identical to macOS.

UTF-8 input is limited to 16 MiB. Clipboard imports are stored under
`%LOCALAPPDATA%\SSMV\imports` with a 256 MiB total limit. Removing them from the
sidebar preserves those files; an in-app retained-import manager is not yet available.
Imported text cannot open local-file links; save a copy to give it a local folder.
Session data is stored alongside them. If session recovery fails, the app reports
an error and disables automatic session writes to protect the existing state.

The body displays at most 2,000 blocks per part; outlines show 200 headings per
part. Tables display 100 body rows and 12 columns at a time, with navigation for
the remainder. Parsed documents remain in memory. These bounds do not establish
large-document performance parity; continuous viewport virtualization is pending.

Remote URL CLI arguments, stdin/title CLI delivery, imported-document
management, added/modified sorting, update guidance
and Help/About remain incomplete. Web hyperlinks open in the default browser;
that is different from loading remote Markdown into SSMV. Neither platform fetches
embedded image pixels or provides Markdown editing. Windows full screen currently
retains its in-app controls; matching macOS hover-reveal behavior remains work.

## Tests

The parser and document library have no Windows UI dependencies. Run their tests
on macOS, Windows or Linux:

```sh
cmake -S windows -B windows/.build/core
cmake --build windows/.build/core --config Release
ctest --test-dir windows/.build/core -C Release --output-on-failure
```

At `bc7892d`, the [Windows validation run](https://github.com/raeseoklee/ssmv/actions/runs/35197022620)
passed five core suites, x64/ARM64 app and installer builds, and the full x64 reader
smoke test on Windows Server 2022 build 20348. Installer lifecycle tests passed on
that x64 host and native ARM64 Windows 11 Enterprise build 26200: install/reinstall,
Start menu shortcut, app-local CRT loading, opening a Korean filename with spaces
through the registered shell command, running-app guards, and uninstall preserving
user data and other applications' associations.

Full Windows 11 reader interaction checks remain pending: the hosted desktop
exposes UI Automation controls but does not reliably give the app foreground focus
for keyboard and popup tests. Windows 11 x64 has not been directly tested.

Installer tests modify the current account's app installation and registrations.
Run them only in a clean, disposable Windows environment:

```powershell
./windows/scripts/test-installer.ps1 -Installer dist/SSMV-windows-x64-setup.exe
# Add -FullReaderSmoke on an interactive desktop to exercise reader interactions.
```

Use the matching ARM64 installer on ARM64. The Windows workflow's manual
`installer_run` input can reuse an existing ARM64 installer for a Windows 11
retest; `full_reader_smoke` opts into the foreground-dependent reader checks.

Before release, validate picker cancellation, Explorer/desktop drops, Korean paths,
keyboard navigation, tables, theme changes, display scaling, Narrator and large-file
responsiveness on Windows. This work does not create a release or change Homebrew.

## Layout

- `App/`: WinUI application and native document UI.
- `Core/`: portable parser and document library.
- `Tests/`: core regression tests.
- `scripts/build.ps1`: Windows build entry point.
- `scripts/build-installer.ps1`: NSIS installer packaging entry point.

The Windows and macOS apps share project documentation and example documents,
not platform UI code. See [Microsoft's deployment documentation](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/unpackage-winui-app)
for the unpackaged deployment model.
