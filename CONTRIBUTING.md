# Contributing

[English](CONTRIBUTING.md) · [简体中文](CONTRIBUTING.zh.md)

You can contribute by reporting bugs, improving documentation, or submitting code. The application targets native macOS; its static product website lives in `site/`. See the [README](README.md#build-from-source) for app build instructions and the [getting started guide (Chinese)](docs/getting-started.md) for usage. For larger features or changes in direction, open an issue describing the problem and expected behavior before starting.

## Report a bug

When opening an [issue](https://github.com/rankangkang/phosdeck/issues), include as much of the following as possible:

```text
Version or commit:
macOS version and chip architecture; Xcode version for build issues:
Steps to reproduce, preferably with synthetic images:
Expected result:
Actual result, frequency, and relevant error messages:
What you have tried; any community language packs or optional models in use:
```

Find macOS and chip details in About This Mac. Use `git rev-parse --short HEAD` for the checked-out commit and `xcodebuild -version` for the Xcode version.

Check screenshots, recordings, and logs for usernames, email addresses, tokens, absolute paths, photo filenames, and metadata before posting. Do not upload private originals, `.phoscat`/`.omlcat`/`.omlrcat` catalogs, SQLite backups, JSON management manifests, or file-access bookmarks. These can expose personal information even without photos attached.

Try to reproduce the issue with images you generate yourself. For other samples, confirm that you can share them, inspect the image and metadata for personal information, and provide the source and license. If a sample cannot be shared safely, explain that limitation.

## Local development and checks

Application code is in `Sources/`; regression tests are in `Tests/`. Follow the [development rules (Chinese)](AGENTS.md), especially the requirements for protecting photos and catalogs, registering Swift files, writing files, and handling performance-sensitive code. Use synthetic data or public samples explicitly allowed by the repository and covered by the required permissions. Do not write tests that search for private catalogs or originals. `Samples/` is ignored by Git; this does not make its contents suitable for committing.

JPG, JPEG, PNG, WebP, GIF and TIFF assets outside `site/` are tracked with Git LFS regardless of size; see the [README](README.md#build-from-source) for setup. Website assets remain in regular Git for GitHub Pages. LFS does not override the ignore rules for samples or catalogs.

Run the full checks from the repository root:

```sh
./scripts/check.sh
```

The full checks run documentation validation first. For documentation-only changes, run:

```sh
python3 scripts/check-docs.py
git diff --check
```

The README and contribution guide each have Chinese and English versions. Keep both versions in sync when changing shared information.

You can also run a test class affected by your change, for example:

```sh
xcodebuild -project Phosdeck.xcodeproj -scheme Phosdeck -derivedDataPath build -destination 'platform=macOS' -only-testing:PhosdeckTests/FoundationTests test
```

Optional real merge sequences are listed in [`Tests/Fixtures/public-merge-samples.json`](Tests/Fixtures/public-merge-samples.json), with sources, usage scope and file hashes. Place local files in `Samples/public-merge/<id>/`. Test builds stage only complete, hash-verified sequences and skip absent ones; they never download them. Photographs, reference programs and generated results are not distributed with the app or repository.

Test preparation uses the `python3` standard library, with no extra Python packages. Some tests skip when public RAW samples, smart-mask resources, or required access are unavailable. Report the actual tests run, skips, and failures separately. Interface changes also need checks in the app's actual window using permitted samples.

Ordinary development does not require smart-mask weights. The research preparation script downloads a complete set of experimental resources, including face weights. See the [model guide (Chinese)](docs/smart-mask-models.md) for restrictions, model versions, and behavior when models are missing.

Register new Swift files in both `Phosdeck.xcodeproj/project.pbxproj` and `project.yml`. Check licenses and bundled notices before adding dependencies; the repository does not accept GPL dependencies. See the [README license section](README.md#license) for the project's license and third-party notices.

## Continuous integration

GitHub Actions uses read-only repository permissions for checks, with separate deployment permissions for Pages:

- `Check repository`: validates documentation, changed whitespace, Python/shell syntax, and workflow syntax on PRs, pushes to `master`, and manual runs.
- `Check native app`: builds all test code and runs selected core regressions on macOS 26 with Xcode 26.6 when native code, tests, project files, or related resources change. Select `full_suite` in a manual run for the complete XCTest suite. Ad hoc CI tests disable hardened runtime; distribution signing retains it.
- `Check website and deploy GitHub Pages`: checks, builds, and tests the website for relevant PRs and manual runs. See [website development](#website-development) for automatic deployment conditions.
- `Verify release package`: runs after a Release is published, or manually with an existing tag such as `v0.1.0-alpha.1`. It downloads the ZIP and SHA-256 file and checks the version, universal binary, signature, notarization ticket, Gatekeeper, and bundle contents using the current verification rules on `master`.

Native CI downloads no RAW samples or research models. Core tests are not full coverage; inspect known failures and skips caused by missing resources separately in full-suite results. XCTest result bundles, logs, and summaries are retained for seven days. The focus and sandbox-copy failures in [known issues (Chinese)](docs/STATUS.md#已知问题) still need fixes. `Tests/test_calibration_paths.py` runs separately on macOS using synthetic data. Signing, notarization, packaging, and GitHub Release publication remain local. CI holds no Apple credentials and creates or modifies no Releases.

## Local prerelease preparation (maintainers)

The current prerelease identifier is `0.1.0-alpha.1`. macOS uses the numeric `CFBundleShortVersionString` `0.1.0` and build number `CFBundleVersion` `1`; the full identifier is stored separately as `PhosdeckReleaseVersion` and used in the package name. The system About window shows the numeric version and build. For the next distributed build, update the version and incrementing build number in both `project.yml` and `Phosdeck.xcodeproj/project.pbxproj`. When changing prerelease stage, also update the identifier in `project.yml`, `Sources/App/Info.plist`, and the version regression test.

Run the applicable checks first and record failures and skips. Review the release notes, supported macOS versions and chips, catalog compatibility limits, [model contents and licensing (Chinese)](docs/smart-mask-models.md), and [known distribution issues (Chinese)](docs/STATUS.md). Release builds contain no research models. Signing and packaging do not replace installation and experience checks on a real Mac.

With the Apple developer team that owns the Developer ID, prepare the `Developer ID Application` certificate and private key in Keychain or Xcode, and sign in to the corresponding Xcode account. Keep certificates, private keys, and credentials out of the repository. Run these commands from the repository root in the same terminal; the archive goes into a new local directory:

```sh
mkdir -p build
RELEASE_DIR="$(mktemp -d "$PWD/build/release.XXXXXXXX")"
xcodebuild -project Phosdeck.xcodeproj -scheme Phosdeck -configuration Release \
  -derivedDataPath build -destination 'generic/platform=macOS' \
  -archivePath "$RELEASE_DIR/Phosdeck.xcarchive" archive
```

The archive uses ad hoc signing. Set `TEAM_ID` to the ten-character ID of the team that owns the certificate, then export a Developer ID-signed app without changing the project or signing its dependencies with a global build setting:

```sh
TEAM_ID="YOUR_TEAM_ID"
plutil -create xml1 "$RELEASE_DIR/ExportOptions.plist"
plutil -insert method -string developer-id "$RELEASE_DIR/ExportOptions.plist"
plutil -insert destination -string export "$RELEASE_DIR/ExportOptions.plist"
plutil -insert signingStyle -string manual "$RELEASE_DIR/ExportOptions.plist"
plutil -insert signingCertificate -string 'Developer ID Application' "$RELEASE_DIR/ExportOptions.plist"
plutil -insert teamID -string "$TEAM_ID" "$RELEASE_DIR/ExportOptions.plist"
xcodebuild -exportArchive -archivePath "$RELEASE_DIR/Phosdeck.xcarchive" \
  -exportPath "$RELEASE_DIR/export" -exportOptionsPlist "$RELEASE_DIR/ExportOptions.plist"
```

For notarization, prepare a Keychain profile with `xcrun notarytool store-credentials PhosdeckNotary` and follow its interactive prompts; never put credentials in the repository or command history. Submit the signed app to Apple as follows. This uploads the binary to Apple but does not create a public download. Continue only if the submission status is `Accepted`:

```sh
ditto -c -k --sequesterRsrc --keepParent "$RELEASE_DIR/export/Phosdeck.app" "$RELEASE_DIR/notary.zip"
xcrun notarytool submit "$RELEASE_DIR/notary.zip" --keychain-profile PhosdeckNotary --wait
xcrun stapler staple "$RELEASE_DIR/export/Phosdeck.app"
xcrun stapler validate "$RELEASE_DIR/export/Phosdeck.app"
```

Run this against the exported app:

```sh
./scripts/package-release.sh "$RELEASE_DIR/export/Phosdeck.app"
```

The script requires a timestamped Developer ID signature, hardened runtime, and a stapled notarization ticket. It uses `scripts/verify-release.sh` to check Gatekeeper, nested code, universal architectures, sandbox entitlements, research models, and bundled notices, then creates a ZIP in a separate `build/releases/` directory and verifies the extracted app and SHA-256. It retains intermediate files on failure, does not overwrite an existing package, and does not upload. Before distribution, also check downloading, installation, launch, import, editing, and export using permitted assets in a separate test environment, and review the licenses required for public distribution. Local checks or notarization do not constitute user acceptance.

## Website development

The bilingual Astro website reuses the app's design tokens and approved brand assets. Website development requires Node.js 22.23.4 or later and npm 9.6.5 or later; native app builds do not require either tool. Run from the repository root:

```sh
npm --prefix site ci
npm --prefix site run dev
```

Preview English at `http://127.0.0.1:4321/phosdeck/` and Chinese at `http://127.0.0.1:4321/phosdeck/zh/`. Both start in graphite unless an explicit website theme choice has been saved. The `/phosdeck/` prefix matches the intended GitHub Pages project path. To stop the local server, run `npm --prefix site run stop`.

Before submitting website changes, run:

```sh
npm --prefix site run check
npm --prefix site run build
npm --prefix site test
python3 scripts/check-docs.py
git diff --check
```

Check both languages and themes in desktop and mobile layouts. GitHub Actions redeploys to [GitHub Pages](https://rankangkang.github.io/phosdeck/) only when a push to `master` includes changes under `site/**`. PRs and manual runs perform checks only. The site imports shared tokens and wordmarks from `design/`; changes confined to those resources go live with the next `site/` change.

The site build uses Astro and `@astrojs/check` (MIT), TypeScript (Apache-2.0), and Astro's optional image tooling: sharp (Apache-2.0) with libvips (LGPL-3.0-or-later). The static output does not ship these build tools or native libraries; their installed packages retain their license notices.

## Submit changes

Review the diff and run `git diff --check` before committing. Keep private samples, build outputs, local signing configuration, and unrelated changes out of the commit. Write commit messages in English using [Conventional Commits](AGENTS.md#提交约定), for example `docs: clarify catalog backup` or `fix(import): preserve selected photos`.

In the pull request, describe the problem, the main changes, and the actual verification results, including failures and skips. For interface changes, you can attach reviewed screenshots made with synthetic data. See the [localization guide (Chinese)](docs/localization.md) for creating and maintaining community language packs.
