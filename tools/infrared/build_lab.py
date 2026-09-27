#!/usr/bin/env python3
"""Package the shared Glance IR panel as an isolated app for hardware testing."""
import argparse
import json
from pathlib import Path
import platform
import plistlib
import re
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
    parser.add_argument("--sign-identity", help="Signing identity for the optional SMAppService helper")
    parser.add_argument("--team-id", help="Ten-character team ID belonging to that identity")
    args = parser.parse_args()
    if bool(args.sign_identity) != bool(args.team_id):
        parser.error("--sign-identity and --team-id must be provided together")
    if args.team_id and not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
        parser.error("Invalid signing team ID")
    metadata = json.loads((args.helper.resolve().parent / "build-info.json").read_text())
    minimum_macos = metadata["minimum_macos"]
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", minimum_macos):
        raise RuntimeError("Invalid deployment target in probe build metadata")
    target = platform.machine() + "-apple-macosx" + minimum_macos
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
        run("xcrun", "swiftc", "-target", target, "-parse-as-library", "-swift-version", "5", "-O",
            *sources, HERE / "IRLabApp.swift", "-o", executable)
        shutil.copyfile(args.helper, resources / "brio-ir-probe")
        (resources / "brio-ir-probe").chmod(0o755)
        info = {
            "CFBundleIdentifier": "local.glance.ir-lab",
            "CFBundleName": "Glance IR Lab",
            "CFBundleExecutable": "GlanceIRLab",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.2.1",
            "LSMinimumSystemVersion": minimum_macos,
            "NSHighResolutionCapable": True,
            "NSCameraUsageDescription": "Show a five-second infrared camera test when you request it.",
        }
        identity = args.sign_identity or "-"
        signing = ["--options", "runtime", "--timestamp=none"] if args.sign_identity else []
        if args.sign_identity:
            service_name = "local.glance.ir-lab.camera-helper"
            def requirement(identifier):
                return (f'anchor apple generic and identifier "{identifier}" '
                        f'and certificate leaf[subject.OU] = "{args.team_id}"')
            config = Path(temporary) / "ServiceBuildConfiguration.swift"
            # Values are fixed identifiers and a validated team ID.
            config.write_text("enum ServiceBuildConfiguration {\n"
                + "static let serviceName = " + json.dumps(service_name) + "\n"
                + "static let clientRequirement = " + json.dumps(requirement(info["CFBundleIdentifier"])) + "\n}\n")
            daemon = executable.parent / "GlanceIRService"
            engine = args.helper.resolve().parent / "libbrio-ir.a"
            run("xcrun", "swiftc", "-target", target, "-parse-as-library", "-swift-version", "5", "-O",
                "-import-objc-header", HERE / "brio_ir_engine.h",
                ROOT / "glance/Infrared/InfraredServiceProtocol.swift",
                HERE / "service/InfraredDaemon.swift", config, engine,
                "-framework", "IOKit", "-framework", "CoreFoundation", "-framework", "Security",
                "-framework", "SystemConfiguration", "-o", daemon)
            launch = app / "Contents/Library/LaunchDaemons"
            launch.mkdir(parents=True)
            (launch / (service_name + ".plist")).write_bytes(plistlib.dumps({
                "Label": service_name,
                "BundleProgram": "Contents/MacOS/GlanceIRService",
                "MachServices": {service_name: True},
                "ProcessType": "Interactive",
            }))
            info["GlanceIRServiceName"] = service_name
            info["GlanceIRServiceRequirement"] = requirement(service_name)
            run("codesign", "--force", "--sign", identity, "--identifier", service_name, *signing, daemon)
            signed = subprocess.run(["codesign", "-d", "--verbose=4", str(daemon)], capture_output=True, text=True, check=True)
            if f"TeamIdentifier={args.team_id}" not in signed.stderr.splitlines():
                raise RuntimeError("Signing identity does not belong to the requested team")
            run("codesign", "--verify", "-R", "=" + requirement(service_name), daemon)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        shutil.copyfile(HERE / "README.md", resources / "README.md")
        shutil.copytree(args.helper.resolve().parent / "Licenses", resources / "Licenses")
        run("codesign", "--force", "--sign", identity, *signing, resources / "brio-ir-probe")
        run("codesign", "--force", "--sign", identity, *signing,
            "--entitlements", HERE / "IRLab.entitlements", app)
        run("codesign", "--verify", "--deep", "--strict", app)
        if args.sign_identity:
            run("codesign", "--verify", "-R", "=" + requirement(info["CFBundleIdentifier"]), app)
        # A valid signature alone is insufficient: hardened runtime otherwise
        # denies camera consent before macOS can show its permission prompt.
        entitlements = subprocess.check_output(
            ["codesign", "-d", "--entitlements", "-", "--xml", str(app)], stderr=subprocess.DEVNULL)
        if plistlib.loads(entitlements).get("com.apple.security.device.camera") is not True:
            raise RuntimeError("Signed lab is missing its camera entitlement")
        # ZIP excludes extended attributes and preserves executable mode bits.
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as zipped:
            for path in app.rglob("*"):
                if path.is_file():
                    zipped.write(path, path.relative_to(app.parent))
    print(f"Built and verified {archive}")


if __name__ == "__main__":
    main()
