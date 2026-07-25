#!/usr/bin/env python3
"""
Converts InsightFace's ArcFace recognition model (w600k_mbf, MobileFaceNet
backbone trained with ArcFace loss) into a Core ML .mlpackage that Glance's
Swift code can load directly.

Pipeline: ONNX (InsightFace's official weights) -> torch (via onnx2torch)
-> traced TorchScript -> Core ML, with preprocessing baked into the model so
Swift only ever hands over a raw RGB 112x112 image.

Usage:
    python3 -m venv .venv && source .venv/bin/activate
    pip install -r tools/requirements.txt
    python tools/convert_arcface.py --variant w600k_mbf

Output:
    glance/Models/ArcFace.mlpackage
        input:  "input_image", 112x112 RGB CVPixelBuffer/CGImage
        output: "embedding", 512 floats (NOT yet L2-normalized — Swift does that)

This script does not modify the Xcode project or any Swift source. It only
produces the model file; wiring it in is a separate, reviewable step.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "glance" / "Models" / "ArcFace.mlpackage"

VARIANT_ONNX_NAMES = {
    "w600k_mbf": "w600k_mbf.onnx",   # buffalo_s pack, ~13MB, MobileFaceNet backbone
    "w600k_r50": "w600k_r50.onnx",   # buffalo_l pack, ~166MB, ResNet50 backbone
}
VARIANT_PACK = {
    "w600k_mbf": "buffalo_s",
    "w600k_r50": "buffalo_l",
}


def fail(message: str) -> None:
    print(f"\nERROR: {message}\n", file=sys.stderr)
    sys.exit(1)


def locate_or_download_onnx(variant: str, explicit_path: str | None) -> Path:
    """Returns a local path to the recognition-model .onnx file.

    Prefers an explicit --onnx-path if given (for when auto-download fails
    or the user already has the weights). Otherwise downloads the official
    InsightFace model pack via the `insightface` package's own model zoo,
    which is the actively-maintained source for these weights — more
    resilient than us hardcoding a URL that could move.
    """
    if explicit_path:
        path = Path(explicit_path).expanduser().resolve()
        if not path.is_file():
            fail(f"--onnx-path does not exist: {path}")
        return path

    try:
        from insightface.app import FaceAnalysis
    except ImportError:
        fail(
            "The 'insightface' package is required to auto-download weights.\n"
            "Install it with: pip install insightface onnxruntime opencv-python\n"
            "Or download w600k_mbf.onnx yourself and pass --onnx-path."
        )

    pack_name = VARIANT_PACK[variant]
    print(f"Downloading InsightFace '{pack_name}' model pack (first run only)...")
    # .prepare() triggers the download+unzip into ~/.insightface/models/<pack>/
    # and validates every model in the pack loads correctly.
    app = FaceAnalysis(name=pack_name, providers=["CPUExecutionProvider"])
    app.prepare(ctx_id=-1)

    model_dir = Path.home() / ".insightface" / "models" / pack_name
    onnx_name = VARIANT_ONNX_NAMES[variant]
    matches = list(model_dir.glob(f"*{onnx_name}"))
    if not matches:
        fail(
            f"Downloaded pack '{pack_name}' but couldn't find {onnx_name} in {model_dir}. "
            f"Contents: {list(model_dir.iterdir()) if model_dir.exists() else 'directory missing'}"
        )
    return matches[0]


def convert_to_coreml(onnx_path: Path, output_path: Path) -> None:
    import numpy as np
    import onnx
    import coremltools as ct
    from onnx2torch import convert
    import torch

    print(f"Loading ONNX model from {onnx_path} ({onnx_path.stat().st_size / 1e6:.1f} MB)...")
    onnx_model = onnx.load(str(onnx_path))
    onnx.checker.check_model(onnx_model)

    print("Converting ONNX -> torch (via onnx2torch)...")
    torch_model = convert(onnx_model)
    torch_model.eval()

    dummy_input = torch.randn(1, 3, 112, 112)
    with torch.no_grad():
        traced = torch.jit.trace(torch_model, dummy_input)

    print("Converting torch -> Core ML (preprocessing baked in: RGB, (px-127.5)/127.5)...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="input_image",
                shape=(1, 3, 112, 112),
                scale=1.0 / 127.5,
                bias=[-1.0, -1.0, -1.0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
    )

    mlmodel.short_description = "ArcFace (w600k_mbf) face embedding — 512-d, on-device"
    mlmodel.input_description["input_image"] = "112x112 RGB aligned face crop"
    mlmodel.output_description["embedding"] = "512-float embedding (not L2-normalized)"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(output_path))
    print(f"Saved {output_path}")
    return mlmodel, onnx_path


def verify_parity(mlmodel, onnx_path: Path) -> None:
    """The real correctness check: feed identical random pixels through both
    the original ONNX graph and the converted Core ML model, and confirm
    they agree. Shape-only checks would miss a channel-order or scale bug —
    exactly the kind of mistake that silently wrecks ArcFace accuracy
    without ever throwing an error.
    """
    import numpy as np
    import onnxruntime as ort
    from PIL import Image

    print("\nVerifying ONNX <-> Core ML numerical parity on random input...")
    rng = np.random.default_rng(0)
    pixels = rng.integers(0, 256, size=(112, 112, 3), dtype=np.uint8)

    sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    onnx_input_name = sess.get_inputs()[0].name
    chw = pixels.astype(np.float32).transpose(2, 0, 1)[None]
    normalized = (chw - 127.5) / 127.5
    onnx_out = sess.run(None, {onnx_input_name: normalized})[0].flatten()

    pil_image = Image.fromarray(pixels, mode="RGB")
    prediction = mlmodel.predict({"input_image": pil_image})
    coreml_out = np.array(prediction["embedding"]).flatten()

    if onnx_out.shape != (512,) or coreml_out.shape != (512,):
        fail(f"Unexpected output shape: onnx={onnx_out.shape}, coreml={coreml_out.shape} (expected (512,))")

    cosine = float(np.dot(onnx_out, coreml_out) / (np.linalg.norm(onnx_out) * np.linalg.norm(coreml_out)))
    print(f"ONNX vs Core ML cosine similarity: {cosine:.6f}  (expect > 0.999)")
    if cosine < 0.999:
        fail(
            "Parity check failed — the converted model disagrees with the original. "
            "Most likely cause: preprocessing mismatch (channel order RGB vs BGR, or "
            "scale/bias). Do not use this model until this passes."
        )
    print("Parity check passed. The conversion is numerically correct.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", choices=sorted(VARIANT_ONNX_NAMES), default="w600k_mbf")
    parser.add_argument("--onnx-path", default=None, help="Skip auto-download; use this local .onnx file instead.")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="Output .mlpackage path.")
    parser.add_argument("--skip-verify", action="store_true", help="Skip the ONNX/Core ML parity check.")
    args = parser.parse_args()

    onnx_path = locate_or_download_onnx(args.variant, args.onnx_path)
    mlmodel, onnx_path = convert_to_coreml(onnx_path, Path(args.output))

    if not args.skip_verify:
        verify_parity(mlmodel, onnx_path)

    print(f"\nDone. Model ready at: {args.output}")
    print("Next: add this file to the Xcode project (glance/Models/ArcFace.mlpackage) if not auto-picked-up,")
    print("then build — ArcFaceEmbedder.swift will load it from the app bundle at runtime.")


if __name__ == "__main__":
    main()
