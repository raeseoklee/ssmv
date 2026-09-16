# Security

SSMV is a read-only Markdown viewer for local files, public HTTPS documents, and
imported text. It has no account system, telemetry, embedded browser, remote
image fetching, or Markdown script execution. HTTPS Markdown links open in the
viewer; other HTTP/HTTPS/mailto links open in the system's default application.
Remote and imported documents cannot dispatch local-file or custom-scheme links.

Files must be regular UTF-8 files no larger than 16 MiB. At most two background
parsers run concurrently. Cancelling a request releases its caller immediately;
an already-running Foundation parse retains its slot until it finishes, while
queued cancelled loads are skipped. Text construction yields between batches
and layout is performed on demand. These limits do not guarantee bounded
rendering memory or instant processing of pathological documents. Document records and imported
text are stored in Application Support; preferences and a record backup are
stored in macOS UserDefaults. Records include local paths, remote URLs (including
query parameters), titles, and timestamps. These records are not an upload feed.
The legacy file shelf is retained for migration rollback.

PDF export strips local-file and custom URL schemes from link annotations. The
user chooses the destination; only a completed PDF replaces an existing file.
Export runs another instance of the same signed executable in a private helper
mode, with no shell or external program. The current document source and PDF
are temporarily stored in a per-export directory accessible only to the current
user (0700). Normal completion, cancellation, and orderly app exit remove these
files; a crash or forced termination can leave temporary files. The app retains
the loaded source in memory so subsequent disk edits do not change an export.
Removing a document from the sidebar does not delete its original file.


## URL acquisition and storage

Explicit URL opening, selecting an uncached remote document, and Reload can send
HTTPS requests to the supplied host and validated redirect destinations. The
server receives the requested path and query parameters, plus normal connection
information. Requests do not use browser cookies or stored credentials. URL
userinfo and redirects to HTTP are rejected. Public GitHub file links resolve to
raw content; authentication and webpage-to-Markdown conversion are unsupported.

At most two downloads run at once, separately from the two parser slots. Each
body is limited to 16 MiB, with a 15-second request timeout, a 30-second transfer
deadline, and at most five redirects. Downloads are validated before cache
promotion. The remote body cache has a 128 MiB budget and can evict old content.
Restoring the sidebar and expanding inactive remote rows use cached content
only. There is no document polling; the separate Homebrew update check remains
limited to once per 24 hours on launch.

Clipboard access occurs only through Open Clipboard as Markdown. Imported text
is durable, with a 256 MiB quota separate from the remote cache. Sidebar removal
keeps imports; Manage Imported Documents permits confirmed deletion only after
they are unlisted. Storage uses owner-only directories (0700) and files (0600).
This is local storage, not encryption, and does not isolate data from other
programs running as the same user. Save a Copy uses the destination you choose.

## CLI delivery

The bundled `SSMVCLI` executable, exposed as `ssmv` by Homebrew, uses NSWorkspace
to deliver a local file or a structured request to the app. It does not invoke a
shell, listen on a port, expose a public URL scheme, or run an MCP server. URL
and stdin requests use owner-only inbox files with a versioned schema, bounded
sizes, UUID paths, symlink checks, and duplicate-delivery handling. Standard
input must be completed UTF-8 text of at most 16 MiB. Pending inbox storage has
a separate 256 MiB limit; unclaimed requests older than 24 hours can be pruned.

CLI success confirms dispatch, not rendering or successful remote acquisition.
Accepted imports are persisted before their request files are acknowledged and
removed. Crashes or failed imports can leave pending requests. Do not include
inbox contents, signed URLs, or private documents in public diagnostics.

The initial release is ad-hoc signed and **not notarized**. Its Homebrew cask
checks the archive SHA-256 and verifies the bundle signature, then removes
quarantine from the installed SSMV.app only. This bypasses Gatekeeper’s
first-launch check for that app; it does not constitute Apple notarization or
change global security settings. The cask discloses this installation behavior.
Build from source if you do not want to use this binary installation method.

Report vulnerabilities through [GitHub private vulnerability reporting](https://github.com/raeseoklee/ssmv/security/advisories/new).
Do not include private Markdown files or credentials in public issues. See the
[publication review](docs/COMPLIANCE.md) for the initial review scope and limits.
