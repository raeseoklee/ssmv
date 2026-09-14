# SSMV — So Simple Markdown Viewer

[한국어](docs/README.ko.md)

SSMV is a native, read-only Markdown viewer for **macOS 13 and later**. Open local Markdown files from Finder, keep several documents in a collapsible sidebar, and export a document as PDF. Built with Swift and AppKit, it uses no web view, background server, or third-party packages.

![SSMV displaying Markdown with its document sidebar](docs/images/ssmv.png)

## Install

```sh
brew install --cask raeseoklee/tap/ssmv
open -a SSMV
```

Or download the Universal app for Apple Silicon and Intel from [GitHub Releases](https://github.com/raeseoklee/ssmv/releases). Unzip it and move `SSMV.app` to Applications.

**Release signing:** Version 0.1.5 is ad-hoc signed, not Developer ID signed or notarized by Apple. The Homebrew cask verifies the archive checksum and bundle signature, then removes quarantine from SSMV.app so it can launch. This bypasses Gatekeeper’s first-launch check for this app; it does not add Apple notarization. A manually downloaded copy may still be blocked. Review [Apple’s guidance for opening apps from unidentified developers](https://support.apple.com/en-gb/102445) before deciding whether to open it. You can also [build from source](#build-from-source).

Open SSMV once after Homebrew installation to register it for Finder’s **Open With** menu.
If an older installation is missing from that menu, refresh the tap and reinstall:

```sh
brew update
brew reinstall --cask raeseoklee/tap/ssmv
open -a SSMV
```

## Use

Open `.md`, `.markdown`, or `.mdown` files with **Finder → Open With → SSMV**, or press **⌘O** in the app. To use SSMV on double-click, select a Markdown file in Finder, choose **Get Info → Open with → SSMV → Change All…**. SSMV does not change your default app automatically.

- Add multiple documents with **⌘O**, the **+** button, or drag and drop onto the sidebar.
- Select a document to read it; collapse the sidebar when you need more space.
- Remove a document with **−**, its context menu, or **⌘⌫**. This removes only the sidebar entry; it never deletes the source file.
- The document list, selection, sidebar visibility, and appearance persist between launches. File paths are saved; moved or deleted files must be reopened.
- Choose **View → System Appearance**, **Light**, or **Dark**.
- In full screen (**⌃⌘F**), the title and toolbar hide automatically. Move the pointer to the top edge to reveal them.
- Choose **File → Export as PDF…** to save the selected document as a paginated A4 PDF with a white background, independent of the screen theme or text size. A separate progress window shows the current stage and offers **Cancel**; you can keep reading or switch documents during export.

## Markdown support

SSMV renders headings, paragraphs, emphasis, strikethrough, lists, block quotes, code blocks, tables, and links. Web links open in your default browser; relative Markdown links open in the sidebar. UTF-8 text, including Korean and emoji, is supported. Files are limited to 16 MiB.

Images, HTML rendering, Mermaid diagrams, mathematical notation, syntax highlighting, interactive checkboxes, and in-document anchor navigation are not supported. Parsing uses Foundation Markdown and does not promise full GitHub rendering compatibility. These same limits apply to PDF export.

Files are read and parsed in the background. After parsing, text appears in cancellable batches and the visible region is laid out on demand. You can switch documents while loading; at most two parsers run at once. An in-progress Foundation parse cannot be interrupted, so new work may wait if both are busy.

Very large paragraphs, tables, finding distant text, and PDF export can still take time. PDF export becomes available when text construction finishes. There is no automatic file watching: use **⌘R** to reload changes.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Open documents | ⌘O |
| Find | ⌘F |
| Copy / Select all | ⌘C / ⌘A |
| Export as PDF | ⇧⌘E |
| Toggle sidebar | ⌃⌘S |
| Remove from sidebar | ⌘⌫ |
| Reload | ⌘R |
| Increase / Decrease / Reset text size | ⌘+ / ⌘− / ⌘0 |
| Full screen | ⌃⌘F |
| Close window / Quit | ⌘W / ⌘Q |

⌘ = Command, ⇧ = Shift, ⌃ = Control. App-defined shortcuts do not require Fn. macOS may display 🌐 for Fn in system-managed menus; **Help → Keyboard Shortcuts…** explains these symbols. System-owned menu labels may differ by macOS version.

## Build from source

Requires macOS 13 or later and Xcode or Command Line Tools with **Swift 6 or later**.

```sh
git clone https://github.com/raeseoklee/ssmv.git
cd ssmv
scripts/build-app.sh
open dist/SSMV.app
```

Use `UNIVERSAL=1 scripts/build-app.sh` to build for both Apple Silicon and Intel. Local builds are ad-hoc signed. See [CONTRIBUTING.md](CONTRIBUTING.md) for checks and contribution guidelines.

## FAQ

**Can SSMV edit Markdown?** No. It is a viewer. Edit the source in your preferred editor, then reload it in SSMV.

**Are documents uploaded?** SSMV reads local files and has no document-upload service or analytics. Opening a web link hands its URL to your default browser.

**Does removing a sidebar entry delete my file?** No. Your original document stays on disk.

## Project

- Source and issues: [raeseoklee/ssmv](https://github.com/raeseoklee/ssmv)
- Homebrew tap: [raeseoklee/homebrew-tap](https://github.com/raeseoklee/homebrew-tap)
- Release notes: [CHANGELOG.md](CHANGELOG.md)
- License: [MIT](LICENSE). The app icon was created with an AI image-generation tool; its prompt is included in [Resources/AppIcon-prompt.txt](Resources/AppIcon-prompt.txt).

- [Security](SECURITY.md) · [Publication review](docs/COMPLIANCE.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)

- Performance measurements: [PERFORMANCE.md](docs/PERFORMANCE.md)
