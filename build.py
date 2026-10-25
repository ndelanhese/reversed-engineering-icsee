"""Build the native app with Command Line Tools; no Xcode project required."""
import pathlib
import plistlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent
app = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root / 'dist' / 'CamMac.app'
binary = app / 'Contents' / 'MacOS' / 'CamMac'
binary.parent.mkdir(parents=True, exist_ok=True)
sources = sorted((root / 'Sources').rglob('*.swift'))
subprocess.run(['swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos14.0', '-parse-as-library', '-O',
                *map(str, sources), '-o', str(binary)], check=True)
info = {'CFBundleName': 'CamMac', 'CFBundleDisplayName': 'CamMac',
        'CFBundleIdentifier': 'local.CamMac', 'CFBundleExecutable': 'CamMac',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.2.1',
        'CFBundleVersion': '4', 'LSMinimumSystemVersion': '14.0',
        'NSHighResolutionCapable': True,
        'NSLocalNetworkUsageDescription': 'CamMac conecta diretamente às suas câmeras na rede local.'}
with (app / 'Contents' / 'Info.plist').open('wb') as handle:
    plistlib.dump(info, handle)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print(app)
