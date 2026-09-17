# Contributing to SSMV

SSMV is a small, native Markdown viewer. Contributions should preserve its read-only purpose, macOS conventions, and minimal resource use. Discuss new dependencies or substantial features in an [issue](https://github.com/raeseoklee/ssmv/issues) before implementing them.

## macOS development

Use macOS 13 or later with Swift 6 or later. The macOS project uses Swift Package Manager and has no external package dependencies.

- `macos/Sources/SSMV/`: app lifecycle, menus, window, and sidebar.
- `macos/Sources/MarkdownCore/`: source loading, URL cache, durable document state, request transport, Markdown rendering, and PDF export.
- `macos/Sources/SSMVCLI/`: the one-shot CLI delivered inside the app as `SSMVCLI`.
- `macos/Tests/MarkdownCoreTests/` and `macos/Tests/SSMVTests/`: core and app regression tests.
- `macos/Resources/`: app metadata and icon assets.
- `macos/scripts/`: app and release tooling; `scripts/` retains compatible entrypoints.
- `windows/`: the C++/WinUI 3 Windows project, currently in development.
- `Examples/` and `docs/`: shared sample documents and documentation.

Run these checks from the repository root:

```sh
swift test --package-path macos
swift build --package-path macos -Xswiftc -warnings-as-errors
swift format lint --strict --recursive macos/Sources macos/Tests macos/Package.swift macos/scripts/benchmark.swift
bash -n scripts/*.sh macos/scripts/*.sh
plutil -lint macos/Resources/Info.plist
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
swiftc -O -swift-version 6 -parse-as-library macos/Sources/MarkdownCore/*.swift macos/scripts/benchmark.swift -o .build/benchmarks/benchmark
/usr/bin/time -l .build/benchmarks/benchmark /path/to/document.md
```

The benchmark reports first-viewport time, complete text construction, and gaps
between main-actor heartbeat checks. `--full-layout` additionally measures the
whole-document layout required for comparison with older versions; the viewer
does not force this on opening. `tail_preserved` expects a fixture ending in
`END_OF_DOCUMENT`. This is a rendering harness, not an interactive UI test or an
end-to-end Finder launch measurement. Use generated files without personal data.

## Windows development

The native C++/WinRT and WinUI 3 project lives in `windows/`. See the
[Windows build and test guide](windows/README.md) for prerequisites, supported
features and remaining porting work. Keep platform-specific code in its platform
folder; example documents and repository documentation remain shared. A Windows
CI artifact is a development build and must not trigger a macOS release or tap
update. Windows release readiness requires actual Windows interaction testing.
