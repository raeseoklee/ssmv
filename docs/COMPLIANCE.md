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
installation and release documentation. The SSMV Homebrew cask does not disable
Gatekeeper or remove quarantine. A future notarized release requires a Developer
ID Application certificate and Apple notarization credentials.

See [Security](../SECURITY.md) for runtime boundaries and reporting.
