"""Run core and isolated native-window checks with Command Line Tools."""
import argparse
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import select

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
subprocess.run(['swiftc','-swift-version','6','-target','arm64-apple-macos14.0','-parse-as-library',str(core),
                str(root/'Tests/CoreSelfTest.swift'),'-o',str(core_test)],check=True)
subprocess.run([str(core_test)],check=True)

def run_control_fixture(binary, arguments=(), server_arguments=(), timeout=25):
    server = subprocess.Popen([sys.executable, str(root/'Tests/ControlFixtureServer.py'), *server_arguments],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        ready, _, _ = select.select([server.stdout], [], [], 10)
        if not ready:
            server.terminate()
            try:
                _, diagnostics = server.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                _, diagnostics = server.communicate()
            raise RuntimeError('Local control fixture did not start in time. ' + diagnostics[-2000:])
        ports = json.loads(server.stdout.readline())
        subprocess.run([str(binary), str(ports['onvifPort']), str(ports['controlPort']), *arguments],
                       check=True, timeout=timeout)
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()

sources = [str(p) for p in sorted((root/'Sources').rglob('*.swift')) if p.name != 'ReversedEngineeringIcseeApp.swift']
control_tests = [
    ('onvif-control', ['Sources/CameraControl/ONVIFTypes.swift', 'Sources/CameraControl/ONVIFClient.swift'], 'Tests/ONVIFControlTest.swift', 30),
    ('dvrip-control', ['Sources/CameraCore/CameraCore.swift', 'Sources/CameraControl/DeviceJSON.swift', 'Sources/CameraControl/DVRIPClient.swift'], 'Tests/DVRIPControlTest.swift', 30),
    ('device-settings-editor', ['Sources/CameraControl/DeviceJSON.swift', 'Sources/ReversedEngineeringIcsee/DeviceSettingsEditor.swift'], 'Tests/DeviceSettingsEditorTest.swift', 15),
    ('camera-control-model', None, 'Tests/CameraControlModelTest.swift', 15),
    ('recording-protocol', ['Sources/CameraCore/CameraCore.swift', 'Sources/CameraControl/DeviceJSON.swift', 'Sources/CameraControl/DVRIPClient.swift', 'Sources/CameraRecordings/RecordingTypes.swift', 'Sources/CameraRecordings/DVRIPRecordingClient.swift'], 'Tests/RecordingProtocolTest.swift', 45),
    ('recording-media', ['Sources/CameraRecordings/RecordingMedia.swift', 'Sources/CameraRecordings/RecordingMovieWriter.swift'], 'Tests/RecordingMediaTest.swift', 60),
    ('recording-presentation', ['Sources/ReversedEngineeringIcsee/RecordingPresentation.swift'], 'Tests/RecordingPresentationTest.swift', 15),
]
for name, files, test, timeout in control_tests:
    binary = build / name
    inputs = [str(root/path) for path in files] if files else sources
    subprocess.run(['swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos14.0', '-parse-as-library', *inputs, str(root/test), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=timeout)

recording_raw = build / 'recording-fixture.xm'
subprocess.run([str(build/'recording-media'), '--write-fixture', str(recording_raw)], check=True)

def run_recording_fixture(arguments=()):
    peer = subprocess.Popen([sys.executable, str(root/'Tests/RecordingFixtureServer.py'), str(recording_raw)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        if not select.select([peer.stdout], [], [], 10)[0]:
            raise RuntimeError('Synthetic recording peer did not start.')
        ports = json.loads(peer.stdout.readline())
        subprocess.run([str(build/'camera-recordings'), str(ports['controlPort']), *arguments], check=True, timeout=45)
    finally:
        peer.terminate()
        try:
            peer.wait(timeout=5)
        except subprocess.TimeoutExpired:
            peer.kill(); peer.wait()

subprocess.run(['swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos14.0', '-parse-as-library', *sources,
                str(root/'Tests/CameraRecordingsTest.swift'), '-o', str(build/'camera-recordings')], check=True)
run_recording_fixture()

flow_test = build / 'camera-control-flow'
subprocess.run(['swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos14.0', '-parse-as-library', *sources,
                str(root/'Tests/CameraControlFlowTest.swift'), '-o', str(flow_test)], check=True)
run_control_fixture(flow_test)
run_control_fixture(flow_test, server_arguments=('--array-camera-param',))
credential_test = build / 'credential-tests'
subprocess.run(['swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos14.0', '-parse-as-library', *sources,
                str(root/'Tests/CredentialStoreTest.swift'), '-o', str(credential_test)], check=True)
subprocess.run([str(credential_test)], check=True)
selection_test = build / 'menu-selection-tests'
subprocess.run(['swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos14.0', '-parse-as-library', *sources,
                str(root/'Tests/MenuBarSelectionTest.swift'), '-o', str(selection_test)], check=True)
subprocess.run([str(selection_test)], check=True)
locale_app = build / 'LocalizationFixture.app'
locale_binary = locale_app / 'Contents/MacOS/localization-tests'
locale_binary.parent.mkdir(parents=True, exist_ok=True)
locale_resources = locale_app / 'Contents/Resources'
if locale_resources.exists():
    shutil.rmtree(locale_resources)
locale_resources.mkdir()
for localization in (root / 'Resources').glob('*.lproj'):
    shutil.copytree(localization, locale_resources / localization.name)
catalogs = {}
for language in ['en', 'pt-BR']:
    catalog = root / f'Resources/{language}.lproj/Localizable.strings'
    catalogs[language] = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(catalog)]))
assert catalogs['en'].keys() == catalogs['pt-BR'].keys(), 'Translations must cover the same keys.'
for key in catalogs['en']:
    placeholders = sorted(re.findall(r'%(?:lld|@)', key))
    for language in catalogs:
        assert sorted(re.findall(r'%(?:lld|@)', catalogs[language][key])) == placeholders, (language, key)
print('PASS: translation coverage and typed interpolation placeholders')
info = {'CFBundleExecutable': 'localization-tests', 'CFBundleIdentifier': 'local.REI.localization-tests',
        'CFBundlePackageType': 'APPL', 'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': ['en', 'pt-BR']}
(locale_app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['swiftc','-swift-version','6','-target','arm64-apple-macos14.0','-parse-as-library',*sources,
                str(root/'Tests/LocalizationTest.swift'),'-o',str(locale_binary)],check=True)
for preferred, expected in [('en', 'en'), ('en-BR', 'en'), ('pt-BR', 'pt-BR'), ('pt-PT', 'pt-BR'),
                            ('fr-FR', 'en'), ('fr-FR, pt-BR, en', 'pt-BR')]:
    subprocess.run([str(locale_binary), '-AppleLanguages', f'({preferred})',
                    '--expected-language', expected],check=True)
if args.core_only:
    sys.exit(0)
window_test = build / 'window-tests'
subprocess.run(['swiftc','-swift-version','6','-target','arm64-apple-macos14.0','-parse-as-library',*sources,
                str(root/'Tests/CameraWindowsTest.swift'),'-o',str(window_test)],check=True)
subprocess.run([str(window_test)],check=True)
if args.interactive:
    run_recording_fixture(('--window',))
    controls_window_test = build / 'camera-controls-window'
    subprocess.run(['swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos14.0', '-parse-as-library', *sources,
                    str(root/'Tests/CameraControlsWindowTest.swift'), '-o', str(controls_window_test)], check=True)
    run_control_fixture(controls_window_test)
    run_control_fixture(controls_window_test, arguments=('--shutdown-move',))
    run_control_fixture(controls_window_test, arguments=('--shutdown-preset',))
    menu_test = build / 'menu-preview-tests'
    subprocess.run(['swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos14.0', '-parse-as-library', *sources,
                    str(root/'Tests/MenuBarPreviewTest.swift'), '-o', str(menu_test)], check=True)
    subprocess.run([str(menu_test)], check=True, timeout=20)
    scene_test = build / 'menu-scene-tests'
    subprocess.run(['swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos14.0', '-parse-as-library', *sources,
                    str(root/'Tests/MenuBarSceneTest.swift'), '-o', str(scene_test)], check=True)
    subprocess.run([str(scene_test)], check=True, timeout=20)
    for language in ['en', 'pt-BR']:
        subprocess.run([str(locale_binary), '-AppleLanguages', f'({language})',
                        '--expected-language', language, '--render-ui'],check=True,timeout=15)
    fullscreen_test = build / 'fullscreen-tests'
    subprocess.run(['swiftc','-swift-version','6','-target','arm64-apple-macos14.0','-parse-as-library',*sources,
                    str(root/'Tests/FullscreenTest.swift'),'-o',str(fullscreen_test)],check=True)
    subprocess.run([str(fullscreen_test)],check=True,timeout=20)
