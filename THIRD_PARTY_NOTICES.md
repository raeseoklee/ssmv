# Third-party notices and asset provenance

## Source and documentation

SSMV's source code, scripts, examples, and documentation are provided under the
[MIT License](LICENSE). The initial implementation was developed with AI
assistance and reviewed before publication. No external Swift packages or
vendored library source are included.

## Apple platform components

The app links to macOS-provided AppKit, Foundation, and UniformTypeIdentifiers.
Tests also use PDFKit and Swift Testing. System fonts and toolbar/sidebar
symbols are requested through Apple APIs at runtime; their binaries and symbol
artwork are not redistributed in this repository. These platform components
remain subject to Apple's terms, not SSMV's MIT license.

The [Xcode and Apple SDKs Agreement](https://www.apple.com/legal/sla/docs/xcode.pdf),
section 2.10, governs system-provided images. SSMV uses them in its macOS UI,
not as its app icon or logo. macOS screenshots show the app's actual UI.

## App icon

`macos/Resources/AppIcon-source.png` was generated for this project with OpenAI's image
generation tool. `macos/Resources/AppIcon-prompt.txt` records its provenance and final
packaging geometry; `macos/scripts/build-icon.sh` creates the macOS renditions. No
Apple SF Symbol export, third-party font file, or third-party icon image was
used as the source asset. The generated design incorporates a conventional
Markdown-style M and downward arrow.

The independently published [Markdown Mark by Dustin Curtis](https://github.com/dcurtis/markdown-mark)
is dedicated to the public domain under [CC0](https://github.com/dcurtis/markdown-mark/blob/master/LICENSE).
Its files were not copied into this project; this reference documents the
established motif rather than claiming authorship of the Markdown Mark.

To the extent the maintainers hold rights in the generated artwork, it is
available under this repository's MIT License. This is not a claim that
AI-generated artwork has exclusive copyright or trademark protection.
[OpenAI's terms](https://openai.com/policies/row-terms-of-use/) assign output
rights between OpenAI and the user to the extent permitted by law, while
retaining the user's responsibility for third-party rights. Neither Apple,
OpenAI, nor the Markdown Mark's creator endorses SSMV.

## Windows platform components

The Windows development project restores Microsoft.WindowsAppSDK.WinUI 1.8.260803003
and Microsoft.Windows.CppWinRT 2.0.250303.1 from NuGet. These packages and their
transitive dependencies retain their own licenses; SSMV's MIT license does not
relicense the Windows SDK or runtime. The Windows core parser uses only the C++
standard library. No third-party Markdown parser source is vendored.

Windows App SDK package license terms govern redistribution of runtime files.
C++/WinRT includes its own license in the package. Before publishing a Windows
installer or release, retain the restored packages' license/notice files, review
the actual runtime files included, and complete the distribution review.
Windows builds are currently development artifacts, not signed release packages.
