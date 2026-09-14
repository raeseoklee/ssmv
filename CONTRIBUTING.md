# Contributing to SSMV

SSMV is a small, native Markdown viewer. Contributions should preserve its read-only purpose, macOS conventions, and minimal resource use. Discuss new dependencies or substantial features in an [issue](https://github.com/raeseoklee/ssmv/issues) before implementing them.

## Development

Use macOS 13 or later with Swift 6 or later. The project uses Swift Package Manager and has no external package dependencies.

- `Sources/SSMV/`: app lifecycle, menus, window, and sidebar.
- `Sources/MarkdownCore/`: file loading, Markdown rendering, document state, and PDF export.
- `Tests/MarkdownCoreTests/`: automated regression tests.
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
