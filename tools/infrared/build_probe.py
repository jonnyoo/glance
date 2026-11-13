#!/usr/bin/env python3
"""Build the isolated IR probe; no installation or administrator access.

Requires Xcode command-line tools and git. Builds pinned libusb by default.
Build products and a pinned libuvc checkout stay in the specified directory.
"""
import argparse
import json
import platform
import re
from pathlib import Path
import subprocess
import shutil
from build_libusb import build_libusb

REVISION = "4e9fc773914377ec0bcf2f31621f56da5a0fa09f"
HERE = Path(__file__).resolve().parent


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError("Pinned libuvc source no longer matches the expected patch")
    return text.replace(old, new, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_directory", type=Path)
    parser.add_argument("--libusb-prefix", type=Path, help="Optional existing static libusb installation")
    parser.add_argument("--arch", choices=("arm64", "x86_64"), default=platform.machine())
    parser.add_argument("--deployment-target", default=platform.mac_ver()[0],
                        help="Minimum macOS version (defaults to this Mac)")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", args.deployment_target) or int(args.deployment_target.split(".")[0]) < 15:
        parser.error("The deployment target must be macOS 15 or newer")
    build = args.build_directory.resolve()
    build.mkdir(parents=True, exist_ok=True)
    source = build / "libuvc"
    if not source.exists():
        run("git", "init", source)
        run("git", "-C", source, "fetch", "--depth", "1",
            "https://github.com/libuvc/libuvc.git", REVISION)
        run("git", "-C", source, "checkout", "--detach", "FETCH_HEAD")
    actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if actual != REVISION:
        raise RuntimeError("Unexpected libuvc revision in build directory")
    # Always derive modified sources from the pinned commit, not previous edits.
    for name in ("include/libuvc/libuvc.h", "src/stream.c"):
        original = subprocess.check_output(
            ["git", "-C", str(source), "show", f"{REVISION}:{name}"], text=True)
        if name.endswith("libuvc.h"):
            patched = replace_once(original, "  /** Number of formats understood */",
                "  /** Microsoft KSMedia 8-bit infrared, distinct from ordinary grayscale. */\n"
                "  UVC_FRAME_FORMAT_KSMEDIA_L8_IR,\n  /** Number of formats understood */")
        else:
            patched = replace_once(original, "    FMT(UVC_FRAME_FORMAT_GRAY16,",
                "    FMT(UVC_FRAME_FORMAT_KSMEDIA_L8_IR,\n"
                "      {0x32,0,0,0,2,0,0x10,0,0x80,0,0,0xaa,0,0x38,0x9b,0x71})\n"
                "    FMT(UVC_FRAME_FORMAT_GRAY16,")
        if name == "src/stream.c":
            patched = replace_once(patched, "      ctrl->bInterfaceNumber,\n      buf, len, 0\n", "      ctrl->bInterfaceNumber,\n      buf, len, 1500\n")
        (source / name).write_text(patched)
    config = source / "include/libuvc/libuvc_config.h"
    template = config.with_suffix(".h.in").read_text()
    for key, value in {"MAJOR": "0", "MINOR": "0", "PATCH": "8"}.items():
        template = template.replace(f"@libuvc_VERSION_{key}@", value)
    config.write_text(template.replace("@libuvc_VERSION@", "0.0.8")
                     .replace("#cmakedefine LIBUVC_HAS_JPEG 1", "/* JPEG disabled */"))
    usb = args.libusb_prefix.resolve() if args.libusb_prefix else build_libusb(build / "libusb", args.arch, args.deployment_target)
    library = usb / "lib/libusb-1.0.a"
    if not library.is_file():
        raise RuntimeError(f"Static libusb library missing: {library}")
    version = lambda value: tuple((list(map(int, value.split("."))) + [0, 0])[:3])
    load_commands = subprocess.check_output(["xcrun", "otool", "-l", str(library)], text=True)
    dependencies = re.findall(r"\bminos\s+([0-9.]+)", load_commands)
    if any(version(item) > version(args.deployment_target) for item in dependencies):
        raise RuntimeError("libusb targets a newer macOS release; rebuild libusb or increase --deployment-target")
    sources = [source / "src" / (name + ".c") for name in
               ("ctrl", "ctrl-gen", "device", "diag", "frame", "init", "stream", "misc")]
    run("xcrun", "clang", "-arch", args.arch, "-mmacosx-version-min=" + args.deployment_target, "-O2", "-Wall", "-I" + str(source / "include"),
        "-I" + str(usb / "include/libusb-1.0"), HERE / "brio_ir_probe.c", *sources,
        library, "-framework", "IOKit", "-framework", "CoreFoundation",
        "-framework", "Security", "-lobjc", "-o", build / "brio-ir-probe")
    # Link the same engine into the signed service, with no child-process launch.
    objects = []
    for index, item in enumerate([HERE / "brio_ir_probe.c", *sources]):
        obj = build / f"ir-engine-{index}.o"
        run("xcrun", "clang", "-arch", args.arch, "-mmacosx-version-min=" + args.deployment_target, "-O2", "-Wall", "-DBRIO_IR_EMBEDDED",
            "-I" + str(source / "include"), "-I" + str(usb / "include/libusb-1.0"),
            "-c", item, "-o", obj)
        objects.append(obj)
    run("xcrun", "libtool", "-static", "-o", build / "libbrio-ir.a", *objects, library)
    licenses = build / "Licenses"
    licenses.mkdir(exist_ok=True)
    shutil.copyfile(source / "LICENSE.txt", licenses / "libuvc-BSD.txt")
    shutil.copyfile(library.resolve().parent.parent / "COPYING", licenses / "libusb-LGPL.txt")
    if args.arch == platform.machine():
        run(build / "brio-ir-probe", "--selftest")
    (build / "build-info.json").write_text(json.dumps({"minimum_macos": args.deployment_target, "arch": args.arch}))
    print(f"Built {build / 'brio-ir-probe'}")


if __name__ == "__main__":
    main()
