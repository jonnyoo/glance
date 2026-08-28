<h1 align="center">
  <br>
  <a href="https://tryglance.app"><img src="glance/Assets.xcassets/appicon.imageset/appicon.png" alt="Glance" width="150"></a>
  <br>
  Glance
  <br>
</h1>

<h3 align="center">FaceID for your Mac</h3>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-black.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-black.svg" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-black.svg" alt="Swift">
</p>

Glance brings the FaceID experience of your iPhone to a Mac near you. Unlock your Mac with a glance — no typing, no reaching for the Touch ID key. Everything runs on-device using Apple's Vision
and Core ML frameworks, so your face data and your Mac password never touch the internet. The UI is built into your Macbook's notch with fluid dynamic island like animations.


https://github.com/user-attachments/assets/453ce8c3-2f7a-4056-9fb3-3ec7f315895b


---

## Installation

**Requirements:**
- macOS 15 Sequoia or later
- Apple Silicon or Intel Mac

<a href="https://github.com/TheBoredTeam/boring.notch/releases/latest/download/boringNotch.dmg" target="_self"><img width="200" src="https://github.com/user-attachments/assets/e3179be1-8416-4b8a-b417-743e1ecc67d6" alt="Download for macOS" /></a>

Open the `.dmg` file and drag Glance to `/Applications`, then open it.


## Permissions

| Permission | Why |
|---|---|
| **Camera** | To see your face. Frames are processed in memory and never written to disk. |
| **Accessibility** | To type your password into the lock screen. |
| **Touch ID** | Gates the key that encrypts your face data and password. |

## How it works

1. Launch the app and follow the onboarding to enroll your face. Glance guides you through capturing your face, turning your head in nine
   directions. Each frame becomes a 512-number *embedding* — a mathematical fingerprint — and the
   image is thrown away.
2. Enter your Mac password once, encrypted behind Touch ID.
3. When your Mac locks or wakes from sleep, the animation appears in the notch and starts searching for a face.
4. If it's you — and the liveness checks agree you're a real person — Glance types the
   password and you're in.

## Features

| Feature | Description |
|---|---|
| **Face unlock** | Triggers on wake, on lock, or on pressing space at the lock screen. Pick any combination. |
| **Multiple identities** | Enroll several people, or several versions of yourself — with glasses, a beard, different lighting. Toggle any of them off without deleting. |
| **Liveness checks** | Watches for the motion and reflections that separate a real face from a photo. *Light* or *Heavy* strictness, or off. |
| **Notch UI** | A closed pill that expands into a scan animation with success and failure states. Hover to retry — or turn animations off entirely and Glance stays invisible. |
| **Camera & display** | Choose which camera to use, including different cameras for the built-in display vs. an external monitor. |
| **Auto-locking sessions** | The Touch ID session re-locks itself after an idle period you choose, so an unattended Mac doesn't stay authorized forever. |
| **Trackpad haptics** | Hovering over the notch will trigger haptics |
| **Notchless Mac support** | Macs without a notch will be replaced with a pill-shape, dynamic island style design. |
| **Your data, your call** | Edit or delete your enrolment or stored password at any time. The encrypted files are removed immediately. |


> [!WARNING]
> ## Glance is never as secure as Touch ID
> 
> MacBooks don't come equipped with the depth sensors that make iPhone Face ID trustworthy. An
> iPhone builds a 3D map of your face; a MacBook webcam sees a flat 2D image. That means:
> 
> - Glance defeats a **printed photo**, and with reasonable confidence a **photo on a phone screen**.
> - Glance does **not** reliably defeat a **video of you played on a phone**
> - macOS has no API that lets a third-party app authorize a login, so Glance unlocks by **typing
>   your stored password**.
> 
> Glance is a convenience feature, not a security upgrade. It's off by default, and you can leave
it that way.

## Privacy

- **Completely offline.** Face recognition runs entirely on-device. The only network request
  Glance ever makes is checking for app updates, which you can turn off.
- **Your face is never stored.** Only embeddings — a list of numbers nothing can turn back into a
  picture of you.
- **Encrypted with AES-GCM.** Your enrolled faces and stored password are ciphertext. The key
  that decrypts them lives in the macOS Keychain behind a Touch ID / device-password gate, and is
  only ever held in memory. There's no plaintext fallback anywhere.

---

# Deeper on security

A single macOS app target — SwiftUI + AppKit, ~15k lines, one dependency (Sparkle).

## Architecture

```
CameraManager ──▶ FaceRecognitionPipeline ──▶ FaceEnrollmentStore
                    detect → align → embed      (encrypted templates)
                    │
                    └──▶ LivenessAnalyzer
                    
FaceUnlockCoordinator ◀── LockMonitor / SpaceKeyMonitor
   │
   ├──▶ NotchOverlayController        (what you see)
   └──▶ SecureCredentialManager ──▶ KeystrokeInjector
```

**Recognition** is one pipeline — detect → align → embed — that everything else shares.
Vision finds the face and its landmarks; `FaceAligner` warps it onto ArcFace's canonical 112×112
template (skipping this costs a lot of accuracy); Core ML runs InsightFace's `w600k_mbf` model to
produce a 512-float embedding. Matching is cosine similarity against each enabled identity, and a
match has to clear the threshold against both the identity's averaged template *and* its closest
individual sample.

**Liveness** is five independent cues over a rolling ~2s window, split into two roles. *Deny* cues
(screen glare, a detected device rectangle around the face) fail the scan outright — a spoof tell
doesn't get outvoted. *Confirm* cues (flat-vs-3D landmark geometry, nose parallax across head
turns, blinks) prove a real face; any one is enough, and their absence is never a failure, since a
live person can sit still. There's deliberately no combined score: an earlier version averaged
~11 signals into a percentage, and that number wandered 30–80% on a live face while a phone photo
scored about the same.

**Unlocking** is handled by `FaceUnlockCoordinator`, which decides *whether* to unlock and
delegates the *how*. Recognition and liveness run concurrently and latch independently, so the
unlock fires the moment the second one lands. A latched match clears if a detected face stops
matching, so it can't be handed to someone who steps in front of the camera afterwards.

**Storage** is two-tier: an AES-256 session key in the Keychain behind a `.userPresence` gate,
and AES-GCM blobs (your identities on disk, your password in the Keychain) encrypted under it.
The blobs are meaningless without the key, which is what lets the password be read from the lock
screen where no Touch ID prompt could ever appear.

**Face Lab** is a built-in debug console — live preview, alignment visualization, per-identity
similarity scores, threshold calibration, per-cue liveness diagnostics. It never touches the
unlock path, and keeps its own threshold, so tuning it can't silently change the real gate.

## Project layout

```
glance/
├── glanceApp.swift              App entry, menu bar, window lifecycle
├── CameraManager.swift          AVCaptureSession → frames
├── FaceDetector / FaceAligner / ArcFaceEmbedder
├── FaceRecognitionPipeline.swift   detect → align → embed, and matching
├── FaceEnrollmentStore.swift    Identities, samples, templates
├── SecureCredentialManager / SecureFaceStore / KeychainManager
├── FaceUnlockCoordinator.swift  The unlock decision
├── KeystrokeInjector.swift      CGEvent keystrokes
├── LockMonitor / SpaceKeyMonitor / SessionAutoLocker
├── Liveness/                    Five-cue liveness model
├── NotchOverlay/                Lock-screen notch UI
├── Onboarding/                  Guided first-run flow
├── Settings/                    Settings window and pages
└── Models/ArcFace.mlpackage     Converted Core ML model
tools/                           Model conversion, liveness self-test
```

## Building from source

**Prerequisites:** macOS 15+ and Xcode 26+

```bash
git clone https://github.com/jonnyoo/glance.git
open glance/glance.xcodeproj
```

Build the `glance` scheme. Sparkle resolves automatically via SPM, and the Core ML model is
committed to the repo, so a fresh clone builds and runs as-is.

To regenerate the model (e.g. to swap in a different ArcFace variant), see
[`tools/README.md`](tools/README.md). If it's ever missing at runtime, the pipeline falls back to
Vision's generic feature-print embedder and says so in the UI — that's a diagnostic path, not a
supported mode.

The liveness model has no Vision or AppKit dependencies, so
[`tools/liveness_selftest.swift`](tools/liveness_selftest.swift) can run the real decision logic
against synthetic data with no camera.

Note that Glance runs unsandboxed and isn't Mac App Store distributable — keystroke injection and
lock-screen visibility both require it.

## Contributing

Not currently accepting PRs. Feel free to fork this project.

App feedback goes to [tryglance.app/feedback](https://tryglance.app/feedback).

## Acknowledgements

- **[The Boring Notch](https://github.com/TheBoredTeam/boring.notch)** — for the notch window
  physics.
- **[InsightFace](https://github.com/deepinsight/insightface)** — the ArcFace model doing the
 recognition.

## License

[MIT](LICENSE) © Jonathan Zhou
