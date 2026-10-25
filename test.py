"""Run core and isolated native-window checks with Command Line Tools."""
import argparse
import json
import pathlib
import plistlib
import re
import shutil
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
sources = [str(p) for p in sorted((root/'Sources').rglob('*.swift')) if p.name != 'ReversedEngineeringIcseeApp.swift']
credential_test = build / 'credential-tests'
subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', *sources,
                str(root/'Tests/CredentialStoreTest.swift'), '-o', str(credential_test)], check=True)
subprocess.run([str(credential_test)], check=True)
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
subprocess.run(['swiftc','-swift-version','6','-parse-as-library',*sources,
                str(root/'Tests/LocalizationTest.swift'),'-o',str(locale_binary)],check=True)
for preferred, expected in [('en', 'en'), ('en-BR', 'en'), ('pt-BR', 'pt-BR'), ('pt-PT', 'pt-BR'),
                            ('fr-FR', 'en'), ('fr-FR, pt-BR, en', 'pt-BR')]:
    subprocess.run([str(locale_binary), '-AppleLanguages', f'({preferred})',
                    '--expected-language', expected],check=True)
if args.core_only:
    sys.exit(0)
window_test = build / 'window-tests'
subprocess.run(['swiftc','-swift-version','6','-parse-as-library',*sources,
                str(root/'Tests/CameraWindowsTest.swift'),'-o',str(window_test)],check=True)
subprocess.run([str(window_test)],check=True)
if args.interactive:
    for language in ['en', 'pt-BR']:
        subprocess.run([str(locale_binary), '-AppleLanguages', f'({language})',
                        '--expected-language', language, '--render-ui'],check=True,timeout=15)
    fullscreen_test = build / 'fullscreen-tests'
    subprocess.run(['swiftc','-swift-version','6','-parse-as-library',*sources,
                    str(root/'Tests/FullscreenTest.swift'),'-o',str(fullscreen_test)],check=True)
    subprocess.run([str(fullscreen_test)],check=True,timeout=20)
