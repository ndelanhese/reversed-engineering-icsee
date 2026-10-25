"""Run core and isolated native-window checks with Command Line Tools."""
import argparse
import pathlib
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
modes = parser.add_mutually_exclusive_group()
modes.add_argument('--core-only', action='store_true', help='Skip native windows; suitable for CI without a desktop session.')
modes.add_argument('--interactive', action='store_true', help='Also exercise native fullscreen and Escape in a desktop session.')
args = parser.parse_args()

root = pathlib.Path(__file__).resolve().parent
build = root / '.build-tests'
build.mkdir(exist_ok=True)
core = root / 'Sources/CameraCore/CameraCore.swift'
core_test = build / 'core-tests'
subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(core),
                str(root/'Tests/CoreSelfTest.swift'),'-o',str(core_test)],check=True)
subprocess.run([str(core_test)],check=True)
if args.core_only:
    sys.exit(0)
sources = [str(p) for p in sorted((root/'Sources').rglob('*.swift')) if p.name != 'CamMacApp.swift']
window_test = build / 'window-tests'
subprocess.run(['swiftc','-swift-version','6','-parse-as-library',*sources,
                str(root/'Tests/CameraWindowsTest.swift'),'-o',str(window_test)],check=True)
subprocess.run([str(window_test)],check=True)
if args.interactive:
    fullscreen_test = build / 'fullscreen-tests'
    subprocess.run(['swiftc','-swift-version','6','-parse-as-library',*sources,
                    str(root/'Tests/FullscreenTest.swift'),'-o',str(fullscreen_test)],check=True)
    subprocess.run([str(fullscreen_test)],check=True,timeout=20)
