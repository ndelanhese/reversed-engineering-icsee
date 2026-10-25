"""Build the native app with Command Line Tools; no Xcode project required."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess

from Tools.local_sign import existing_identity, sign

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', nargs='?', help='Destination .app bundle.')
parser.add_argument('--bundle-ffmpeg', action='store_true', help='Include the decoder built by Tools/build_ffmpeg.py.')
parser.add_argument('--sign-identity', help='Certificate fingerprint; "-" forces ad-hoc signing. Default: reuse local identity if present.')
args = parser.parse_args()
identity = args.sign_identity or existing_identity() or "-"
root = pathlib.Path(__file__).resolve().parent
version = json.loads((root / 'version.json').read_text())
app_name = 'Reversed engineering Icsee'
executable_name = 'ReversedEngineeringIcsee'
app = pathlib.Path(args.output).resolve() if args.output else root / 'dist' / (app_name + '.app')
binary = app / 'Contents' / 'MacOS' / executable_name
resources = app / 'Contents/Resources'
binary.parent.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
localizations = sorted((root / 'Resources').glob('*.lproj'))
for previous in resources.glob('*.lproj'):
    shutil.rmtree(previous)
for localization in localizations:
    shutil.copytree(localization, resources / localization.name, dirs_exist_ok=True)
shutil.copy2(root / 'Assets/AppIcon.icns', resources / 'AppIcon.icns')
for name in ['LICENSE', 'THIRD_PARTY_NOTICES.md']:
    shutil.copy2(root / name, resources / name)
decoder = binary.parent / 'ffmpeg'
notices = resources / 'ThirdParty/FFmpeg'
if args.bundle_ffmpeg:
    decoder_build = root / '.build/ffmpeg'
    if not (decoder_build / 'bin/ffmpeg').is_file():
        raise SystemExit('Run python3 Tools/build_ffmpeg.py before bundling the release decoder.')
    decoder_metadata = json.loads((decoder_build / 'build.json').read_text())
    decoder_hash = hashlib.sha256((decoder_build / 'bin/ffmpeg').read_bytes()).hexdigest()
    if decoder_hash != decoder_metadata['binary_sha256']:
        raise SystemExit('Decoder differs from build metadata. Rebuild it before packaging.')
    shutil.copy2(decoder_build / 'bin/ffmpeg', decoder)
    notices.mkdir(parents=True, exist_ok=True)
    for name in ['COPYING.LGPLv2.1', 'LICENSE.md']:
        shutil.copy2(decoder_build / 'licenses' / name, notices / name)
    archive_name = pathlib.Path(decoder_metadata['source_url']).name
    source_url = ('https://github.com/ndelanhese/reversed-engineering-icsee/releases/download/'
                  f'v{version["version"]}/{archive_name}')
    (notices / 'SOURCE.txt').write_text('FFmpeg source, unchanged: ' + source_url + '\n'
        'License: LGPL-2.1-or-later. Configuration: build.json.\n'
        'Rebuild instructions: Tools/build_ffmpeg.py in the matching project source release.\n')
    subprocess.run(['codesign', '--force', '--sign', '-', str(decoder)], check=True)
    decoder_metadata['bundled_binary_sha256'] = hashlib.sha256(decoder.read_bytes()).hexdigest()
    (notices / 'build.json').write_text(json.dumps(decoder_metadata, indent=2) + '\n')
else:
    decoder.unlink(missing_ok=True)
    if notices.exists():
        shutil.rmtree(notices)
sources = sorted((root / 'Sources').rglob('*.swift'))
subprocess.run(['swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos14.0', '-parse-as-library', '-O',
                *map(str, sources), '-o', str(binary)], check=True)
# Keep the original storage identity so existing camera profiles stay available.
info = {'CFBundleName': app_name, 'CFBundleDisplayName': app_name,
        'CFBundleIdentifier': 'local.CamMac', 'CFBundleExecutable': executable_name,
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': version['version'],
        'CFBundleVersion': str(version['build']), 'LSMinimumSystemVersion': '14.0',
        'CFBundleIconFile': 'AppIcon.icns', 'LSApplicationCategoryType': 'public.app-category.video',
        'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': [p.stem for p in localizations],
        'NSHighResolutionCapable': True,
        'NSLocalNetworkUsageDescription': app_name + ' connects directly to cameras on your local network.'}
with (app / 'Contents' / 'Info.plist').open('wb') as handle:
    plistlib.dump(info, handle)
sign(app, identity)
print(app)
