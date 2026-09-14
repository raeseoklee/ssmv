# Security

SSMV is a local, read-only Markdown viewer. It has no account system, telemetry,
embedded browser, remote image fetching, or Markdown script execution. Clicking
an HTTP/HTTPS/mailto link hands it to the system's default application.

Files must be regular UTF-8 files no larger than 16 MiB. Parsing is serialized;
an already-running Foundation parse is not interruptible, but queued cancelled
loads are skipped. Large documents can still take time to lay out. Local file
references and UI preferences are stored in macOS UserDefaults, not uploaded.

PDF export strips local-file and custom URL schemes from link annotations. The
user chooses the destination; only a completed PDF replaces an existing file.
Removing a document from the sidebar does not delete its original file.

The initial release is ad-hoc signed and **not notarized**. Its Homebrew cask
checks the archive SHA-256 and does not remove quarantine or disable Gatekeeper.
Prefer building from source if you do not want to approve an unnotarized binary.

Report vulnerabilities through [GitHub private vulnerability reporting](https://github.com/raeseoklee/ssmv/security/advisories/new).
Do not include private Markdown files or credentials in public issues. See the
[publication review](docs/COMPLIANCE.md) for the initial review scope and limits.
