# Converting ArcFace to Core ML

`convert_arcface.py` turns InsightFace's official `w600k_mbf` ArcFace weights
(ONNX) into `glance/Models/ArcFace.mlpackage`, ready for `ArcFaceEmbedder.swift`
to load. Run this yourself — it downloads ~2GB of Python tooling (torch,
coremltools) and ~13MB of model weights from InsightFace's own hosting.

## Run it

```bash
cd /Users/jonathanzhou/Documents/glance
python3 -m venv .venv
source .venv/bin/activate
pip install -r tools/requirements.txt
python tools/convert_arcface.py
```

First run downloads the InsightFace `buffalo_s` model pack to
`~/.insightface/models/` (cached for next time). The script then:

1. Converts ONNX → torch → Core ML, baking preprocessing (RGB, `(px-127.5)/127.5`)
   into the model so Swift only ever hands over a raw 112×112 image.
2. **Verifies numerical parity**: runs the same random input through the
   original ONNX graph and the converted Core ML model and checks the
   outputs agree (cosine similarity > 0.999). This is the real check —
   a channel-order or scale mistake would silently produce a broken model
   that loads fine and returns plausible-looking garbage. If this check
   fails, the script exits with an error and **the model is not usable** —
   do not wire it in.
3. Saves `glance/Models/ArcFace.mlpackage`.

Expect it to take a few minutes, mostly the one-time package installs.

## After it succeeds

Add `glance/Models/ArcFace.mlpackage` to the Xcode project if it doesn't
show up automatically (the `glance/` folder is a file-system-synchronized
group, so it should auto-appear — if not, drag it into Xcode and make sure
"Copy items if needed" + the `glance` target are checked).

The model is committed to git (see the repo's `.gitignore` — only the
*compiled* `.mlmodelc` is excluded, since that's derived from the
`.mlpackage` at build time).

## If auto-download fails

InsightFace's model hosting occasionally moves. If `FaceAnalysis(...).prepare()`
fails, download `w600k_mbf.onnx` yourself from the InsightFace model zoo and
run:

```bash
python tools/convert_arcface.py --onnx-path /path/to/w600k_mbf.onnx
```

## Model contract (what Swift expects)

| | |
|---|---|
| Input | `input_image`, 112×112 RGB image (CVPixelBuffer/CGImage) |
| Output | `embedding`, 512 floats, **not** L2-normalized — Swift normalizes it |
| Preprocessing | Baked in: `(pixel - 127.5) / 127.5`, RGB channel order |

If you ever swap in a different ArcFace variant (e.g. `w600k_r50` via
`--variant w600k_r50`), this contract stays the same — only the file size
and latency change.

## Overlay input checks

`notch_input_selftest.swift` opens two temporary windows and checks which one macOS would target. It covers click-through hover states, setup controls, transparent margins and rounded corners, dragging outside the popup, keyboard eligibility, and intermediate resize/slide animation frames. It does not move the mouse or require Accessibility permission.

Run with Swift 6.2+ and the macOS SDK:

```bash
swiftc -swift-version 5 -default-isolation MainActor \
  glance/NotchOverlay/NotchWindow.swift \
  glance/NotchOverlay/NotchInteractionRegion.swift \
  glance/NotchOverlay/NotchShape.swift \
  glance/NotchOverlay/NotchPanelStyle.swift \
  tools/notch_input_selftest.swift -o /tmp/glance-input-check
/tmp/glance-input-check
```

For a manual check, move the pointer through the popup's edges and click a window behind it. During setup, also confirm that buttons and password entry work, including after moving the pointer outside the popup.
