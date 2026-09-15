# Changelog

## 0.3.3 — 2026-09-15

- Use matching size, background, and symbol weight for all three sidebar actions. Restore the original outline glyph and indicate its enabled state with a border that remains visible in inactive windows.

## 0.3.2 — 2026-09-15

- Distinguish outline on/off states with filled and outlined symbols, retaining contrast when the window loses focus.

- Hold the existing minus button for 0.6 seconds to request removal of all sidebar entries. Confirmation is still required; a short click removes only the selected entry.

## 0.3.1 — 2026-09-15

- Clear all sidebar documents from the File menu or sidebar context menu after explicit confirmation. Original files remain on disk; Cancel is the default action.

## 0.3.0 — 2026-09-15

- Check the Homebrew tap at launch, at most daily, and offer copyable upgrade commands when a newer version is available. No automatic download or installation is performed.
- Refresh only the changed document outline and preserve the visible row position during asynchronous heading updates.
- Add regression coverage for concurrent outline loading, displayed file order, and viewport stability.

## 0.2.2 — 2026-09-15

- Align file icons with the filename and disclosure arrow in two-line sidebar rows.

## 0.2.1 — 2026-09-15

- Place the add, remove, and outline controls beside the Documents heading, leaving more vertical space for the file list.

## 0.2.0 — 2026-09-15

- Browse nested document headings beneath each file in the sidebar and click a heading to jump to its location.
- Show or hide document outlines with the View menu or sidebar button; the preference persists across launches.
- Load inactive outlines on expansion, cap each outline at 2,000 headings, and cancel outstanding outline work when disabled or removed.

## 0.1.6 — 2026-09-15

- Clarify the About description and add links to the source repository and MIT license.

## 0.1.5 — 2026-09-14

- Fix Homebrew installation failures caused by sandboxed document registration. Register the app’s own document claims on normal launch and explain the first-launch step.

## 0.1.4 — 2026-09-14

- Register SSMV with Launch Services during Homebrew installation so Finder can list it in Open With before first launch.
- Automatically hide the title and toolbar in full screen; reveal them at the top edge using native macOS controls.

## 0.1.3 — 2026-09-14

- Fix truncated PDF exports when native text layout exceeds 10 million points.
- Keep the app responsive during export with a separate helper and a cancellable progress window.
- Export the loaded document snapshot; preserve existing PDFs on cancellation or failure.
- Wait for export cleanup when closing its window or quitting the app.

## 0.1.2 — 2026-09-14

- Display documents incrementally with on-demand viewport layout.
- Keep cancellation responsive with at most two background parsers.
- Reduce temporary rendering allocations and reuse native table cells across inline formatting.
- Preserve reading positions through repeated zoom and document switches.
- Add large-document benchmarks and regression tests for streaming, cancellation, and scrolling.

## 0.1.1 — 2026-09-14

- Remove the added `(Fn)` suffix from menu titles and use native macOS labels.
- Keep keyboard shortcuts and the Fn explanation in Help and documentation.

## 0.1.0

Initial public release of **SSMV — So Simple Markdown Viewer** for macOS 13 and later.

- Native Swift and AppKit Markdown viewing without third-party packages or a web view.
- Finder document opening for `.md`, `.markdown`, and `.mdown` files.
- Collapsible multi-document sidebar with persistent selection and non-destructive removal.
- System, light, and dark appearances; search, copy, and text-size controls.
- Headings, lists, quotes, code blocks, tables, and links, including relative Markdown links.
- Paginated A4 PDF export with a white print layout.
- Universal Apple Silicon and Intel app distribution through GitHub Releases and `raeseoklee/tap`.

The release is ad-hoc signed and is not Developer ID signed or notarized. See the [README](README.md) for installation guidance and Markdown limitations.
