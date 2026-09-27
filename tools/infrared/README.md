# Experimental BRIO infrared unlock

This implements an **optional additional IR identity check** for issue #46, alongside the standalone Glance IR Lab diagnostic. The switch is off by default. With it enabled, Glance requires colour-camera recognition, Heavy liveness and a fresh IR match against the same identity's separate encrypted IR enrollment before typing the Mac password. Unavailable IR never falls back to colour-only unlock.

**Integrated face unlock has been confirmed on the test Mac; production biometric validation is not complete.** The existing ArcFace model has not been calibrated for BRIO infrared, and the current liveness checks are not validated presentation-attack detection. This does not establish Windows Hello-equivalent security. Keep #46 open until hardware lifecycle, genuine/impostor and spoof tests pass.

## Integrated app build and setup

Use the existing Glance Xcode scheme with Xcode 26+, Python 3 and your normal Apple-issued signing identity/team. The new build phase packages and signs the camera helper automatically for every requested architecture (`arm64` and/or `x86_64`). It derives the XPC identities from `PRODUCT_BUNDLE_IDENTIFIER` and `DEVELOPMENT_TEAM`; no contributor signing identity is embedded in source. The first signed build downloads pinned libusb/libuvc sources into DerivedData. No Homebrew installation or administrator build step is required. Unsigned builds omit the helper; `GLANCE_ENABLE_INFRARED=NO` explicitly excludes it from a signed build.

Install the signed app in `/Applications`, complete normal Glance setup, then:

1. In **Your Face**, choose **Enroll infrared** for an existing identity.
2. Enable the camera helper, approve it in System Settings → General → Login Items & Extensions, and grant camera access if requested.
3. Capture three separate infrared scans of that same person, then save. Features join the existing encrypted enrollment; preview images are never written to disk.
4. In **Recognition**, enable **Require a BRIO infrared match**. Both centroid and minimum reference similarity must meet the configured threshold. The initial `0.70` is an engineering default, **not a measured security threshold or confidence percentage**.
5. Select the BRIO explicitly in Camera settings; turn off **Allow iPhone cameras** if Continuity Camera should not be discovered. A selected camera that disappears is unavailable, not permission to switch cameras. On a scan, Glance allows up to five seconds for the selected camera to reappear after USB handoff, then waits up to five seconds for the first fresh colour frame before starting the recognition timer. IR-required scans allow at least ten seconds for positive liveness. Glance then stops its colour camera before the root helper takes the BRIO. It requires Heavy liveness even if the ordinary liveness setting is disabled or Light. Missing enrollment/helper/camera, failed capture/alignment, low scores or expired evidence deny face unlock; manual Mac-password entry remains available.

RGB recapture invalidates that identity's IR enrollment. Removing or disabling an identity, changing its enrollment, cancelling/superseding a scan, locking the credential session or exceeding the 15-second monotonic evidence window prevents password entry. Authorization is checked again after credential decryption and before each character and Return. Evidence and liveness cannot be carried over from a different recognized identity.

For an isolated development variant, override `PRODUCT_BUNDLE_IDENTIFIER` and `PRODUCT_NAME`, and retain **`glance/glance.entitlements`**. Its keychain group expands to the actual bundle identifier. Do not substitute `IRLab.entitlements`: those camera-only entitlements are sufficient for diagnostics but cause “A required entitlement is not present” when Glance accesses its protected session key. Xcode must have a signed-in developer account and a matching macOS provisioning profile (automatic signing can create one). A valid app signature alone does not prove protected keychain access works. Alternate bundle identifiers have separate keychain services and encrypted enrollment directories and do not start the production updater. Do not run two copies with face unlock enabled during a lock-screen test.

Distribution still uses the maintainer's existing signing/notarization process. The app includes native licenses and `InfraredSources.zip` with corresponding source, build scripts and native relinkable objects. Disable the helper before removing the app. The helper starts only for requests and never receives credentials.

## Hardware verified

Logitech BRIO USB `046d:085e`, firmware `0317`, USB 3 connection, macOS 27.0 (`26A428`). Its second video-streaming interface advertises KSMedia L8_IR (`00000032-0002-0010-8000-00aa00389b71`), 340 × 340, 8 bits per pixel. AVFoundation/CoreMediaIO do not publish that interface on this machine.

Direct USB capture using libusb and a narrowly patched libuvc received 128–129 complete frames over five seconds. The BRIO alternates dark and illuminated frames. The diagnostic selects the brightest complete frame for its preview; this is **not** a liveness algorithm. No vendor extension controls or firmware changes are used.

macOS owns this camera through its USB video driver. The test uses administrator authorization (either per test or through the optional approved helper), temporarily takes the entire BRIO (including normal video/audio) away from that driver, captures a bounded burst (up to five seconds), then releases it and reattaches the drivers. The BRIO was visible again through the macOS camera API after testing. Full recording/audio functionality after recovery still needs a manual check.

## Build and run

Requirements: macOS 15+, Xcode 26+, Python 3 and git. The scripts build pinned libusb locally and do not install global dependencies or change system configuration.

From the repository root:

```sh
python3 tools/infrared/build_probe.py /absolute/path/to/ir-build
/absolute/path/to/ir-build/brio-ir-probe --selftest
/absolute/path/to/ir-build/brio-ir-probe --check
python3 tools/infrared/build_lab.py /absolute/path/to/ir-build/brio-ir-probe '/absolute/path/to/Glance IR Lab.zip'
ditto -xk '/absolute/path/to/Glance IR Lab.zip' /absolute/path/to/test-folder
open '/absolute/path/to/test-folder/Glance IR Lab.app'
```

Builds target the current macOS version by default. For an earlier system, pass `--deployment-target 15.0` (or newer); dependencies are built for that target. Use `--arch arm64` or `--arch x86_64` to select an architecture. The lab inherits the probe's minimum OS version. An existing static libusb can optionally be supplied with `--libusb-prefix /absolute/prefix`; its deployment target must not exceed the requested one.

Click **Check camera**, then **Test infrared**. Approve the macOS administrator prompt and look at the BRIO with the privacy cover open. The preview stays in memory. Closing the panel clears it. No photographs, enrollment templates or passwords are written or read. The optional `--snapshot` CLI mode returns pixel data over stdout; do not redirect that mode to a log if you want images to remain transient. `--capture` returns statistics only.

In the integrated app, open Settings → About and click the app icon five times to reveal Face Lab. Signed builds now include the probe and service automatically. Stop other camera uses before running diagnostics.

The standalone app is built for the current Mac architecture and ad-hoc signed by default for local development. The ZIP avoids iCloud/Finder metadata that can invalidate strict signing checks on a newly created app bundle in Documents.

## Experimental IR face comparison

The lab also measures how similar a fresh IR face scan is to three session-only IR reference scans. It uses the repository's existing `ArcFace.mlpackage`, compiled into the lab at build time. This is a diagnostic experiment: it does not load or modify Glance's enrolled identities, store templates, set a match threshold, check liveness, or authorize an unlock.

1. Click **Check camera** with the helper enabled.
2. Keep the same person in front of the BRIO and click **Add reference scan** three times. Each button press takes a separate capture, lasting up to five seconds. The preview remains visible if a scan is unsuitable for comparison.
3. Click **Compare new scan** for an independent capture. The panel shows cosine similarity to the normalized reference centroid and the minimum/maximum similarity to its individual scans. Scores range from −1 to 1 and are **not confidence percentages**. The latest five measurements remain visible for the session.
4. **Clear reference** or close the panel to discard the reference and measurements. **Cancel** discards the current capture while keeping completed reference scans. Comparisons never train or modify the reference.

Only a single detected face with five-point alignment is accepted. The model must return a finite, nonzero, 512-dimensional vector. Missing models, unaligned faces, multiple faces and malformed vectors produce an error; there is no fallback to a generic feature-print model. Samples have separate capture IDs and an IR-specific model identifier; the reference rejects reuse of a reference capture or comparison across models. A failed or cancelled scan cannot display an old score as the latest result.

The existing model's performance on BRIO IR images is uncalibrated. Same-person scores alone do not measure false acceptance or presentation-attack resistance. Measurements with different people, photos/screens, pose changes and lighting changes are needed before choosing any authentication policy. The source model also has its own usage terms: [InsightFace model zoo](https://github.com/deepinsight/insightface/tree/master/model_zoo) describes the published weights as intended for non-commercial research. This local experiment does not establish production suitability.

## Optional signed camera service

The lab can now package a root helper managed by `SMAppService`. This is still an experimental diagnostic, not a login service. Build with an Apple-issued signing identity and its matching team ID:

```sh
python3 tools/infrared/build_lab.py /absolute/path/to/ir-build/brio-ir-probe \
  '/absolute/path/to/Glance IR Lab.zip' \
  --sign-identity 'Developer ID Application: Your Name (YOURTEAMID)' \
  --team-id YOURTEAMID
```

Extract the app into `/Applications` before enabling it. Click **Enable camera helper**, approve it in System Settings → General → Login Items & Extensions if macOS requests it, then return to the app. Camera privacy consent is also required. The signed app carries `com.apple.security.device.camera`; without this entitlement, hardened runtime rejects the request before macOS can show its consent prompt. Packaging verifies the entitlement in the finished signature. **Check camera** followed by **Test infrared** uses the approved helper without a new administrator prompt per capture. **Cancel** or closing the panel cancels the request. **Disable camera helper** unregisters it; disable it before removing or replacing the app. The default build without signing arguments retains the bounded, per-test authorization path and installs no service.

The signed build does not fall back to per-test administrator execution when its service is unavailable. The daemon starts on demand and opens the camera only for explicit requests; it does not scan continuously or handle credentials. It links the USB engine directly instead of launching another executable as root. Each capture has separate memory, a frame collection window of up to five seconds, cancellation, and a 20-second cancellation watchdog (the client times out at 25 seconds). USB driver cleanup still depends on libusb/macOS completing their operations; this is not a hard real-time termination guarantee.

The listener authenticates the client's bundle identifier and signing team using macOS XPC code requirements. The client separately authenticates the helper. The daemon accepts only the current console user, checks that user during capture and before returning image data, permits one camera job at a time, and cancels a job if its connection closes. SIGTERM requests cancellation and lets USB cleanup finish. No file paths, shell commands, enrollment data, or passwords are accepted over XPC. The signing identity and team are build parameters, never personal values committed to the project. Hardware access at the lock screen, fast user switching, sleep/wake and abrupt daemon termination still require end-to-end validation before production release.

The integrated app uses the same service code with its own bundle/team requirements, generated by `build_xcode.py`. The standalone lab remains isolated and never authorizes unlocks.

## Validation

Run all camera-free Swift regression suites with:

```sh
python3 tools/infrared/run_tests.py
```

They cover response/vector validation, encrypted-record payload migration, failed-save rollback, RGB recapture invalidation, stale identity rejection, session clearing, authorization expiry/revocation and cancellation during simulated password entry. The event tests use an in-memory sink: they never type into the running desktop or read the keychain. The existing liveness regression suite is included. Synthetic tests do not establish biometric accuracy. The glare-crop regression uses synthetic highlights to verify that a bright patch outside the detected face is excluded while an identical patch inside it still triggers the existing glare threshold. Device/bezel detection continues to examine the full camera image.

Local integrated builds passed unsigned for Apple Silicon and signed Release for both Apple Silicon and Intel. Execution on Intel hardware remains untested. The development app's nested signatures, camera entitlement, expanded XPC requirements and launch-daemon bundle path were checked. Release builds explicitly disable injected debug entitlements. Validate a finished signed bundle without launching it with:

```sh
python3 tools/infrared/verify_app.py /absolute/path/to/glance.app
```

For a Debug development build only, add `--allow-debug`. This also checks the provisioned keychain group and app identity, matching app/helper/probe architectures and bundled source/licenses. The camera-only development package from the initial integration was rejected by the added keychain check after the tester found the setup error; the corrected, automatically provisioned universal build passed package verification and a macOS protected-keychain lookup for a random nonexistent test item (no credential reads or writes). The tester subsequently completed setup and approved the helper. The enrollment sheet retained stale approval state until closed/reopened; explicit app-activation refresh and a Check approval button address this. The tester then confirmed the integrated IR preview appears. Earlier live lab tests below exercise the shared capture service, not the complete new lock-screen flow.


```sh
xcrun swiftc -parse-as-library glance/Infrared/InfraredProbeResult.swift tools/infrared/result_selftest.swift -o /absolute/path/to/ir-build/result-selftest
/absolute/path/to/ir-build/result-selftest
```

```sh
xcrun swiftc -parse-as-library glance/Infrared/InfraredReference.swift \
  tools/infrared/reference_selftest.swift -o /absolute/path/to/ir-build/reference-selftest
/absolute/path/to/ir-build/reference-selftest
```

`model_selftest.swift`, run from a test bundle containing the compiled model, checks that model loading and inference produce a finite normalized 512-dimensional vector and that a blank image is rejected as a face. It does not open the camera.

The reference tests cover incomplete enrollment, reused reference captures, different model identifiers, invalid vectors (including NaN and infinity), known cosine values, immutable comparison and clearing. `service/recognition_selftest.swift` runs an explicit four-capture BRIO experiment from a signed test bundle containing the compiled model. It reports numeric measurements without logging images or face vectors; a no-face or alignment failure is an unsuccessful measurement, not a match.

`engine_selftest.c` checks independent capture state and cancellation before USB access. It can be compiled with AddressSanitizer and UndefinedBehaviorSanitizer against the generated `libbrio-ir.a`:

```sh
xcrun clang -O1 -g -fsanitize=address,undefined \
  -I /absolute/path/to/ir-build/libuvc/include -I /absolute/path/to/ir-build/libusb/installed/include/libusb-1.0 \
  tools/infrared/engine_selftest.c /absolute/path/to/ir-build/libbrio-ir.a \
  -framework IOKit -framework CoreFoundation -framework Security -lobjc \
  -o /absolute/path/to/ir-build/engine-selftest
/absolute/path/to/ir-build/engine-selftest
```

`service/connection_selftest.swift` checks a registered lab helper without opening the camera. Compile it with `InfraredServiceProtocol.swift`. First sign a copy using the lab's identity and bundle ID (`local.glance.ir-lab`) and run `allow TEAM_ID`; only then run an ad-hoc copy with `deny TEAM_ID`, a copy signed with a different bundle ID with `deny TEAM_ID`, and the trusted copy with `deny AAAAAAAAAA`. These exercise accepted clients, unsigned clients, incorrect client identity, and incorrect server requirements. A timeout is inconclusive. Local testing passed all four cases. `service/capture_selftest.swift`, signed with the same identity and bundle ID, explicitly opens the camera to test cancellation and two consecutive captures. On the BRIO, both service captures returned 129 valid frames with zero rejected frames and decoded in memory; cancellation completed without an image.

The native probe verifies USB VID/PID, a single connected matching camera, IR format GUID, interface/format/frame indices and the negotiated frame interval. It rejects malformed/incomplete frames and never falls back to RGB or generic grayscale. The BRIO advertises a maximum buffer of 231200 bytes (twice the actual 115600-byte image); negotiation permits that bounded allocation, but accepted frames must be exactly 115600 bytes.

The Swift parser rejects failed, oversized, incorrectly sized, missing and malformed pixel data. Merely detecting the IR descriptor cannot produce a preview. Apple Vision runs face detection on the decoded image; a detected face is not an identity match or proof of liveness.

The helper is statically linked to libusb and libuvc and loads only system libraries. `build_probe.py` fetches libuvc commit `4e9fc773914377ec0bcf2f31621f56da5a0fa09f` and adds an explicit KSMedia L8_IR format identifier plus a 1.5-second timeout for stream negotiation requests. It does not reinterpret ordinary grayscale as IR.

## Manual release acceptance

Do these with a disposable development enrollment, only one running unlock app and a known-working manual password fallback. Never put passwords, pictures or face vectors in logs/issues.

| Test | Required result | Current evidence |
| --- | --- | --- |
| Protected-keychain setup | Session key can be stored/read with local user authentication | Provisioned rebuild/check passed; tester completed setup and reached IR enrollment |
| Three IR scans and encrypted save/reload | Same identity retains usable IR enrollment after relaunch | Automated serialization/store tests pass; tester confirmed three scans saved and IR requirement enabled across app updates |
| Genuine lock-screen unlock | Fresh RGB + Heavy liveness + IR pass, exactly one password submission | Tester confirmed successful unlock after regranting Accessibility for the development signing identity |
| Missing/disconnected BRIO or disabled helper | No password submission, clear error, manual login works | Policy tests pass; hardware test pending |
| Cancel, disable identity/IR enrollment or change session during capture | No submission; helper cleans up | Policy/injection tests and lab cancellation pass; integrated test pending |
| Wrong person, printed photo, phone display/video, varied light/pose | No false acceptance; record numerical genuine/impostor separation | Pending; no security threshold established |
| Sleep/wake, fast user switching, lock during enrollment | Discard old evidence; correct console user only | Code gates implemented; system tests pending |
| Repeated captures then normal camera and microphone use | Drivers return; ordinary recording/audio work | Three BRIO-only IR→colour handoffs passed, including immediate/2s/8s restarts and cancelled-start recovery; full recording/audio test pending |
| Signed installation, approval, update, helper removal | Correct team restrictions; no orphaned running capture | Lab enable/signature/XPC rejection tests pass; release lifecycle pending |

No claim of secure production readiness should be based solely on an IR preview, one successful face match or passing synthetic tests. Model usage terms also require the maintainer's review.

## Third-party licenses and references

libuvc is BSD-licensed (Ken Tossell and contributors). Its complete license is in the downloaded checkout's `LICENSE.txt`. libusb is LGPL-2.1-or-later. When distributing a statically linked binary, include the corresponding source/build materials and licenses required for relinking; the local build script and pinned libuvc source are retained for that purpose. Review the relinking materials and distribution requirements before a production release.

- [Issue #46](https://github.com/jonnyoo/glance/issues/46)
- [KSMedia L8_IR identification](https://lkml.org/lkml/2018/3/21/202)
- [Apple device capture requirements](https://developer.apple.com/documentation/iousbhost/iousbhostobjectinitoptions/devicecapture)
- [libusb macOS access limitations](https://github.com/libusb/libusb/wiki/FAQ)

### Lock-screen glare regression

The first integrated lock test correctly matched the colour face but was rejected by the existing glare cue before IR capture. A controlled BRIO lock-screen comparison measured 37 face frames: the old 15%-padded crop crossed the glare gate in 26 frames, whereas a face-only crop crossed it in none. At the strongest old-crop reading, its glare score was 0.168 versus 0.0026 for the face-only crop from that same frame. The crop now excludes surrounding background; the glare formula/threshold, full-frame device detector, Heavy liveness and IR match requirement are unchanged. A later corrected build completed a real lock-screen unlock as recorded below. This regression fix does not establish presentation-attack resistance.

The tester confirmed the crop fix removed the glare rejection (score 0.000) while retaining a colour identity match. The next attempt timed out awaiting positive liveness. Camera warmup is now separately bounded, the IR-required live-face stage gets at least ten seconds, and in-memory diagnostics include the continuous matched-frame count and live-face cue readings. Evidence expiry remains 15 monotonic seconds after the relevant RGB/liveness evidence, and no match or liveness threshold was reduced. Subsequent camera and permission fixes enabled the confirmed IR-assisted unlock described below.

### Camera handoff regression

A live lock attempt reached the IR helper; its next scan reused an invalid CoreMediaIO connection and produced no fresh colour frames. `CameraManager` now rebuilds the session, input, output and delegate for each start. Configuration/start/stop/teardown share one serial queue; generation checks discard callbacks from retired sessions, and the preview binds to the replacement session. Startup allows five seconds for the selected USB camera to reappear before reporting it unavailable.

Camera selection no longer falls back silently when an explicit device disappears. **Allow iPhone cameras** controls Continuity discovery (enabled by default for existing users). The Info.plist declares the distinct Continuity device type so macOS does not classify an iPhone as a built-in camera. Onboarding and preview use the same resolver.

`service/camera_handoff_selftest.swift` is an explicit, signed hardware test outside the offline suite. Compile it with `CameraManager.swift`, `CameraDeviceCatalog.swift`, `InfraredServiceClient.swift`, `InfraredServiceProtocol.swift` and `InfraredProbeResult.swift`. Package it with a development app's bundle ID, matching signing identity/profile, camera entitlement and service configuration; the corresponding helper must already be approved. Include `NSCameraUseContinuityCameraDeviceType = true`. Quit other camera consumers and launch through Launch Services. It selects only Logitech BRIO, checks the actual input ID and rejects Continuity inputs; it never reads credentials/enrollment, saves pictures or submits keystrokes. It checks ordinary restart, three IR handoffs with immediate/2-second/8-second colour restarts, and interrupted-start recovery. Its settings stub does not modify the installed app's preferences. `--select-only` reports the BRIO ID without opening it.

An earlier desktop handoff test allowed system-default fallback and cannot establish BRIO recovery; only a test checking the actual selected input is valid. This also explains why camera re-enumeration alone is insufficient acceptance evidence.

The BRIO-pinned signed test passed all three handoffs on the test Mac (130/129/129 complete IR frames; 15 verified BRIO colour frames after each handoff), plus normal restart and cancelled-start recovery. Seven offline suites and the signed universal Release build/package checks passed. The next lock attempt passed colour identity, Heavy liveness and IR (centroid 0.924, lowest reference 0.850, threshold 0.700), but macOS denied Accessibility because its stored grant matched an earlier signing identity. The app now checks that permission before scanning and preserves the actual final-unlock error. Re-add the development app in Accessibility after changing signing identities. The tester regranted Accessibility and confirmed an actual lock-screen unlock; the complete RGB + liveness + IR path works on this Mac.

### Capture latency

The initial prototype always captured for five seconds. The engine now finishes after at least 12 complete frames including three illuminated frames (mean brightness at least 5/255), retaining the brightest complete image from that burst. This is exposure/readiness selection, not an anti-spoof decision; RGB Heavy liveness, IR identity thresholds and the 15-second evidence limit are unchanged. Dark/malformed/incomplete streams cannot satisfy the early-finish condition, and capture remains bounded to five seconds. A dark image returned at timeout must still pass the app's ordinary face/identity checks.

Native sanitizer tests cover insufficient bursts, dark frames, malformed bright frames, illuminated-frame selection, state isolation and cancellation. Recognition diagnostics now include the IR request duration and total face-check duration so latency can be measured instead of inferred from a successful match.

The faster signed helper measured 1.151s, 1.057s and 1.107s for three real BRIO captures (12 complete frames each), down from roughly 5.6s with the fixed five-second collection window. All three actual BRIO colour restarts and interrupted-start recovery passed. These numbers measure IR capture/USB handoff, not the entire liveness/unlock flow.

The tester also confirmed a faster successful lock-screen unlock using the existing RGB and IR enrollment. The in-app readout showed 1.1s IR capture and 2.9s total face checks. This excludes the old 550ms automatic-trigger delay and password submission; production biometric/PAD validation remains outstanding.


### Further latency work

The latest development build removes the fixed 250ms pre-arm wait and evaluates the authoritative lock state immediately. If the lock is still settling after wake, it permits one 300ms retry for the same unhandled event. It never delays a confirmed lock, rearms an already-handled event from a late retry, or acts on a superseding event. Unlock/sleep notifications cancel and reset the prior lock immediately, even while CGSession still reports the previous state; they only stop work and never authorize a scan. This prevents a rapid lock→unlock→lock from being mistaken for an already-handled lock. A camera-free regression exercises the production retry code, including that observed sequence, sleep and cancellation.

IR model loading runs concurrently with USB capture. Unlock detection omits Vision's capture-quality request, which no identity/liveness decision consumes; enrollment and diagnostic callers keep it by default. Geometry can skip homography diagnostics below the unchanged yaw gate, where the original algorithm necessarily abstains. Full diagnostic calculation remains the Face Lab default. Service configuration/handles are retained, but OS approval is queried afresh before each authorization check. No score threshold, liveness cue, evidence lifetime, per-character authorization gate or keyboard pacing changed.

Measurements on the test Mac:

| Measurement | Result and scope |
| --- | --- |
| Actual BRIO RGB startup | First frame 1.512/1.307/1.276s; native callback pixels 1920×1080 |
| Limit format selection to 1080p (test only) | 1.387/1.265/1.257s; same callback dimensions; not enough evidence to change production resolution |
| Detect with/without capture-quality request | 12 paired fresh-frame comparisons had identical boxes, pose, landmarks and aligned pixels; alternating order, warm means 5.6/5.3ms |
| Geometry diagnostics below yaw gate | Synthetic 20-frame window: 0.720ms full vs 0.003ms skipped; not a full-unlock speedup |
| IR model cold load | Separate process: 0.746s first load, ~0.015s repeats; actual in-app overlap saving is not yet established |

`service/face_detection_selftest.swift` reproduces the BRIO-only paired detection check without saving images or accessing enrollment. Build it using the signing/package setup of the handoff test. The expanded liveness tests verify identical cue readings and per-frame decisions for both geometry paths across yaw boundaries, missing yaw, noisy/planar/live/still landmarks, blink confirmation, denial overrides and rolling-window expiry. All eight offline suites and the signed universal Release package pass.

Recognition now reports camera startup, colour/liveness, camera handoff, IR capture/analysis, password submission and total scan-to-submission time. Submission completion is not an authoritative macOS unlock acknowledgment. The first timing retest uncovered an unlock-notification/CGSession lag: one lock ended during camera startup, and a rapid second lock was incorrectly suppressed as already handled. The corrected build subsequently completed a real lock-screen unlock. Its stage readout was 1.45s camera startup, 1.77s colour/liveness, 0.14s handoff, 1.1s IR capture, 0.01s IR analysis and 0.57s password submission, totalling 5.06s scan-to-submission. Startup and liveness dominate this run; a measured end-to-end speedup is not established.

A bounded, isolated native RGB+IR experiment was tested on the same BRIO. Simultaneous YUYV 1080p/30 or 720p/30 with 340×340 IR returned IR but zero RGB frames. A 1080p RGB-only control succeeded (first frame ~1.2s). Starting RGB first yielded 12–13 frames, then stopped delivering image data when IR started. The final instrumented run recorded 32,544 successful but empty RGB isochronous packets after IR startup, with no payload bytes, parser rejections or transport errors. Thus this particular capture configuration does not support the proposed overlap; it does not prove every BRIO mode or firmware is incapable of concurrency. These diagnostics remained outside the shipped code, and the original lab/helper were restored. Production RGB capture settings are unchanged.

AVFoundation preset/format-selection experiments continued to deliver 1920×1080 buffers at ~1.3s startup, including attempts to request 720p. Those results are not evidence about actual lower-resolution performance, and no resolution reduction was applied.


### Face-outline background regression

A later live test again stopped at the colour glare gate, before IR: 77 matched frames, glare score 0.051 against 0.040. Comparing old and optimized processing on 121 identical fresh BRIO frames produced zero liveness-snapshot differences, locating the problem in the existing appearance cue. A temporary in-memory diagnostic then showed its bright pixels on the wall beside the temple and below the jaw, still inside the detector's rectangular face bounds.

`GlareFaceRegion` now builds a hull from the detected facial contour and extends its temples to the top of the face rectangle to retain forehead coverage. A small exterior margin tolerates landmark jitter. Glare counts only pixels inside that outline and normalizes by the retained area, so a highlight actually on the face is not diluted. Missing, malformed or undersized outlines retain the full rectangular check. Face Lab and unlock share this extraction; full-frame bezel detection, identity, Heavy liveness, glare thresholds and IR matching remain unchanged.

On 69 paired fresh BRIO frames, the rectangular crop crossed the glare threshold in 50 frames (maximum 0.190); the outline crossed it in 0 (maximum 0.010). All other per-frame liveness cues were identical, including a detected blink. The temporary preview confirmed coverage of the forehead, cheeks and chin, with excluded background marked separately. No images were written to disk.

Synthetic tests cover background beside the temple/below the jaw, preserved forehead/cheek/chin highlight rejection, contour traversal order and invalid-outline fallback. `service/glare_outline_selftest.swift` reproduces the live numeric comparison without accessing enrollment or credentials. All eight offline suites and the signed universal Release/package verification pass. The corrected build completed a real lock-screen unlock; its timing is recorded above. These genuine-user false-rejection tests do not establish spoof resistance.
