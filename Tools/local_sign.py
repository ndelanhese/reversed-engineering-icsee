"""Use a persistent, machine-local signing identity for Keychain continuity.

Private key material travels only through pipes and is imported non-extractable.
This is local signing, not Developer ID signing or notarization.
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

LABEL = 'Reversed engineering Icsee Local Signing'
ROOT = Path(__file__).resolve().parents[1]


def existing_identity():
    output = subprocess.check_output(['/usr/bin/security', 'find-identity', '-p', 'codesigning'], text=True)
    identities = set(re.findall(r'([A-F0-9]{40}) "' + re.escape(LABEL) + r'"', output))
    if len(identities) > 1:
        raise SystemExit('Multiple local signing identities found; select a fingerprint with --sign-identity.')
    return next(iter(identities), None)


def create_identity():
    identity = existing_identity()
    if identity:
        return identity
    config = b'[req]\ndistinguished_name=dn\nx509_extensions=sign\n[dn]\n[sign]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n'
    with tempfile.TemporaryDirectory(prefix='rei-signing-') as temporary:
        helper = Path(temporary) / 'import-identity'
        subprocess.run(['swiftc', '-suppress-warnings', str(ROOT/'Tools/ImportSigningIdentity.swift'), '-o', str(helper)], check=True)
        generated = subprocess.run(['/usr/bin/openssl', 'req', '-new', '-x509', '-newkey', 'rsa:3072',
            '-nodes', '-days', '3650', '-subj', '/CN=' + LABEL, '-config', '/dev/stdin',
            '-keyout', '/dev/stdout', '-out', '/dev/stdout'], input=config, capture_output=True)
        if generated.returncode:
            raise SystemExit('Could not generate local signing identity.')
        imported = subprocess.run([str(helper)], input=generated.stdout, capture_output=True)
        if imported.returncode:
            raise SystemExit('Keychain import failed: ' + imported.stderr.decode(errors='replace'))
        fingerprint = imported.stdout.decode().strip()
        if not re.fullmatch('[A-F0-9]{40}', fingerprint):
            raise SystemExit('Keychain import returned no certificate fingerprint.')
    if existing_identity() != fingerprint:
        raise SystemExit('Imported identity is not available for code signing.')
    return fingerprint


def sign(app, identity):
    # Leave the decoder signature intact: its hash is part of the bundled LGPL build metadata.
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity, str(app)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path, help='Existing app bundle to sign locally; camera data is untouched.')
    parser.add_argument('--create', action='store_true', help='Create the persistent local identity if absent.')
    args = parser.parse_args()
    app = args.app.resolve()
    if not app.is_dir() or app.suffix != '.app':
        parser.error('Expected an existing .app bundle.')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    identity = create_identity() if args.create else existing_identity()
    if not identity:
        raise SystemExit('No local identity. Use --create once, then reuse it for every update.')
    sign(app, identity)
    print('Locally signed with certificate ' + identity)
    print('Existing saved passwords may need one final macOS Keychain authorization.')


if __name__ == '__main__':
    main()
