# Contributing to SSMV

SSMV is a small, native Markdown viewer. Contributions should preserve its read-only purpose, macOS conventions, and minimal resource use. Discuss new dependencies or substantial features in an [issue](https://github.com/raeseoklee/ssmv/issues) before implementing them.

## Development

Use macOS 13 or later with Swift 6 or later. The project uses Swift Package Manager and has no external package dependencies.

- `Sources/SSMV/`: app lifecycle, menus, window, and sidebar.
- `Sources/MarkdownCore/`: source loading, URL cache, durable document state, request transport, Markdown rendering, and PDF export.
- `Sources/SSMVCLI/`: the one-shot CLI delivered inside the app as `SSMVCLI`.
- `Tests/MarkdownCoreTests/` and `Tests/SSMVTests/`: core and app regression tests.
- `Resources/`: app metadata and icon assets.
- `scripts/`: app and release tooling.

Run these checks from the repository root:

```sh
swift test
swift build -Xswiftc -warnings-as-errors
swift format lint --strict --recursive Sources Tests Package.swift scripts/benchmark.swift
bash -n scripts/build-app.sh scripts/release.sh
plutil -lint Resources/Info.plist
UNIVERSAL=1 scripts/build-app.sh
```

For UI changes, open `dist/SSMV.app` and check the affected behavior in light and dark appearances. Test Finder opening, sidebar selection, or PDF output when relevant. Cross-compiling for Intel does not verify execution on Intel hardware; report hardware-specific gaps.

## Document input changes

Preserve source identity, insertion order, and selected document when migrating
preferences. Inject an isolated UserDefaults suite and storage/cache directories
in tests; never mutate a developer's real library. Sidebar removal must remain
reference-only. Keep durable imports separate from the evictable remote cache.

For input changes, cover URL validation and redirects, size/encoding limits,
cancellation, cached-only startup, source-aware links, PDF snapshot consistency,
import restart/idempotency, quota failure, and request traversal/symlink rejection.
Use generated fixtures and mock network responses; never commit private text or
signed URLs. Test both cold and warm CLI dispatch with the installed app. Exit 0
means delivery only. Check the bundled `SSMVCLI` executable as well as the GUI,
and the Homebrew `ssmv` link. Do not name the bundled executable `ssmv`: that
collides with `SSMV` on case-insensitive filesystems.

## Release scope

Documentation, screenshots, and GitHub repository metadata are published without changing the app version, creating a tag or GitHub Release, rebuilding the app, or updating the Homebrew cask. Update tap documentation when relevant, but leave its cask unchanged.

In repository-presentation work, “About” refers to the GitHub repository description unless the request explicitly refers to the app's About window. Minor app copy changes can wait for the next planned release; do not publish a standalone release automatically.

Use a new screenshot filename when replacing an image so previously cached images are not reused. Verify the published image and update both language editions and tap references.

## Pull requests

Keep changes focused and reuse existing patterns. Add regression coverage for behavior changes. Explain the problem, the resulting behavior, and the checks you ran. Include a screenshot for visual changes and state any untested scenarios. Do not include personal documents, credentials, generated build output, or third-party material without compatible licensing and attribution.

English is the default for project documentation and commit messages. Update [the Korean README](docs/README.ko.md) when user-facing instructions change.

## Commit messages

Follow the Lore convention: start with a short English sentence explaining **why** the change is needed. Add context when useful and optional Git trailers for verification, constraints, or tradeoffs.

```text
Keep the selected document visible after removing a sidebar item

Choose the next available entry so readers can continue without reopening a file.

Confidence: high
Scope-risk: narrow
Tested: Sidebar selection regression tests
Not-tested: VoiceOver navigation
```

Useful trailers include `Constraint:`, `Rejected:`, `Confidence:`, `Scope-risk:`, `Directive:`, `Tested:`, and `Not-tested:`. Only record claims that apply to your change.

Contributions are provided under the project's [MIT License](LICENSE).

## Large-document measurements

Compile the benchmark with the same MarkdownCore implementation, then run one
file per process to measure peak resident memory separately:

```sh
mkdir -p .build/benchmarks
swiftc -O -swift-version 6 -parse-as-library Sources/MarkdownCore/*.swift scripts/benchmark.swift -o .build/benchmarks/benchmark
/usr/bin/time -l .build/benchmarks/benchmark /path/to/document.md
```

The benchmark reports first-viewport time, complete text construction, and gaps
between main-actor heartbeat checks. `--full-layout` additionally measures the
whole-document layout required for comparison with older versions; the viewer
does not force this on opening. `tail_preserved` expects a fixture ending in
`END_OF_DOCUMENT`. This is a rendering harness, not an interactive UI test or an
end-to-end Finder launch measurement. Use generated files without personal data.
