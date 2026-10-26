#!/usr/bin/env python3
"""Build Android from pinned sources and verify native libraries before distribution."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import secrets
import shutil
import struct
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent
GRADLE_VERSION = "9.4.1"
GRADLE_SHA256 = "2ab2958f2a1e51120c326cad6f385153bb11ee93b3c216c5fccebfdfbb7ec6cb"
NDK_VERSION = "29.0.14206865"
TARGETS = {"arm64-v8a": "aarch64-linux-android", "x86_64": "x86_64-linux-android"}

def run(args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)

def check_elf_alignment(data):
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01":
        raise ValueError("Expected a complete little-endian ELF64")
    offset = struct.unpack_from("<Q", data, 32)[0]
    size, count = struct.unpack_from("<HH", data, 54)
    if size < 56 or count > 1024 or offset + size * count > len(data):
        raise ValueError("Invalid ELF program headers")
    loads = 0
    for index in range(count):
        start = offset + index * size
        if struct.unpack_from("<I", data, start)[0] != 1:
            continue
        loads += 1
        file_offset, address, _, file_size, _, alignment = struct.unpack_from("<QQQQQQ", data, start + 8)
        if alignment < 16384 or (address - file_offset) % 16384 != 0 or file_offset + file_size > len(data):
            raise ValueError("Native library is not compatible with 16-KiB pages")
    if loads == 0:
        raise ValueError("ELF has no loadable segments")

def verify_apk(apk, sdk, signed):
    tools = sdk / "build-tools/37.0.0"
    run([tools / "zipalign", "-c", "-P", "16", "4", apk])
    libraries = set()
    with zipfile.ZipFile(apk) as archive, open(apk, "rb") as source:
        assert not any(n.startswith(("assets/lua/", "assets/hrtfs/")) for n in archive.namelist()), "Unused LibVLC assets must not ship"
        for entry in archive.infolist():
            if entry.filename.startswith("lib/") and entry.filename.endswith(".so"):
                check_elf_alignment(archive.read(entry))
                libraries.add(entry.filename.split("/")[1])
                if entry.compress_type == zipfile.ZIP_STORED:
                    source.seek(entry.header_offset)
                    header = source.read(30)
                    name, extra = struct.unpack_from("<HH", header, 26)
                    assert (entry.header_offset + 30 + name + extra) % 16384 == 0, entry.filename
    assert libraries == set(TARGETS), libraries
    if signed:
        run([tools / "apksigner", "verify", "--verbose", "--print-certs", apk])

def gradle():
    if os.environ.get("GRADLE_HOME"):
        return Path(os.environ["GRADLE_HOME"]) / "bin/gradle"
    cache = Path.home() / ".cache/reversed-icsee"
    cache.mkdir(parents=True, exist_ok=True)
    binary = cache / f"gradle-{GRADLE_VERSION}/bin/gradle"
    if not binary.exists():
        archive = cache / f"gradle-{GRADLE_VERSION}-bin.zip"
        run(["curl", "--fail", "--location", "--retry", "3", "--output", archive,
             f"https://downloads.gradle.org/distributions/gradle-{GRADLE_VERSION}-bin.zip"])
        assert hashlib.sha256(archive.read_bytes()).hexdigest() == GRADLE_SHA256, "Gradle checksum mismatch"
        with zipfile.ZipFile(archive) as z:
            z.extractall(cache)
        binary.chmod(0o755)
    return binary

def local_signer(java_home):
    directory = Path.home() / ".local/share/reversed-engineering-icsee/android-signing"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = directory / "signing.json"
    if metadata.exists():
        config = json.loads(metadata.read_text())
        assert Path(config["keystore"]).is_file(), "Saved signing key missing; restore it instead of replacing it."
        return config
    keystore = directory / "release.p12"
    assert not keystore.exists(), "Signing key already exists without metadata. Restore metadata; do not replace the key."
    password = secrets.token_urlsafe(32)
    env = os.environ | {"ICSEE_SIGNING_PASSWORD": password}
    run([java_home / "bin/keytool", "-genkeypair", "-keystore", keystore, "-storetype", "PKCS12",
         "-storepass:env", "ICSEE_SIGNING_PASSWORD", "-keypass:env", "ICSEE_SIGNING_PASSWORD",
         "-alias", "icsee", "-keyalg", "RSA", "-keysize", "3072", "-validity", "36500",
         "-dname", "CN=Reversed engineering Icsee Android"], env=env)
    keystore.chmod(0o600)
    config = {"keystore": str(keystore), "alias": "icsee", "password": password}
    descriptor = os.open(metadata, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as output:
        json.dump(config, output)
    return config

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sign", action="store_true", help="Reuse/create a private local Android release signer; never upload it.")
    parser.add_argument("--device-tests", action="store_true", help="Run Android tests on ANDROID_SERIAL after the build.")
    args = parser.parse_args()
    sdk = Path(os.environ["ANDROID_HOME"]).resolve()
    java_home = Path(os.environ["JAVA_HOME"]).resolve()
    host = "darwin-x86_64" if platform.system() == "Darwin" else "linux-x86_64"
    toolchain = sdk / f"ndk/{NDK_VERSION}/toolchains/llvm/prebuilt/{host}/bin"
    assert toolchain.is_dir(), f"Install Android NDK {NDK_VERSION}"
    assert (sdk / "platforms/android-37.0/android.jar").is_file(), "Install platforms;android-37.0"
    env = os.environ.copy()
    env["CARGO_TARGET_DIR"] = str(ROOT / "native/target")
    env.pop("RUSTFLAGS", None)
    env["CARGO_ENCODED_RUSTFLAGS"] = "\x1f".join([
        "-C", "link-arg=-Wl,-z,max-page-size=16384",
        f"--remap-path-prefix={ROOT}=/icsee-android",
        f"--remap-path-prefix={Path.home() / '.cargo'}=/cargo",
    ])
    cargo_args = ["cargo", "build", "--locked", "--release"]
    for abi, target in TARGETS.items():
        env[f"CARGO_TARGET_{target.upper().replace('-', '_')}_LINKER"] = str(toolchain / f"{target}28-clang")
        cargo_args += ["--target", target]
    run(["cargo", "test", "--locked"], cwd=ROOT / "native")
    run(cargo_args, cwd=ROOT / "native", env=env)
    for abi, target in TARGETS.items():
        output = ROOT / f"app/src/main/jniLibs/{abi}"
        output.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / f"native/target/{target}/release/libicsee_core.so", output)
    tasks = [":app:testDebugUnitTest", ":app:lintRelease", ":app:assembleRelease"]
    if args.device_tests:
        assert os.environ.get("ANDROID_SERIAL"), "Set ANDROID_SERIAL explicitly for device tests"
        tasks.append(":app:connectedDebugAndroidTest")
    run([gradle(), "--no-daemon", "--console=plain", *tasks], cwd=ROOT, env=env)
    source = ROOT / "app/build/outputs/apk/release/app-release-unsigned.apk"
    metadata = json.loads((source.parent / "output-metadata.json").read_text())
    version = metadata["elements"][0]["versionName"]
    output = ROOT.parent / "dist/android"
    output.mkdir(parents=True, exist_ok=True)
    apk = output / f"reversed-engineering-icsee-android-{version}{'' if args.sign else '-unsigned'}.apk"
    if args.sign:
        config = local_signer(java_home)
        sign_env = env | {"ICSEE_SIGNING_PASSWORD": config["password"]}
        run([sdk / "build-tools/37.0.0/apksigner", "sign", "--ks", config["keystore"],
             "--ks-key-alias", config["alias"], "--ks-pass", "env:ICSEE_SIGNING_PASSWORD",
             "--key-pass", "env:ICSEE_SIGNING_PASSWORD", "--out", apk, source], env=sign_env)
    else:
        shutil.copy2(source, apk)
    verify_apk(apk, sdk, args.sign)
    digest = hashlib.sha256(apk.read_bytes()).hexdigest()
    (output / f"{apk.name}.sha256").write_text(f"{digest}  {apk.name}\n")
    print(f"Verified {'signed' if args.sign else 'unsigned'} APK: {apk}")

if __name__ == "__main__":
    main()
