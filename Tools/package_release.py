"""Build, verify and package a self-contained Apple Silicon release. Never publishes."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

from build_ffmpeg import ARCHIVE, ARCHIVE_NAME, BUILD, SOURCE_SHA256
from verify_bundle import verify

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = 'https://github.com/ndelanhese/reversed-engineering-icsee'
APP_NAME = 'Reversed engineering Icsee.app'


def run(arguments):
    subprocess.run(arguments, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', help='When provided, must equal the version in version.json.')
    args = parser.parse_args()
    version = json.loads((ROOT / 'version.json').read_text())['version']
    if args.tag and args.tag != f'v{version}':
        raise SystemExit(f'Refusing release: tag {args.tag!r} does not match v{version}.')
    if not (BUILD / 'bin/ffmpeg').is_file() or not ARCHIVE.is_file():
        raise SystemExit('Run python3 Tools/build_ffmpeg.py first.')
    if hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() != SOURCE_SHA256:
        raise SystemExit('FFmpeg source archive does not match the pinned checksum.')
    output = ROOT / 'dist/release'
    output.mkdir(parents=True, exist_ok=True)
    prefix = f'Reversed-engineering-Icsee-{version}-macos-arm64'
    source_url = f'{REPOSITORY}/releases/download/v{version}/{ARCHIVE_NAME}'
    with tempfile.TemporaryDirectory(prefix='release-', dir=ROOT / '.build') as temporary:
        stage = Path(temporary)
        image_root = stage / 'image'
        image_root.mkdir()
        app = image_root / APP_NAME
        run([sys.executable, str(ROOT / 'build.py'), str(app), '--bundle-ffmpeg'])
        verify(app)
        (image_root / 'Applications').symlink_to('/Applications')
        instructions = f'''Reversed engineering Icsee {version}

Instalar / Install: arraste o app para Applications / drag the app to Applications.
Requer / Requires: Apple Silicon, macOS 14+. FFmpeg included. No Homebrew required.

Assinatura local ad hoc, sem notarização / Ad-hoc signed, not notarized.
Se o macOS bloquear e você confiar neste download: Ajustes do Sistema > Privacidade
e Segurança > Abrir Mesmo Assim. If macOS blocks it and you trust this download:
System Settings > Privacy & Security > Open Anyway.
https://support.apple.com/en-us/102445

Código / Source: {REPOSITORY}/tree/v{version}
This app uses FFmpeg under LGPL-2.1-or-later. Exact unmodified FFmpeg source:
{source_url}
Licenses and build configuration: app Contents/Resources/ThirdParty/FFmpeg.
'''
        (image_root / 'READ-ME.txt').write_text(instructions)
        dmg = output / f'{prefix}.dmg'
        zip_path = output / f'{prefix}.zip'
        run(['hdiutil', 'create', '-volname', 'Reversed engineering Icsee', '-srcfolder',
             str(image_root), '-fs', 'HFS+', '-format', 'UDZO', '-ov', str(dmg)])
        zip_path.unlink(missing_ok=True)
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(zip_path)])
        # Verify the distributed archives, not only the staging directory.
        unzipped = stage / 'unzipped'
        run(['ditto', '-x', '-k', str(zip_path), str(unzipped)])
        verify(unzipped / APP_NAME)
        mounted = stage / 'mounted'
        mounted.mkdir()
        attachment = subprocess.check_output(['hdiutil', 'attach', '-readonly', '-nobrowse',
            '-mountpoint', str(mounted), '-plist', str(dmg)])
        devices = plistlib.loads(attachment)['system-entities']
        if not any(entity.get('mount-point') == str(mounted) for entity in devices):
            raise SystemExit('DMG did not mount at the expected verification directory.')
        try:
            verify(mounted / APP_NAME)
        finally:
            run(['hdiutil', 'detach', str(mounted)])
        shutil.copy2(ARCHIVE, output / ARCHIVE_NAME)
        shutil.copy2(app / 'Contents/Resources/ThirdParty/FFmpeg/build.json', output / 'ffmpeg-build.json')
    names = [f'{prefix}.dmg', f'{prefix}.zip', ARCHIVE_NAME, 'ffmpeg-build.json']
    checksum_lines = []
    for name in names:
        with (output / name).open('rb') as handle:
            checksum_lines.append(f'{hashlib.file_digest(handle, "sha256").hexdigest()}  {name}')
    (output / 'SHA256SUMS.txt').write_text('\n'.join(checksum_lines) + '\n')
    notes = f'''Native macOS viewer for iCSee / Xiongmai cameras. Apple Silicon, macOS 14+.

## Instalar / Install

- Download **{prefix}.dmg**, open it, and drag the app to **Applications**. ZIP is an alternative.
- Baixe **{prefix}.dmg**, abra e arraste o app para **Applications**. ZIP também disponível.
- FFmpeg is included; no Homebrew, compiler or Python needed to run the app.
- Original app icon included in Finder and Dock. Existing camera profiles and Keychain service are preserved.

## Signing / Assinatura

Ad-hoc signed, **not Developer ID signed or notarized**. macOS may block the first launch.
After checking the source and download, use System Settings → Privacy & Security → Open Anyway if you trust it.
Em português: Ajustes do Sistema → Privacidade e Segurança → Abrir Mesmo Assim.
[Apple's instructions](https://support.apple.com/en-us/102445). Gatekeeper is not disabled by the installer.

## Licensing and integrity

This app uses [FFmpeg](https://ffmpeg.org/) under **LGPL-2.1-or-later** as a separate executable.
[Download its exact unmodified source]({source_url}); configure arguments and binary hashes are in **ffmpeg-build.json**.
Original app source and icon are MIT licensed. Licenses are included in the app bundle.
**SHA256SUMS.txt** covers the app archives, FFmpeg source and build metadata.

## Scope

Local RTSP video, grid, cinema, floating windows and native fullscreen. No audio, PTZ, recording or cloud login.
Remote access requires an existing VPN. Compatibility is firmware-dependent; these builds do not certify every iCSee device.
No automatic updater is installed.

## Validation

Core checks and strict ad-hoc signatures; app and decoder target arm64/macOS 14.
DMG and ZIP are opened and their bundled H.264/HEVC decoder is tested offline with synthetic frames and a system-only PATH.
Release packaging is performed without camera profiles, private footage or live credentials.
'''
    (output / 'RELEASE_NOTES.md').write_text(notes)
    print(f'Release assets ready: {output}')


if __name__ == '__main__':
    main()
