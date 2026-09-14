# Security

SSMV is a local, read-only Markdown viewer. It has no account system, telemetry,
embedded browser, remote image fetching, or Markdown script execution. Clicking
an HTTP/HTTPS/mailto link hands it to the system's default application.

Files must be regular UTF-8 files no larger than 16 MiB. At most two background
parsers run concurrently. Cancelling a request releases its caller immediately;
an already-running Foundation parse retains its slot until it finishes, while
queued cancelled loads are skipped. Text construction yields between batches
and layout is performed on demand. These limits do not guarantee bounded
rendering memory or instant processing of pathological documents. Local file
references and UI preferences are stored in macOS UserDefaults, not uploaded.

PDF export strips local-file and custom URL schemes from link annotations. The
user chooses the destination; only a completed PDF replaces an existing file.
Export runs another instance of the same signed executable in a private helper
mode, with no shell or external program. The current document source and PDF
are temporarily stored in a per-export directory accessible only to the current
user (0700). Normal completion, cancellation, and orderly app exit remove these
files; a crash or forced termination can leave temporary files. The app retains
the loaded source in memory so subsequent disk edits do not change an export.
Removing a document from the sidebar does not delete its original file.

The initial release is ad-hoc signed and **not notarized**. Its Homebrew cask
checks the archive SHA-256 and verifies the bundle signature, then removes
quarantine from the installed SSMV.app only. This bypasses Gatekeeper’s
first-launch check for that app; it does not constitute Apple notarization or
change global security settings. The cask discloses this installation behavior.
Build from source if you do not want to use this binary installation method.

Report vulnerabilities through [GitHub private vulnerability reporting](https://github.com/raeseoklee/ssmv/security/advisories/new).
Do not include private Markdown files or credentials in public issues. See the
[publication review](docs/COMPLIANCE.md) for the initial review scope and limits.
