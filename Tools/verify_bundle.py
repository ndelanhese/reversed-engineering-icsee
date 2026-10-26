"""Check a relocatable release bundle and decode synthetic video without Homebrew."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(arguments, **kwargs):
    return subprocess.check_output(arguments, stderr=kwargs.pop('stderr', subprocess.STDOUT), timeout=30, **kwargs)


def verify(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleDevelopmentRegion') != 'en' or set(info.get('CFBundleLocalizations', [])) != {'en', 'pt-BR'}:
        raise SystemExit('FAIL: bundle must declare native English and Brazilian Portuguese localization')
    for language in ['en', 'pt-BR']:
        for name in ['Localizable.strings', 'InfoPlist.strings']:
            catalog = app / f'Contents/Resources/{language}.lproj' / name
            if not catalog.is_file():
                raise SystemExit(f'FAIL: missing localization resource: {language}/{name}')
            run(['plutil', '-lint', str(catalog)])
    icon = app / 'Contents/Resources' / info.get('CFBundleIconFile', '')
    if not icon.is_file() or icon.read_bytes()[:4] != b'icns':
        raise SystemExit('FAIL: missing or invalid native app icon')
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    ffmpeg = app / 'Contents/MacOS/ffmpeg'
    if not ffmpeg.is_file():
        raise SystemExit('FAIL: release must include its standalone FFmpeg executable')
    run(['codesign', '--verify', '--deep', '--strict', str(app)])
    for binary in [executable, ffmpeg]:
        if run(['lipo', '-archs', str(binary)]).decode().strip() != 'arm64':
            raise SystemExit(f'FAIL: expected arm64 binary: {binary.name}')
        libraries = run(['otool', '-L', str(binary)]).decode().splitlines()[1:]
        for line in libraries:
            dependency = line.strip().split(' (')[0]
            if not dependency.startswith(('/usr/lib/', '/System/Library/', '@rpath/libswift')):
                raise SystemExit(f'FAIL: non-system dependency: {dependency}')
        commands = run(['otool', '-l', str(binary)]).decode()
        minimum = re.search(r'\bminos\s+(\d+)\.(\d+)', commands)
        if not minimum or tuple(map(int, minimum.groups())) > (14, 0):
            raise SystemExit(f'FAIL: minimum OS exceeds macOS 14: {binary.name}')
    notices = app / 'Contents/Resources/ThirdParty/FFmpeg'
    for name in ['COPYING.LGPLv2.1', 'LICENSE.md', 'build.json', 'SOURCE.txt']:
        if not (notices / name).is_file():
            raise SystemExit(f'FAIL: missing FFmpeg distribution notice: {name}')
    metadata = json.loads((notices / 'build.json').read_text())
    if hashlib.sha256(ffmpeg.read_bytes()).hexdigest() != metadata['bundled_binary_sha256']:
        raise SystemExit('FAIL: bundled decoder differs from its signed build metadata')
    # Run the relocated decoder with only the system PATH; no installed FFmpeg or real cameras.
    environment = {'PATH': '/usr/bin:/bin', 'TMPDIR': os.environ.get('TMPDIR', '/tmp')}
    license_text = run([str(ffmpeg), '-L'], env=environment).decode()
    if 'GNU Lesser General Public License' not in ' '.join(license_text.split()):
        raise SystemExit('FAIL: bundled decoder is not the expected LGPL build')
    formats = run([str(ffmpeg), '-hide_banner', '-demuxers'], env=environment).decode()
    if not re.search(r'\bconcat\b', formats) or not re.search(r'\brtsp\b', formats):
        raise SystemExit('FAIL: decoder lacks required concat/RTSP support')
    for name, demuxer in [('blue.h264', 'h264'), ('blue.hevc', 'hevc')]:
        for hardware in [False, True]:
            frames = run([str(ffmpeg), '-hide_banner', '-loglevel', 'error', '-threads', '1',
                *(['-hwaccel', 'videotoolbox'] if hardware else []), '-f', demuxer,
                '-i', str(ROOT / 'Tests/Fixtures' / name), '-map', '0:v:0', '-an',
                '-filter_threads', '1', '-vf', 'scale=1280:-2', '-fpsmax', '15', '-q:v', '5',
                '-threads', '1', '-c:v', 'mjpeg', '-f', 'image2pipe', 'pipe:1'],
                env=environment, stderr=subprocess.PIPE)
            if not frames.startswith(b'\xff\xd8') or not frames.endswith(b'\xff\xd9') or frames.count(b'\xff\xd8') != 2:
                raise SystemExit(f'FAIL: {demuxer} fixture did not produce two JPEG frames (hardware={hardware})')
    print('PASS: icon, strict signature, arm64/macOS 14, system-only dependencies, notices, offline H.264/HEVC decode with hardware request and software path')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python3 Tools/verify_bundle.py /path/to/App.app')
    verify(Path(sys.argv[1]).resolve())
