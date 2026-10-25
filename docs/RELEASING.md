# Building and publishing releases

Distribution target: Apple Silicon, macOS 14+. Runtime users download a DMG or ZIP; they do not need a compiler, Python or Homebrew. These are ad-hoc signed builds, **not Developer ID signed or notarized**. The per-app approval flow is documented in both README files and each release; no installer changes system security settings.

## Local reproduction

Use an Apple Silicon Mac with Apple's Swift 6 toolchain and Python 3.12+. System tools `clang`, `make`, `codesign`, `iconutil`, `sips`, `ditto` and `hdiutil` are used. The first decoder build downloads source from the official FFmpeg site; subsequent identical builds can use the verified local cache.

```sh
python3 test.py --core-only
python3 Tools/build_ffmpeg.py
python3 Tools/package_release.py --tag v0.3.1
```

The `--tag` check is optional for local previews and mandatory in tag-triggered automation. It refuses a tag that differs from `version.json`.

Files in `dist/release/`:

| Asset | Purpose |
| --- | --- |
| `Reversed-engineering-Icsee-VERSION-macos-arm64.dmg` | Drag the app to Applications; includes a readme and Applications shortcut |
| `Reversed-engineering-Icsee-VERSION-macos-arm64.zip` | Alternative archive containing the same self-contained app |
| `ffmpeg-9.0.2.tar.xz` | Exact unmodified source corresponding to the bundled decoder |
| `ffmpeg-build.json` | Source checksum, configure arguments, license and decoder hashes |
| `SHA256SUMS.txt` | Checksums for the binary archives, FFmpeg source and build metadata |
| `RELEASE_NOTES.md` | Generated installation, signing, licensing and scope notes used by GitHub |

`Tools/verify_bundle.py /path/to/App.app` checks an already extracted app. Packaging additionally extracts the ZIP, mounts the DMG read-only, and verifies each bundle from its distributed format. It requires native icon resources, strict ad-hoc signatures, arm64 binaries targeting macOS 14 or earlier, system-only dynamic library dependencies, matching decoder metadata and all licensing files. Offline fixtures exercise H.264 and HEVC decoding, scaling and MJPEG output with no Homebrew on PATH.

Desktop window/fullscreen checks remain separate: `python3 test.py --interactive`. No packaging check uses live camera credentials or footage. Building or checking a package does not publish it.

## FFmpeg provenance and licensing

`Tools/build_ffmpeg.py` pins the official archive's SHA-256 and fails before extraction on mismatch. It disables GPL/nonfree components and external-library autodetection, and builds only needed protocols, formats, codecs and filters. No source patch is applied. Source compilation happens inside its source directory so build configuration does not expose a developer's home path.

The Swift app communicates with a separate FFmpeg executable through pipes. Its MIT license does not replace FFmpeg's LGPL-2.1-or-later license. The release hosts the exact source archive alongside binaries. The app includes upstream license text, source location and configuration under `Contents/Resources/ThirdParty/FFmpeg`. Build metadata's `binary_sha256` describes the compiled decoder before app signing; `bundled_binary_sha256` describes the separately ad-hoc signed copy inside the app.

The bundled executable may be replaced under its license. A modified app's local signature must be recreated; there is no technical restriction preventing replacement. See [third-party notices](../THIRD_PARTY_NOTICES.md) and [FFmpeg's distribution guidance](https://ffmpeg.org/legal.html).

## Icon

`Tools/GenerateIcon.swift` is the editable source for the original geometric artwork. Regenerate PNG and all ICNS sizes with:

```sh
swift Tools/GenerateIcon.swift
```

Review `Assets/AppIcon.png` after artwork changes, then commit it and `Assets/AppIcon.icns`. Normal builds copy the checked-in ICNS and do not need to regenerate artwork.

## Publish a new version

1. Update `version.json` with a new semantic version and a monotonically increasing build number. Update the changelog, release instructions and FFmpeg notices when relevant.
2. Open a PR. The required CI check builds both development and portable bundles, verifies archives and uploads preview assets. Native window changes also need desktop checks. Merge after review and passing checks.
3. Tag the merged commit as `vVERSION` and push that protected tag. Only an administrator can create release tags.
4. The Release workflow calls the same CI packaging workflow with the exact tag. After successful validation, a separate job downloads only that run's artifacts, creates a draft with all required assets, then publishes it as the latest release.
5. Verify release visibility, assets and checksums. Test a fresh download's installation and first launch before announcing broad compatibility.

Only the publishing job has repository write permissions. No signing identity, Apple account, notarization secret, camera credential or third-party publishing action is used. GitHub-owned actions are pinned by commit SHA; Dependabot proposes updates.

Published releases are not silently overwritten. If publishing fails after draft creation, inspect that draft and the workflow log before retrying; the create command fails when a release for the tag already exists. Do not move an existing published tag to fix a release—issue a new patch version. Old source-only tags remain historical snapshots and do not acquire new binary assets automatically.

Automatic in-app updates and notarization are separate future work. Developer ID signing requires an appropriate certificate and Apple notarization credentials; neither is present in this setup.
