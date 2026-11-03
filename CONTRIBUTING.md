# Contributing

[English](CONTRIBUTING.md) · [简体中文](CONTRIBUTING.zh.md)

You can contribute by reporting bugs, improving documentation, or submitting code. The project maintains the native macOS app only. See the [README](README.md#build-from-source) for build instructions and the [getting started guide (Chinese)](docs/getting-started.md) for usage. For larger features or changes in direction, open an issue describing the problem and expected behavior before starting.

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

Test preparation uses the `python3` standard library, with no extra Python packages. Some tests skip when public RAW samples, smart-mask resources, or required access are unavailable. Report the actual tests run, skips, and failures separately. Interface changes also need checks in the app's actual window using permitted samples.

Ordinary development does not require smart-mask weights. The research preparation script downloads a complete set of experimental resources, including face weights. See the [model guide (Chinese)](docs/smart-mask-models.md) for restrictions, model versions, and behavior when models are missing.

Register new Swift files in both `Phosdeck.xcodeproj/project.pbxproj` and `project.yml`. Check licenses and bundled notices before adding dependencies; the repository does not accept GPL dependencies. See the [README license section](README.md#license) for the project's license and third-party notices.

## Submit changes

Review the diff and run `git diff --check` before committing. Keep private samples, build outputs, local signing configuration, and unrelated changes out of the commit. Write commit messages in English using [Conventional Commits](AGENTS.md#提交约定), for example `docs: clarify catalog backup` or `fix(import): preserve selected photos`.

In the pull request, describe the problem, the main changes, and the actual verification results, including failures and skips. For interface changes, you can attach reviewed screenshots made with synthetic data. See the [localization guide (Chinese)](docs/localization.md) for creating and maintaining community language packs.
