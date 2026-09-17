# Windows feature parity

[한국어](WINDOWS-PARITY.ko.md) · [Windows build](../windows/README.md)

This checklist compares the Windows port with the implemented macOS app, not with
every feature in the Markdown specification. It includes the current reading and
session increment and native menu/tree redesign. **Implemented; interaction checks pending** means code exists, with broader
manual acceptance checks still required. The verified native scope is listed below. The Windows app remains a development build.

The Windows window uses File/Edit/View menus with visible Ctrl-based shortcuts,
a native document tree and compact add/remove/outline controls beside Documents.
Appearance is selected under View. URL opening, PDF export and transient navigation highlights are also implemented;
remaining limitations are tracked below.

## Reading and document library

| Capability | Windows status | Acceptance criteria |
| --- | --- | --- |
| Local files | Present; native interaction checks pending | Picker, arguments and Explorer/desktop drops accept multiple supported UTF-8 files, Korean paths and spaces; reject directories, invalid UTF-8 and files over 16 MiB. Duplicate opens select the existing entry. |
| Sidebar and outline | Native tree implemented; broader checks pending | Collapse the sidebar, toggle the outline and jump to nested headings without changing document order or selection. Preserve heading navigation across document parts. |
| Remove documents | Present; native interaction checks pending | Remove one entry or confirm removal of all entries; cancellation preserves the list and no action deletes an original file. |
| Sorting | Partial | Offer added order, name and most recently modified, with stable ties and selection. The baseline offers name ascending/descending only. |
| Block Markdown | Partial | Compare shared fixtures for headings, paragraphs, nested lists, block quotes, rules and fenced code; preserve ordered-list numbering. |
| Inline Markdown and tables | Implemented; interaction checks pending | Verify emphasis, strong text, strikethrough, inline code, escaped syntax, links and table alignment against macOS fixtures. Links must follow the source-aware navigation policy. |
| Find, text size and copy | Implemented; interaction checks pending | Current find navigates matching blocks across parts, not individual occurrences, and briefly highlights the target section. Large tables retain separate page navigation. Text size controls and full-document plain-text copy exist; selection remains per block. Continuous selection and occurrence-level find are gaps. |
| Reload and save a copy | Implemented; interaction checks pending | Explicitly reload changed files; saving preserves source bytes, including BOM, rather than rendered text. Cancelling a picker changes nothing. |
| Themes and session recovery | Implemented; interaction checks pending | Restore the selected document, shelf, theme and outline/sidebar preferences after restart; handle missing files and damaged state without silently discarding recoverable data. Per-document page/scroll restoration is implemented but requires native verification. |
| Reveal file and full screen | Implemented; interaction checks pending | Reveal local sources in Explorer. Use F11 for full screen, with a recoverable way to access controls and exit. In-app controls currently remain visible; macOS-style hover-reveal behavior is still missing. |

The macOS renderer does not fetch and display embedded image pixels. Image
rendering is therefore not a Windows parity requirement; retain readable fallback
text and do not introduce unsolicited network requests. Neither app is a Markdown
editor. The current Windows part-based view is not continuous viewport
virtualization; matching appearance alone does not establish performance parity.

## Input, export and distribution

| Capability | Windows status | Acceptance criteria |
| --- | --- | --- |
| Clipboard Markdown | Implemented; interaction checks pending | Import valid text into durable app-managed storage, preserve it across restart and keep source removal separate from permanent deletion. Enforce the 16 MiB input limit. |
| Imported-document management | Pending | List retained imports, save copies and explicitly delete retained content. Removing from the sidebar must not delete it. The current clipboard path preserves unlisted imports and limits storage to 256 MiB, but has no management UI. Bound storage and recover after interrupted writes. |
| HTTPS Markdown | Implemented; verification in progress | Support raw HTTPS and GitHub file URLs; reject credentials and unsupported content, bound downloads/redirects/timeouts, support cancellation, and retain cached documents for offline reopening. Preserve safe relative-link resolution. |
| LLM/CLI handoff | Partial; native checks pending | File arguments and single-instance forwarding are implemented. Forwarded arguments must be absolute; relative arguments are rejected on warm launch. HTTPS, UTF-8 stdin and optional titles remain pending. Bound and validate the private inbox, recover pending requests and prevent duplicate imports. Document exit codes and PowerShell usage. No MCP server is required. |
| PDF export | Partial; verification in progress | Export a snapshot of the selected document with readable pagination, tables, links and Unicode; verify output visually. Cancellation, document switching and output errors must not corrupt or mix documents. |
| File associations | Pending | A supported install registers `.md`, `.markdown` and `.mdown` for Explorer **Open with** and double-click after user selection. Uninstall removes only SSMV's registrations. |
| Update guidance | Pending | Choose a Windows distribution channel before implementing checks. Notify without silently replacing the app; do not direct Windows users to Homebrew. The macOS app continues to use its tap and Homebrew upgrade guidance. |
| Help and About | Pending | Provide product identity, version and Windows shortcuts; keep English default documentation with a separate Korean link. |

Windows uses native equivalents: Ctrl+O, Ctrl+F, Ctrl+C and Ctrl+A replace
the corresponding macOS Command shortcuts; F11 is the full-screen target.
Do not copy macOS-only Fn or globe-key labels into Windows menus.

## Verification gates

- [ ] Shared fixture comparisons cover Markdown, outline ordering, Unicode and malformed input.
- [x] Windows x64 and ARM64 builds pass; native runtime evidence identifies the tested architecture.
- [ ] A Windows desktop check covers Explorer drops, pickers, focus, keyboard use, display scaling, Narrator, light/dark mode and restart recovery.
- [ ] Measure startup, first readable content, memory, CPU and responsiveness using the same document corpus, including 15 MiB documents. A size limit is not a speed guarantee.
- [ ] Check external-link handling, private import storage, network limits and third-party licenses before public distribution.
- [ ] Rerun macOS regression tests after changes to shared build or repository structure.

At `6c0d9c3`, three portable suites, x64/ARM64 builds and the
[native x64 smoke test](https://github.com/raeseoklee/ssmv/actions/runs/35187903182) pass.
The native checks cover opening View immediately after launch, expanded-tree order,
repeated heading navigation, Ctrl+F search (match/no match), text-size increase and
decrease, sidebar/outline toggles, Dark appearance, two-document cold/warm opening,
and selection/preference restoration after restart. Light, Dark and menu captures
were visually reviewed. These checks do not establish complete macOS parity,
cover every native interaction or verify ARM64 runtime behavior.

PDF requires Microsoft Print to PDF; inline emphasis and clickable annotations are not retained.
Next priorities are durable import management, CLI delivery and installation integration. Publish feature
claims only after their corresponding checks pass; documentation changes alone do
not require a new application version.
