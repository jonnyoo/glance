<h1 align="center">
  <br>
  <a href="https://tryglance.app"><img src="glance/Assets.xcassets/appicon.imageset/appicon.png" alt="Glance" width="150"></a>
  <br>
  Glance
  <br>
</h1>

<h3 align="center">Face unlock for your Mac</h3>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-black.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-black.svg" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-black.svg" alt="Swift">
</p>

Glance brings the FaceID-like experience of your iPhone to a Mac near you. Unlock your Mac with a glance — no typing, no reaching for the Touch ID key. Everything runs on-device using Apple's Vision
and Core ML frameworks, so your face data and your Mac password never touch the internet. The UI is built into your Macbook's notch with fluid dynamic island like animations.


https://github.com/user-attachments/assets/c417446c-f36d-480c-9f0b-1c78bbc54ecd


---

## Installation

**Requirements:**
- macOS 15 Sequoia or later
- Apple Silicon or Intel Mac

<a href="https://github.com/jonnyoo/glance/releases/latest/download/Glance.dmg" target="_self"><img width="200" src="https://github.com/user-attachments/assets/cdb8af97-1ee2-4669-b7cb-dcfb56c9dd61" alt="Download for Mac" /></a>

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
> MacBooks don't come equipped with the depth sensors that make iPhone FaceID trustworthy. An
> iPhone builds a 3D map of your face; a MacBook webcam sees a flat 2D image. That means:
> 
> - Glance defeats a **printed photo**, and with reasonable confidence a **photo on a phone screen**.
> - Glance does **not** reliably defeat a **video of you played on a phone**
> - macOS has no API that lets a third-party app authorize a login, so Glance unlocks by **typing
>   your stored password**.
> 
> Glance is a convenience feature, not a security upgrade. It's off by default, and you can leave
it that way.

---

# Privacy and Security

Glance is designed to keep biometric data and credentials on-device.

### Face data

Glance never stores camera images. During enrollment, each captured face is converted into a **512-dimensional embedding** using an ArcFace-based Core ML model. The original frame is then discarded.

Embeddings are stored locally and encrypted with **AES-GCM**.

### Credentials

Your Mac password is stored as encrypted data and is never written to disk in plaintext. The encryption key is a **256-bit AES key stored in the macOS Keychain**, protected by `userPresence` — requiring Touch ID or your device password.

The key is only held in memory while an authorized Glance session is active.

### Unlock pipeline

Glance won't type your password simply because a face matches. An unlock requires all of the following:

1. A valid Glance session is authorized.
2. The Mac is actually at the lock screen.
3. An enabled identity matches above the configured similarity threshold.
4. Liveness checks accept the detected face.
5. Accessibility permission is available to enter the password.

Face recognition and liveness detection run independently and must both succeed before the password is entered. 

### Local by design

Face recognition, face enrollment, and liveness detection run entirely on-device using Vision and Core ML. Glance does not send face data, camera frames, or credentials to a server.


### How it tells a face from a photo

Five independent cues over a rolling ~2s window, in two roles:

- **Deny cues** are evidence of a spoof — screen glare, or a device-shaped rectangle framing the
face. Either one fails the scan outright and overrides anything else.
- **Confirm cues** are evidence of a real face — flat-vs-3D landmark geometry, nose parallax
across head turns, blinks. Any one is enough, and their absence is never a failure, since a
live person can sit still and not blink.

Light detection only include deny cues. Heavy detection includes both deny and confirm cues.

### Face Lab

Face Lab is a hidden debug console to test face recognition and liveness detection with real values.

**To open it:** Settings → About, then click the app icon 5 times. A
debug section should appear in the sidebar.

---


## Building from source

### Prerequisites

- macOS 15+
- Xcode 26+



### Installation

1. Clone repository:
  ```bash
   git clone https://github.com/jonnyoo/glance.git
   cd glance
  ```
2. Open in Xcode:
  ```bash
   open glance/glance.xcodeproj
  ```
3. Run the project:
  - Click `run` or press `Cmd + R`.



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
