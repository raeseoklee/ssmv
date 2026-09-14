# Large-document performance

Measured on 2026-09-14 with an Apple M4 Pro, 48 GiB RAM, and macOS 15.7.4.
These are synthetic local measurements, not a guarantee for every document or Mac.

## Opening documents

The baseline is SSMV 0.1.1 (`996b9e1`). Version 0.1.2 parses in the background,
constructs attributed text in cancellable batches, and lays out the viewport on
demand. The old opening path forced layout of the entire document before
returning to the UI. The new path defers offscreen layout, so the columns below
represent different completion points rather than equal amounts of layout work.

| Generated document | 0.1.1 read, render and full layout | 0.1.2 first viewport | 0.1.2 all text constructed | Peak opening RSS, old → new |
| --- | ---: | ---: | ---: | ---: |
| Mixed Markdown, 1 MiB | 1.83 s | 0.75 s | 1.43 s | 105 → 99 MiB |
| Mixed Markdown, 5 MiB | 11.32 s | 3.93 s | 7.72 s | 427 → 357 MiB |
| Mixed Markdown, 15 MiB | 46.16 s | 12.35 s | 26.20 s | 1,136 → 1,028 MiB |
| Many small tables, 250 KiB | 1.03 s | 0.27 s | 0.74 s | 478 → 101 MiB |
| One long paragraph, 1 MiB | 0.74 s | 0.10 s | 0.34 s | 109 → 74 MiB |

The mixed fixture repeats headings, Korean/English prose, emphasis, links,
lists, and fenced code. The table fixture repeats separate small three-column
tables; these results do not characterize one enormous table. Completed cases
retained the final text marker. A 16 MiB file passes the reader's size check;
one byte over is rejected before parsing. The full 16 MiB boundary was not
rendered as part of this check.

## Responsiveness and integration

A main-actor heartbeat requested every 10 ms observed maximum gaps of 39–54 ms
in the 1/5/15 MiB, table, and long-paragraph rendering harness cases. This includes
scheduler delay; it is not a screen refresh-rate or input-latency measurement.
Sustained processing still uses approximately one CPU core.

An additional harness instantiated the actual `ViewerWindow`, sidebar,
scroll view and text view without showing the window:

| Input | First content observed | Construction complete | Maximum heartbeat gap | Whole-process peak RSS |
| --- | ---: | ---: | ---: | ---: |
| Mixed 1 MiB | 0.84 s | 1.54 s | 43 ms | 141 MiB |
| Mixed 5 MiB | 3.90 s | 7.62 s | 45 ms | 415 MiB |
| Tables 250 KiB | 0.28 s | 0.75 s | 34 ms | 136 MiB |

Switching to a small document while one 15 MiB parse was busy completed in
approximately 14 ms. Switching during incremental rendering and repeated zoom
preserved the newly selected document; no stale content was applied. Regression
tests cover cancellation, the two-parser bound, text/Unicode/table preservation,
scroll restoration, PDF pagination, and PDF link filtering.

## Limits

- Parsing already in Foundation cannot be interrupted. At most two parsers run;
  when both are busy, a new request waits. Large files still take time to parse.
- The per-batch work budget is a target, not a hard deadline. A single enormous
  Markdown run, table, AppKit text-storage operation, or distant navigation can
  take longer. A 15 MiB mixed document still needs about 1 GiB of process memory.
- Viewport layout reduces opening memory; it does not remove the cost of laying
  out everything. Forcing full layout of the table fixture still peaked around
  486 MiB. In 0.1.2, PDF export runs synchronously in the app and requires full
  document layout. Version 0.1.3 moves this work to a cancellable helper (below).
- Find and Select All operate on text already constructed while loading is in
  progress. PDF export is available after construction completes.
- The Mac was locked, so interactive scrolling and visual inspection of the
  updated app were not performed. Intel execution was not tested.

## Reproducing measurements

See [benchmark commands](../CONTRIBUTING.md#large-document-measurements).
`scripts/benchmark.swift` compiles against the app's actual MarkdownCore sources.
Use one document per optimized process and `/usr/bin/time -l` for peak RSS.
Append `--full-layout` to measure the deferred whole-document layout separately.

The measurements above exclude process startup from stage timings. Peak RSS
includes the whole benchmark process; it is neither incremental document memory
nor the installed app's steady-state footprint. Runs were sequential on a
non-isolated Mac, not a statistically controlled cold-cache study. The first
15 MiB baseline attempt was stopped at 45 seconds; a retry with a longer cap
completed in 46.16 seconds.

The viewport approach follows AppKit's
[noncontiguous layout](https://developer.apple.com/documentation/appkit/nslayoutmanager/allowsnoncontiguouslayout)
and [background layout](https://developer.apple.com/documentation/appkit/nslayoutmanager/backgroundlayoutenabled)
controls. SSMV disables idle whole-document layout and uses on-demand layout.


## PDF export — 0.1.3

The original 15 MiB PDF measurement (13,434 pages, 32.9 MiB, 53 seconds) was
incomplete: `NSTextView.sizeToFit()` clamped the print view at its default
10,000,000-point maximum height, although the text layout needed 14,664,720 points.
Version 0.1.3 removes that cap. A regression uses three lines with large paragraph
spacing to reproduce the boundary without generating thousands of pages.

The same generated 15 MiB source now produces **19,700 A4 pages**, **50,811,259
bytes (48.5 MiB)**, in **57.4 seconds** on the machine above. The final
`END_OF_DOCUMENT` marker was visually verified on the final PDF page. The
standalone helper peaked at about **1.46 GiB RSS**; this excludes the interactive
app's memory. These numbers describe this repeated heading/list/code fixture,
not a general Markdown-to-PDF size ratio.

The export helper still performs synchronous full-document layout, but the
interactive app is free to read and switch documents. Its progress window shows
stages rather than an estimated percentage. Cancel stops the helper; closing
the document window or quitting also cancels and waits for cleanup. A completed
PDF replaces the destination only after success. Export captures the loaded
source, so later file edits or document selection changes do not change it.

In a separate 1 MiB export through the actual export job, completion took 2.62
seconds (1,314 pages). A main-actor heartbeat requested every 10 ms ran 192 times
with a maximum gap of 15.7 ms. This demonstrates cooperative app-side waiting,
not a measured input latency. Helper cancellation, failure, snapshot consistency,
existing-file preservation, and window-close cleanup have automated tests.
The Mac remained locked, so the new progress window and direct user interaction
have not been visually exercised. The export still consumes time and memory
proportional to document complexity; it is not a faster pagination engine.
