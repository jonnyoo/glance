#!/usr/bin/env python3
"""Check a signed integrated app without launching it or registering its helper."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
parser.add_argument("--allow-debug", action="store_true")
args = parser.parse_args()
app = args.app.resolve()
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
entitlements = plistlib.loads(subprocess.check_output(
    ["codesign", "-d", "--entitlements", ":-", str(app)], stderr=subprocess.DEVNULL))
assert entitlements.get("com.apple.security.device.camera"), "Missing camera entitlement"
assert args.allow_debug or not entitlements.get("com.apple.security.get-task-allow"), "Debug attachment enabled in release"
signature = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)], capture_output=True, text=True, check=True).stderr
team = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", signature, re.M).group(1)
assert "(runtime)" in signature, "Hardened runtime is required"
name = info["CFBundleIdentifier"] + ".camera-helper"
requirement = f'anchor apple generic and identifier "{name}" and certificate leaf[subject.OU] = "{team}"'
assert info["GlanceIRServiceName"] == name
assert info["GlanceIRServiceRequirement"] == requirement, "XPC requirement was not expanded correctly"
daemon = plistlib.loads((app / "Contents/Library/LaunchDaemons" / (name + ".plist")).read_bytes())
assert daemon["Label"] == name and daemon["MachServices"] == {name: True}
assert daemon["BundleProgram"] == "Contents/MacOS/GlanceIRService"
helper = app / daemon["BundleProgram"]
subprocess.run(["codesign", "--verify", "--strict", "-R", "=" + requirement, str(helper)], check=True)
expected_arches = set(subprocess.check_output(["lipo", "-archs", str(app / "Contents/MacOS" / info["CFBundleExecutable"])], text=True).split())
for binary in (helper, app / "Contents/Resources/brio-ir-probe"):
    assert set(subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()) == expected_arches
with zipfile.ZipFile(app / "Contents/Resources/InfraredSources.zip") as sources:
    assert sources.testzip() is None
    assert "tools/infrared/build_xcode.py" in sources.namelist()
    assert any(name.endswith(".tar.bz2") for name in sources.namelist())
assert (app / "Contents/Resources/InfraredLicenses/libusb-LGPL.txt").is_file()
assert (app / "Contents/Resources/InfraredLicenses/libuvc-BSD.txt").is_file()
print("Signed app passed: camera entitlement, release/debug policy, hardened runtime, mutual-identity configuration, helper signature, architectures and source/license packaging.")
