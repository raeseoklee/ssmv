# Publication review

Reviewed on **2026-09-14** for SSMV 0.1.0, before the initial public upload.

## Scope and result

The review covered the Swift source and tests, package manifest, shell scripts,
CI workflow, app metadata, icon assets, examples, documentation, and intended
release archive. There was no pre-existing Git history to publish.

**No unresolved source-publication blocker was identified in the reviewed
files.** This is a technical licensing and exposure review, not a legal opinion
or a guarantee of copyright, trademark, or security clearance.

## Licensing and provenance

- The project uses MIT for its own source, scripts, examples, and documentation.
- `swift package show-dependencies` reports no external dependencies. No vendored
  library source or bundled third-party fonts were found.
- Apple frameworks and system UI assets are supplied by macOS. They are not
  relicensed or bundled as standalone artwork. The app icon is separately generated.
- The initial implementation and icon were created with AI assistance. The icon
  prompt and generation provenance are retained. AI output may be nonunique;
  this review does not establish exclusive rights or exhaustive trademark clearance.
- [Third-party notices](../THIRD_PARTY_NOTICES.md) document platform terms,
  generated artwork, and the CC0 Markdown Mark reference.

The relevant primary sources were checked: [Apple's Xcode and SDK agreement,
section 2.10](https://www.apple.com/legal/sla/docs/xcode.pdf),
[OpenAI's output terms](https://openai.com/policies/row-terms-of-use/), and the
[Markdown Mark license](https://github.com/dcurtis/markdown-mark/blob/master/LICENSE).

## Exposure and security checks

Source inspection and pattern scans checked intended public files for credentials,
private keys, personal machine paths, network calls, process execution, and
unattributed copied material. Build output, local state, and temporary files are
excluded from source publication. Release binaries have debug symbols stripped
before signing to remove local build paths. The documentation screenshot uses public example
files. Pattern scans cannot prove the absence of all secrets or copied material.

Before release, file loading was restricted to regular UTF-8 files of at most
16 MiB, parsing was serialized with cancellation checks, and PDF export was
restricted to HTTP, HTTPS, and mailto link annotations. Regression tests cover
file rejection and PDF link filtering. CI actions are pinned to commits and
receive read-only repository permissions without persisted Git credentials.

## Distribution limitation

Version 0.1.0 is a universal Apple Silicon/Intel build with an **ad-hoc signature**.
It is **not Developer ID signed or notarized**. This limitation is disclosed in
installation and release documentation. At initial publication, the SSMV Homebrew cask preserved quarantine. A future notarized release requires a Developer
ID Application certificate and Apple notarization credentials.

See [Security](../SECURITY.md) for runtime boundaries and reporting.

## Homebrew installation correction — 2026-09-14

After a reported launch failure, installation behavior was compared with this
tap’s bium cask. Both apps were ad-hoc signed, but only bium removed quarantine
after installation. SSMV’s cask now checks the bundle signature and removes
quarantine from SSMV.app after Homebrew verifies the archive checksum. This
bypasses Gatekeeper’s first-launch check for that app without changing global
security settings. It does not add Apple notarization or prove malware absence.
The cask and installation documentation disclose the change. The release archive
and its checksum are unchanged. Notarized releases omit these install steps.

## Large-document processing — 0.1.2

The viewer now limits background parsing to two workers, cancels obsolete
waiters, constructs text in cooperative batches, and defers offscreen layout.
Native table cells are reused across inline spans. No new dependencies or
subprocess parsing were introduced. The file-size and PDF link restrictions
remain unchanged. See [performance measurements](PERFORMANCE.md) for validation
and the limits of noninterruptible parsing and synchronous PDF export.


## PDF correctness and cancellation — 0.1.3

Removed the native text view's default height cap that truncated exceptionally
long PDFs. PDF parsing, formatting, and print layout now run in a private mode
of the same executable. No package, external executable, shell invocation, or
network operation was added. Export uses a snapshot of the loaded source in a
0700 temporary directory. Cancellation waits for helper termination and removes
temporary files; only successful output is staged beside the chosen destination
and atomically published. Orderly app exit waits for active export cleanup.
Forced termination can still leave temporary files. PDF link filtering, the
16 MiB input limit, and release signing behavior are unchanged.

Validation includes snapshot consistency, cancellation, destination preservation,
launch failure, window-close cleanup, and a height-cap regression. The 15 MiB
fixture now exports its final marker; see [measurements](PERFORMANCE.md#pdf-export--013).


## Finder registration and full-screen controls — 0.1.4

The initial Homebrew postflight attempted to register the installed SSMV bundle
with Launch Services. Installation testing exposed a sandbox restriction;
version 0.1.5 replaces that step with registration on normal launch. Neither
approach resets the database or assigns default document handlers. The existing
Markdown type declarations and Viewer/Alternate rank are retained. Signature
verification and app-specific quarantine handling remain unchanged.

Full-screen controls use AppKit's native presentation options, without mouse
tracking, overlays, or global preference changes. The proposed Dock policy is
preserved. Tests verify the option combination and unchanged windowed state;
direct hover interaction was not tested while the Mac was locked.


## Homebrew registration compatibility — 0.1.5

Actual installation testing found that Homebrew's sandbox denies the
`com.apple.lsd.modifydb` Mach service. Both `lsregister` and `LSRegisterURL`
return -10822 inside that sandbox, and a required postflight step rolls back the
installation. The tap correction removes registration from postflight without
weakening the sandbox or changing signature/quarantine checks.

SSMV registers only its own bundle through `LSRegisterURL` on normal launch.
Installation instructions therefore ask users to open SSMV once. An internal
`--register-documents` mode performs the same app-scoped registration and exits
before creating UI or touching preferences. No default handlers are assigned.
The 0.1.4 full-screen behavior is retained. Other-Mac state and direct hover
interaction remain unverified; local supported-extension and default-handler
queries validate the installed registration path.


## 0.3.0 update check

The startup checker reads the public `raeseoklee/homebrew-tap` cask over HTTPS using an ephemeral URLSession, with a five-second timeout and a 64 KiB response limit. It compares a literal numeric version without executing Ruby. No document content, paths, credentials, or analytics are transmitted. GitHub receives a normal network request with a fixed generic User-Agent. Checks are limited to once per 24 hours. The notice only copies Homebrew commands on request; it never runs a shell, downloads an app, or changes signing or quarantine policy. No external dependencies were added.
