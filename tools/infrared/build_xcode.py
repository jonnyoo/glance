#!/usr/bin/env python3
"""Xcode build phase: compile and sign the bundled camera service for each arch.

Dependencies are pinned and cached under DerivedData; no global installations.
Xcode signs the enclosing app after this phase. Unsigned builds omit the helper.
"""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    env = os.environ
    app = Path(env["TARGET_BUILD_DIR"]) / env["WRAPPER_NAME"]
    binary = app / "Contents/MacOS/GlanceIRService"
    resources = app / "Contents/Resources"
    client = env["PRODUCT_BUNDLE_IDENTIFIER"]
    if not re.fullmatch(r"[A-Za-z0-9.-]+", client):
        raise RuntimeError("Invalid application bundle identifier")
    name = client + ".camera-helper"
    plist = app / "Contents/Library/LaunchDaemons" / (name + ".plist")
    enabled = env.get("GLANCE_ENABLE_INFRARED", "YES") == "YES" and env.get("CODE_SIGNING_ALLOWED") != "NO"
    if not enabled:
        # Never leave a signed helper from an earlier build in an unsigned app.
        for item in (binary, plist, resources / "brio-ir-probe", resources / "InfraredSources.zip"):
            item.unlink(missing_ok=True)
        print("Infrared helper omitted from this unsigned/disabled build.")
        return
    team = env.get("DEVELOPMENT_TEAM", "")
    identity = env.get("EXPANDED_CODE_SIGN_IDENTITY", "")
    if not re.fullmatch(r"[A-Z0-9]{10}", team) or not identity or identity == "-":
        raise RuntimeError("IR service requires an Apple-issued signing identity and team. Use GLANCE_ENABLE_INFRARED=NO for an unsigned build.")
    architectures = env.get("ARCHS", "arm64").split()
    if not architectures or any(item not in ("arm64", "x86_64") for item in architectures):
        raise RuntimeError("Unsupported infrared helper architecture")
    minimum = env.get("MACOSX_DEPLOYMENT_TARGET", "15.0")
    work = Path(env["DERIVED_FILE_DIR"]) / "glance-infrared"
    work.mkdir(parents=True, exist_ok=True)
    requirement = lambda identifier: f'anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{team}"'
    configuration = work / "ServiceBuildConfiguration.swift"
    configuration.write_text("enum ServiceBuildConfiguration {\nstatic let serviceName = " + json.dumps(name)
        + "\nstatic let clientRequirement = " + json.dumps(requirement(client)) + "\n}\n")
    helpers, probes, builds = [], [], []
    for arch in architectures:
        build = work / arch
        run(sys.executable, HERE / "build_probe.py", build, "--arch", arch, "--deployment-target", minimum)
        daemon = build / "GlanceIRService"
        run("xcrun", "swiftc", "-target", f"{arch}-apple-macosx{minimum}", "-parse-as-library", "-swift-version", "5", "-O",
            "-import-objc-header", HERE / "brio_ir_engine.h", ROOT / "glance/Infrared/InfraredServiceProtocol.swift",
            HERE / "service/InfraredDaemon.swift", configuration, build / "libbrio-ir.a",
            "-framework", "IOKit", "-framework", "CoreFoundation", "-framework", "Security",
            "-framework", "SystemConfiguration", "-o", daemon)
        helpers.append(daemon); probes.append(build / "brio-ir-probe"); builds.append(build)
    binary.parent.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    for inputs, output in ((helpers, binary), (probes, resources / "brio-ir-probe")):
        if len(inputs) == 1: shutil.copy(inputs[0], output)
        else: run("xcrun", "lipo", "-create", *inputs, "-output", output)
    plist.parent.mkdir(parents=True, exist_ok=True)
    plist.write_bytes(plistlib.dumps({"Label": name, "BundleProgram": "Contents/MacOS/GlanceIRService",
                                     "MachServices": {name: True}, "ProcessType": "Interactive"}))
    shutil.copytree(builds[0] / "Licenses", resources / "InfraredLicenses", dirs_exist_ok=True)
    # Corresponding native source/build material accompanies the statically
    # linked LGPL dependency; preserve each architecture's relinkable objects.
    with zipfile.ZipFile(resources / "InfraredSources.zip", "w", zipfile.ZIP_DEFLATED) as archive:
        for item in HERE.rglob("*"):
            if item.is_file() and "__pycache__" not in item.parts:
                archive.write(item, Path("tools/infrared") / item.relative_to(HERE))
        shared = ROOT / "glance/Infrared/InfraredServiceProtocol.swift"
        archive.write(shared, "glance/Infrared/InfraredServiceProtocol.swift")
        archive.write(configuration, "ServiceBuildConfiguration.swift")
        for build in builds:
            for item in build.glob("*.o"): archive.write(item, Path(build.name) / item.name)
            for item in build.glob("*.a"): archive.write(item, Path(build.name) / item.name)
        source = builds[0] / "libuvc"
        for item in source.rglob("*"):
            if item.is_file() and ".git" not in item.relative_to(source).parts:
                archive.write(item, Path("libuvc") / item.relative_to(source))
        for item in (builds[0] / "libusb").glob("*.tar.bz2"):
            archive.write(item, item.name)
    timestamp = "--timestamp" if env.get("CONFIGURATION") == "Release" else "--timestamp=none"
    run("codesign", "--force", "--sign", identity, "--options", "runtime", timestamp, "--identifier", name, binary)
    run("codesign", "--force", "--sign", identity, "--options", "runtime", timestamp, resources / "brio-ir-probe")
    run("codesign", "--verify", "--strict", "-R", "=" + requirement(name), binary)
    print("Signed infrared helper packaged for " + ", ".join(architectures))


if __name__ == "__main__":
    main()
