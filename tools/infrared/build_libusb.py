#!/usr/bin/env python3
"""Build pinned libusb with Xcode tools; no Homebrew or administrator access."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile

VERSION = "1.0.29"
SHA256 = "5977fc950f8d1395ccea9bd48c06b3f808fd3c2c961b44b0c2e6e29fc3a70a85"
URL = f"https://github.com/libusb/libusb/releases/download/v{VERSION}/libusb-{VERSION}.tar.bz2"


def build_libusb(directory: Path, architecture: str, minimum_macos: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    prefix = directory / "installed"
    configuration = {"sha256": SHA256, "arch": architecture, "minimum_macos": minimum_macos}
    stamp = directory / "build-info.json"
    if stamp.exists() and json.loads(stamp.read_text()) == configuration and (prefix / "lib/libusb-1.0.a").exists():
        return prefix
    archive = directory / f"libusb-{VERSION}.tar.bz2"
    if not archive.exists():
        temporary = archive.with_suffix(".download")
        subprocess.run(["curl", "--fail", "--location", "--proto", "=https", "--tlsv1.2", "--retry", "3", "--output", str(temporary), URL], check=True)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != SHA256:
            raise RuntimeError("libusb download checksum mismatch")
        temporary.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError("Cached libusb archive checksum mismatch")
    source = directory / f"libusb-{VERSION}"
    if not source.exists():
        with tarfile.open(archive) as bundle:
            for member in bundle.getmembers():
                target = (directory / member.name).resolve()
                if not target.is_relative_to(directory.resolve()) or member.issym() or member.islnk():
                    raise RuntimeError("Unexpected path/link in libusb source archive")
            bundle.extractall(directory)
    objects = directory / "objects"
    objects.mkdir(exist_ok=True)
    env = dict(os.environ, CC="clang", CFLAGS=f"-O2 -arch {architecture} -mmacosx-version-min={minimum_macos}",
               LDFLAGS=f"-arch {architecture} -mmacosx-version-min={minimum_macos}")
    env["CC"] = "/usr/bin/xcrun clang"
    env["SDKROOT"] = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    with (directory / "build.log").open("w") as log:
        def run(*args):
            subprocess.run([str(item) for item in args], cwd=objects, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        run(source / "configure", f"--prefix={prefix}", "--disable-shared", "--enable-static",
            f"--host={architecture}-apple-darwin", f"--build={platform.machine()}-apple-darwin")
        run("make", "-j4")
        run("make", "install")
    shutil.copyfile(source / "COPYING", prefix / "COPYING")
    stamp.write_text(json.dumps(configuration))
    return prefix
