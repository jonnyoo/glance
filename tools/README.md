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

---

# Enrollment self-test

`enrollment_selftest.swift` drives the guided-enrollment pose maths with a
simulated head and reports how hard enrollment is to finish.

```bash
swiftc -O tools/enrollment_selftest.swift glance/Onboarding/EnrollmentPoseGeometry.swift \
    -o /tmp/enrollment_selftest
/tmp/enrollment_selftest
```

It compiles the shipping `EnrollmentPoseGeometry.swift` rather than a copy, so
it cannot stay green while the app's matching drifts.

It asserts the properties that matter and prints the numbers behind them:

1. **The ring and the gate agree** for a turn pointing at the requested pose:
   `headTurn`'s progress and `poseMatches` derive from the same normalized
   vector and honour the same outer cap, so the ring can never read full while
   the pose is refused. A turn pointing at a *different* sector is a separate
   matter — the ring only ever describes the pose being asked for.
2. **A diagonal costs no more head turn than a cardinal.**
3. **The eight sectors tile the circle exactly once**, boundaries included: no
   direction satisfies two poses, and none falls between them.

It then simulates enrollment at three levels of user effort with a noisy
yaw/pitch estimate, modelling the real capture loop — the 500 ms continuous
hold, the match streak, and two samples per pose, with any non-matching frame
restarting the hold. It prints time-to-enrol and give-up rate against the old
rectangular matcher, which is kept in the file purely so the regression stays
visible. The random source is seeded, so runs are reproducible.
