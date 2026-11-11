<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/readme/hero-graphite.svg">
  <source media="(prefers-color-scheme: light)" srcset="docs/assets/readme/hero-ivory.svg">
  <img src="docs/assets/readme/hero-ivory.svg" width="1200" alt="Phosdeck, a photo manager and editor for macOS">
</picture>

<h1 align="center">Phosdeck</h1>

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh.md">简体中文</a> · <a href="https://rankangkang.github.io/phosdeck/">Website</a>
</p>

<p align="center">
  <a href="#build-from-source"><img src="https://img.shields.io/badge/macOS-26%2B-2A2B29?style=flat-square&amp;labelColor=1C1D1C" alt="Requires macOS 26 or later"></a>
  <a href="#development-and-contributing"><img src="https://img.shields.io/badge/UI-SwiftUI%20%2B%20Metal-2A2B29?style=flat-square&amp;labelColor=1C1D1C" alt="Native SwiftUI interface and Metal preview"></a>
  <a href="#support-and-limitations"><img src="https://img.shields.io/badge/status-development_preview-B85F14?style=flat-square&amp;labelColor=1C1D1C" alt="Development preview"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0--only-2A2B29?style=flat-square&amp;labelColor=1C1D1C" alt="Licensed under AGPL-3.0-only"></a>
</p>

Phosdeck is a photo manager and non-destructive editor for macOS, built with SwiftUI, Core Image, Metal, and GRDB. Originals stay on your Mac. The catalog stores organization data and edits.

Enable the local MCP server in Settings → Agent to manage catalogs, import photos, review folder changes, and recover copy imports. An Agent can also filter, select and compare photos, set ratings, flags, and color labels in batches, and edit keywords and captions. Preview sharing has its own switch. [Setup and Phosdeck Skill](docs/agent-integration.md#本地连接)

The project is a development preview. Download a [prerelease build](https://github.com/rankangkang/phosdeck/releases) or build from source.

## Interface

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="design/darkroom_workspace_graphite.jpg">
  <source media="(prefers-color-scheme: light)" srcset="design/darkroom_workspace_ivory.jpg">
  <img src="design/darkroom_workspace_ivory.jpg" width="1800" alt="Develop workspace: presets and history on the left, a synthetic gradient preview in the center, and editing controls on the right">
</picture>

<p align="center"><sub>Graphite and ivory themes, selected by GitHub's appearance setting. Screenshots taken on 2026-11-03 using a synthetic test image.</sub></p>

Themes affect the interface only. They do not change photo pixels or exported images.

## Features

| Feature | Details |
|---|---|
| Photo organization | Import in place or copy files; ratings, flags, color labels, keywords, regular and smart collections, virtual copies, stacks, and RAW/JPEG pairing |
| Global adjustments | Exposure, white balance, point curves, HSL, B&W mixing, point color, manual defringe, sharpening, noise reduction, grain, and vignette; presets, history, and snapshots |
| Local adjustments | Brushes, linear and radial gradients, color and luminance range masks, person selection, and spot repair |
| Geometry | Crop, line-based straightening, flip, and guided or automatic perspective correction |
| Photo merging | Panorama, HDR, HDR panorama and focus stacking; average, median, additive, lighten, darken and screen modes; panorama levelling, boundary warp and diffusion edge fill; separate editable 32-bit float TIFF/DNG masters |
| Camera checks | Local RAW decoding and pipeline consistency checks with JSON reports |
| Export | JPEG, PNG, and 16-bit TIFF; naming templates, export presets, multiple output specifications, and optional metadata; existing files are never overwritten |

Lightroom XMP preset import supports an approximate conversion of selected global parameters. Results may differ from Lightroom. Lightroom catalogs cannot be opened directly.

## Build from source

Requires macOS 26 or later and Xcode 26 or later, including the Metal Toolchain. Most validation has been done on Apple Silicon.

The repository uses [Git LFS](https://git-lfs.com/) for raster images outside `site/`. Install it and run `git lfs install` before cloning; in an existing checkout, run `git lfs install` and `git lfs pull`.

1. Clone the repository:

   ```sh
   git clone https://github.com/rankangkang/phosdeck.git phosdeck
   cd phosdeck
   ```

2. Build from the repository root:

   ```sh
   xcodebuild -project Phosdeck.xcodeproj -scheme Phosdeck -configuration Debug -derivedDataPath build -destination 'platform=macOS' build
   ```

The first build needs an internet connection to download the pinned Swift packages and binary dependencies. You can also open `Phosdeck.xcodeproj` in Xcode, select the `Phosdeck` scheme, and run it.

Debug builds use local ad hoc signing by default, with no Apple development certificate required. In the tested Xcode 27.1 build, the sandbox is retained but hardened runtime is disabled. File access may need to be granted again after rebuilding.

The app is built at `build/Build/Products/Debug/Phosdeck.app`. For a first run, create a `.phoscat` test catalog and import a few synthetic images or photos you have permission to use. Try rating, editing, and exporting them. The [getting started guide (Chinese)](docs/getting-started.md) covers the full workflow and backup and restore steps.

Catalogs store photo locations and edits, not the original files. Back up photos and exports separately. Existing `.omlcat` and `.omlrcat` files can still be opened; a prompt lets you choose whether to change the extension in place. Renaming does not convert the database format.

<details>
<summary>Use a stable local development signature</summary>

If an Apple Development certificate is installed in your keychain, create `Config/LocalSigning.xcconfig` with your team ID:

```xcconfig
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

This file is ignored by Git and overrides the default Debug signing settings. The build steps above are for local development; distribution signing and notarization require separate setup.

</details>

<details>
<summary>Install the Metal Toolchain</summary>

If Xcode reports that the component is missing, run:

```sh
xcodebuild -downloadComponent MetalToolchain
```

</details>

## Support and limitations

| Area | Current support |
|---|---|
| Input | JPEG, single-page RGB TIFF, and supported static PNG files. ARW, NEF, CR3, RAF, and some DNG files depend on the camera, compression mode, and macOS decoder. |
| Not enabled | HEIC and Apple DNG/ProRAW. |
| Output | JPEG, 8-bit PNG, and 16-bit TIFF, currently in sRGB. Wide-gamut output and soft proofing are not implemented. |
| Smart masks | Whole-person selection uses system Vision and needs no extra weights. Object and body-part selection require separately prepared research models. Manual masks and saved selections work without those models. Distribution rights for the face weights remain unresolved; see the [model guide (Chinese)](docs/smart-mask-models.md). |
| Catalog format | Old catalog schemas are not migrated during development. Keep existing catalogs, backups, and originals before upgrading. |
| Interface language | Built-in Simplified Chinese and English, with support for community language packs. The English interface still has some clipped text and wording issues; see the [localization guide (Chinese)](docs/localization.md). |

## Development and contributing

Run the native checks from the repository root:

```sh
./scripts/check.sh
```

The checks use the `python3` standard library to prepare optional public RAW test resources; no extra Python packages are needed. Some tests skip when samples, models, or required access are unavailable. Report the actual results.

| Guide | Contents |
|---|---|
| [Getting started (Chinese)](docs/getting-started.md) | Catalog creation, import, editing, export, backup, and restore |
| [Contributing](CONTRIBUTING.md) · [简体中文](CONTRIBUTING.zh.md) | Bug reports, development checks, and submitting changes |
| [Development rules (Chinese)](AGENTS.md) | Code layout, data protection, commit conventions, and local app review |
| [Documentation index (Chinese)](docs/README.md) | Current status, decisions, and topic guides |
| [Design specification v3 (Chinese)](design/darkroom_instrument_design_system_v3.md) | Native darkroom interface and interaction conventions |
| [Design tokens v3](design/darkroom_instrument_tokens_v3.json) | Ivory and graphite colors, dimensions, and state tokens |
| [Issues](https://github.com/rankangkang/phosdeck/issues) | Bug reports and feature requests |

## Acknowledgments

Phosdeck draws on Lightroom Classic's workflow and uses algorithms and implementations from these projects:

| Source | Use in Phosdeck |
|---|---|
| [Adobe Lightroom Classic](https://www.adobe.com/products/photoshop-lightroom-classic.html) | Workflow reference for photo organization, culling, developing, local adjustments, and batch export. The exposure response tables for raster images use Lightroom output from synthetic images as reference; the basis for public use still needs review. See [known issues (Chinese)](docs/STATUS.md#已知问题). |
| [Lightcraft](https://github.com/storytold/lightcraft) | Feature and interaction reference. Selected algorithms and implementations, including preset strength, masks, vignette, grain, point color, stacks, HDR and panorama merging, were ported or adapted to Swift/Metal under MIT. |
| [Redlamp](https://github.com/pdcgomes/redlamp) | Line detection and CPU focus-stack alignment, depth and detail fusion adapted under MPL-2.0; line constraints, conservative geometry fallback and camera-evidence organization inform native implementations. |
| [PhotoCraft](https://github.com/storytold/photocraft) | Source of the test-only PatchMatch prototype through Lightcraft, adapted under MIT. The prototype is not part of the app's current repair pipeline. |
| [Oklab — Björn Ottosson](https://bottosson.github.io/posts/oklab/) | Conversion matrices and reference implementation for perceptual color processing, with MIT attribution retained. |

The [third-party attribution and license notice](docs/references/lightcraft-LICENSE.txt) records the specific ports, upstream revisions, and copyright notices.

## License

Project code is licensed under [AGPL-3.0-only](LICENSE). Third-party code, dependencies, and resources retain their own licenses. Notices include:

- [Lightcraft/PhotoCraft attribution and MIT license](docs/references/lightcraft-LICENSE.txt).
- [Redlamp attribution and MPL-2.0 license](docs/references/redlamp-LICENSE.txt).
- [Oklab attribution and MIT license](docs/references/oklab-LICENSE.txt).
- [GRDB MIT license](docs/references/grdb-LICENSE.txt).
- [MCP Swift SDK, SwiftNIO, and dependency notices](docs/references/mcp-NOTICES.txt).
- [SmartMaskRuntime/LiteRT Apache-2.0 license](Packages/SmartMaskRuntime/LICENSE) and [pinned runtime dependency notices](docs/references/litert-NOTICES.txt).
- [Smart-mask research model sources, licenses, and restrictions](docs/references/smart-mask-research-NOTICE.txt).

Model weights and sample photos are not included with the source, and their licenses are not replaced by this project's AGPLv3 license. See the [model guide (Chinese)](docs/smart-mask-models.md) for versions, sources, and packaging limits. Notices from the removed Rust experiments remain in the [legacy attribution files](docs/references/legacy-rust/README.md).
