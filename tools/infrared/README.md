# Experimental BRIO infrared capture

This is a working capture/diagnostic prototype for issue #46, **not IR authentication**. It adds an infrared panel to Face Lab and also runs as a separate **Glance IR Lab** app without configuring passwords or enrollment.

## Hardware verified

Logitech BRIO USB `046d:085e`, firmware `0317`, USB 3 connection, macOS 27.0 (`26A428`). Its second video-streaming interface advertises KSMedia L8_IR (`00000032-0002-0010-8000-00aa00389b71`), 340 × 340, 8 bits per pixel. AVFoundation/CoreMediaIO do not publish that interface on this machine.

Direct USB capture using libusb and a narrowly patched libuvc received 128–129 complete frames over five seconds. The BRIO alternates dark and illuminated frames. The diagnostic selects the brightest complete frame for its preview; this is **not** a liveness algorithm. No vendor extension controls or firmware changes are used.

macOS owns this camera through its USB video driver. The test uses administrator authorization (either per test or through the optional approved helper), temporarily takes the entire BRIO (including normal video/audio) away from that driver, captures for five seconds, then releases it and reattaches the drivers. The BRIO was visible again through the macOS camera API after testing. Full recording/audio functionality after recovery still needs a manual check.

## Build and run

Requirements: macOS 15+, Xcode 26+, Python 3, git and Homebrew libusb with its static library. The scripts do not install dependencies or change system configuration.

From the repository root:

```sh
python3 tools/infrared/build_probe.py /absolute/path/to/ir-build
/absolute/path/to/ir-build/brio-ir-probe --selftest
/absolute/path/to/ir-build/brio-ir-probe --check
python3 tools/infrared/build_lab.py /absolute/path/to/ir-build/brio-ir-probe '/absolute/path/to/Glance IR Lab.zip'
ditto -xk '/absolute/path/to/Glance IR Lab.zip' /absolute/path/to/test-folder
open '/absolute/path/to/test-folder/Glance IR Lab.app'
```

Builds target the current macOS version by default. To build for an earlier system, pass `--deployment-target 15.0` (or newer) to `build_probe.py` and use a libusb library built for that target or earlier. The lab inherits the probe's minimum OS version; the build rejects a newer libusb dependency.

For Intel Homebrew, pass `--libusb-prefix /usr/local` to `build_probe.py`.

Click **Check camera**, then **Test infrared for 5 seconds**. Approve the macOS administrator prompt and look at the BRIO with the privacy cover open. The preview stays in memory. Closing the panel clears it. No photographs, enrollment templates or passwords are written or read. The optional `--snapshot` CLI mode returns pixel data over stdout; do not redirect that mode to a log if you want images to remain transient. `--capture` returns statistics only.

To use the panel in Glance, build Glance normally, then copy `brio-ir-probe` into the built app's `Contents/Resources/` and sign the app for your development environment. The helper is optional and is not built/downloaded automatically by Xcode. Open Settings → About and click the app icon five times to reveal Face Lab. Stop other camera uses before testing. A production package would need a reviewed helper packaging/signing flow.

The standalone app is built for the current Mac architecture and ad-hoc signed by default for local development. The ZIP avoids iCloud/Finder metadata that can invalidate strict signing checks on a newly created app bundle in Documents.

## Optional signed camera service

The lab can now package a root helper managed by `SMAppService`. This is still an experimental diagnostic, not a login service. Build with an Apple-issued signing identity and its matching team ID:

```sh
python3 tools/infrared/build_lab.py /absolute/path/to/ir-build/brio-ir-probe \
  '/absolute/path/to/Glance IR Lab.zip' \
  --sign-identity 'Developer ID Application: Your Name (YOURTEAMID)' \
  --team-id YOURTEAMID
```

Extract the app into `/Applications` before enabling it. Click **Enable camera helper**, approve it in System Settings → General → Login Items & Extensions if macOS requests it, then return to the app. Camera privacy consent is also required. The signed app carries `com.apple.security.device.camera`; without this entitlement, hardened runtime rejects the request before macOS can show its consent prompt. Packaging verifies the entitlement in the finished signature. **Check camera** followed by **Test infrared for 5 seconds** uses the approved helper without a new administrator prompt per capture. **Cancel** or closing the panel cancels the request. **Disable camera helper** unregisters it; disable it before removing or replacing the app. The default build without signing arguments retains the bounded, per-test authorization path and installs no service.

The signed build does not fall back to per-test administrator execution when its service is unavailable. The daemon starts on demand and opens the camera only for explicit requests; it does not scan continuously or handle credentials. It links the USB engine directly instead of launching another executable as root. Each capture has separate memory, a five-second frame collection window, cancellation, and a 20-second cancellation watchdog (the client times out at 25 seconds). USB driver cleanup still depends on libusb/macOS completing their operations; this is not a hard real-time termination guarantee.

The listener authenticates the client's bundle identifier and signing team using macOS XPC code requirements. The client separately authenticates the helper. The daemon accepts only the current console user, checks that user during capture and before returning image data, permits one camera job at a time, and cancels a job if its connection closes. SIGTERM requests cancellation and lets USB cleanup finish. No file paths, shell commands, enrollment data, or passwords are accepted over XPC. The signing identity and team are build parameters, never personal values committed to the project. Hardware access at the login screen, fast user switching, sleep/wake and abrupt daemon termination still require validation before any unlock integration.

The service packaging currently targets the isolated lab. Shipping it inside Glance needs equivalent packaging with Glance's bundle identifier and the maintainer's signing identity, along with security review and distribution/notarization work.

## Validation

```sh
xcrun swiftc -parse-as-library glance/Infrared/InfraredProbeResult.swift tools/infrared/result_selftest.swift -o /absolute/path/to/ir-build/result-selftest
/absolute/path/to/ir-build/result-selftest
```

`engine_selftest.c` checks independent capture state and cancellation before USB access. It can be compiled with AddressSanitizer and UndefinedBehaviorSanitizer against the generated `libbrio-ir.a`:

```sh
xcrun clang -O1 -g -fsanitize=address,undefined \
  -I /absolute/path/to/ir-build/libuvc/include -I /opt/homebrew/include/libusb-1.0 \
  tools/infrared/engine_selftest.c /absolute/path/to/ir-build/libbrio-ir.a \
  -framework IOKit -framework CoreFoundation -framework Security -lobjc \
  -o /absolute/path/to/ir-build/engine-selftest
/absolute/path/to/ir-build/engine-selftest
```

`service/connection_selftest.swift` checks a registered lab helper without opening the camera. Compile it with `InfraredServiceProtocol.swift`. First sign a copy using the lab's identity and bundle ID (`local.glance.ir-lab`) and run `allow TEAM_ID`; only then run an ad-hoc copy with `deny TEAM_ID`, a copy signed with a different bundle ID with `deny TEAM_ID`, and the trusted copy with `deny AAAAAAAAAA`. These exercise accepted clients, unsigned clients, incorrect client identity, and incorrect server requirements. A timeout is inconclusive. Local testing passed all four cases. `service/capture_selftest.swift`, signed with the same identity and bundle ID, explicitly opens the camera to test cancellation and two consecutive captures. On the BRIO, both service captures returned 129 valid frames with zero rejected frames and decoded in memory; cancellation completed without an image.

The native probe verifies USB VID/PID, a single connected matching camera, IR format GUID, interface/format/frame indices and the negotiated frame interval. It rejects malformed/incomplete frames and never falls back to RGB or generic grayscale. The BRIO advertises a maximum buffer of 231200 bytes (twice the actual 115600-byte image); negotiation permits that bounded allocation, but accepted frames must be exactly 115600 bytes.

The Swift parser rejects failed, oversized, incorrectly sized, missing and malformed pixel data. Merely detecting the IR descriptor cannot produce a preview. Apple Vision runs face detection on the decoded image; a detected face is not an identity match or proof of liveness.

The helper is statically linked to libusb and libuvc and loads only system libraries. `build_probe.py` fetches libuvc commit `4e9fc773914377ec0bcf2f31621f56da5a0fa09f` and adds an explicit KSMedia L8_IR format identifier plus a 1.5-second timeout for stream negotiation requests. It does not reinterpret ordinary grayscale as IR.

## Remaining work for issue #46

- Validate the new opt-in signed service across locked sessions, sleep/wake, user switching, disconnection and installation/removal. The per-test build still installs no service; the signed lab registers one only after explicit enablement and macOS approval.
- Establish colour/IR coexistence, or a secure sequential acquisition design. The current direct USB path takes the whole camera.
- Validate an IR-compatible recognition and presentation-attack detection pipeline; choose enrollment storage, model provenance and thresholds based on measurements.
- Bind fresh IR evidence to the same identity and scan, reject stale/disconnected/substituted sources, and refuse face unlock if an explicitly required IR check cannot run.
- Test real users, printed photos, phone screens, video replays, masks, light/dark conditions, disconnection and sleep/wake.

The current unlock pipeline and liveness settings are unchanged. This diagnostic never grants an unlock.

## Third-party licenses and references

libuvc is BSD-licensed (Ken Tossell and contributors). Its complete license is in the downloaded checkout's `LICENSE.txt`. libusb is LGPL-2.1-or-later. When distributing a statically linked binary, include the corresponding source/build materials and licenses required for relinking; the local build script and pinned libuvc source are retained for that purpose. Do not ship this prototype as a signed production helper.

- [Issue #46](https://github.com/jonnyoo/glance/issues/46)
- [KSMedia L8_IR identification](https://lkml.org/lkml/2018/3/21/202)
- [Apple device capture requirements](https://developer.apple.com/documentation/iousbhost/iousbhostobjectinitoptions/devicecapture)
- [libusb macOS access limitations](https://github.com/libusb/libusb/wiki/FAQ)
