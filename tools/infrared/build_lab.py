#!/usr/bin/env python3
"""Package the shared Glance IR panel as an isolated app for hardware testing."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper", type=Path)
    parser.add_argument("output_zip", type=Path)
    args = parser.parse_args()
    archive = args.output_zip.resolve()
    if archive.suffix != ".zip":
        parser.error("output_zip must end in .zip")
    archive.parent.mkdir(parents=True, exist_ok=True)
    # Stage outside iCloud/File Provider directories: Finder metadata added to
    # .app folders there can invalidate signing while codesign is running.
    with tempfile.TemporaryDirectory(prefix="glance-ir-lab-") as temporary:
        app = Path(temporary) / "Glance IR Lab.app"
        executable = app / "Contents/MacOS/GlanceIRLab"
        resources = app / "Contents/Resources"
        executable.parent.mkdir(parents=True)
        resources.mkdir(parents=True)
        sources = sorted((ROOT / "glance/Infrared").glob("*.swift"))
        run("xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-O",
            *sources, HERE / "IRLabApp.swift", "-o", executable)
        shutil.copyfile(args.helper, resources / "brio-ir-probe")
        (resources / "brio-ir-probe").chmod(0o755)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "local.glance.ir-lab",
            "CFBundleName": "Glance IR Lab",
            "CFBundleExecutable": "GlanceIRLab",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1",
            "LSMinimumSystemVersion": "15.0",
            "NSHighResolutionCapable": True,
        }))
        shutil.copyfile(HERE / "README.md", resources / "README.md")
        shutil.copytree(args.helper.resolve().parent / "Licenses", resources / "Licenses")
        run("codesign", "--force", "--sign", "-", resources / "brio-ir-probe")
        run("codesign", "--force", "--sign", "-", app)
        run("codesign", "--verify", "--deep", "--strict", app)
        # ZIP excludes extended attributes and preserves executable mode bits.
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as zipped:
            for path in app.rglob("*"):
                if path.is_file():
                    zipped.write(path, path.relative_to(app.parent))
    print(f"Built and verified {archive}")


if __name__ == "__main__":
    main()
