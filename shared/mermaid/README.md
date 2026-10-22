# Offline Mermaid renderer

SSMV vendors Mermaid **12.2.0**, unmodified, from the official npm package.
The entry module and diagram chunks load locally on demand; no CDN or remote
rendering endpoint is used. Native text controls remain responsible for the
Markdown document. Rendered diagrams use a bounded image cache.

## Provenance

- Package: [`mermaid@12.2.0`](https://registry.npmjs.org/mermaid/12.2.0)
- Source: [Mermaid release](https://github.com/mermaid-js/mermaid/tree/mermaid%4012.2.0)
- npm archive SHA-1: `8500d2500a57bd10f0c8ab03ec4deff87df36c39`
- Entry module SHA-256: `dae3440dd5a4adecf76cfd2951c7a69523df3237f110dd186bebbd55f6038c9d`
- Copied files: `dist/mermaid.esm.min.mjs` and
  `dist/chunks/mermaid.esm.min/*.mjs`; no source maps or TypeScript declarations.
- Local KaTeX CSS/font assets retain their original MIT notices.

The full distribution preserves the upstream diagram families, including
mindmaps and architecture diagrams. The host disables external resources and
interactive actions. Invalid or oversized diagrams fall back to their source.
macOS uses system WebKit; Windows uses the installed WebView2 Runtime.

## Redistribution

Keep the entire `licenses/` directory with the renderer in source distributions
and packaged apps. `licenses/inventory.json` records exact package versions,
npm archive integrity and paths to retained license/notice files. It
conservatively covers the runtime dependency closure from the release's
[pnpm lockfile](https://github.com/mermaid-js/mermaid/blob/mermaid%4012.2.0/pnpm-lock.yaml),
excluding type-only packages. Some listed dependencies may be eliminated by
upstream bundling; this inventory is not an exact runtime module list.

Mermaid and most supporting packages use MIT, ISC or BSD-3-Clause terms.
Chevrotain uses Apache-2.0. For dual-licensed DOMPurify this distribution uses
Apache-2.0. ELK uses EPL-2.0; its [source availability notice](licenses/elkjs@0.9.3/SOURCE.md)
and license must remain available. KaTeX and its fonts use MIT terms, with
[font provenance](licenses/katex-fonts/SOURCE.md) retained separately.

On upgrades, recheck the release lockfile, all retained notices and the actual
asset payload before publication. Do not strip the license comments embedded
in upstream JavaScript or replace these assets with an unpinned CDN URL.

## Resource limits

Each diagram is limited to 64 KiB of source, 500 edges, and a bounded output image.
Configuration directives/frontmatter are not accepted; themes and security settings
come from the app. A reading page or PDF preparation attempts at most 24 diagrams;
macOS limits decoded attachments to 24 MiB and Windows to 64 MiB. Timed-out,
invalid, or over-budget diagrams retain their source instead of blocking reading.
The web renderer is temporary on macOS and closes after 15 idle seconds on Windows.
