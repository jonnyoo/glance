#!/usr/bin/env python3
"""Offline regression tests. Never opens cameras, keychains or posts keystrokes."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
IR = "glance/Infrared/"
TESTS = "tools/infrared/"
cases = {
    "result": [IR + "InfraredProbeResult.swift", TESTS + "result_selftest.swift"],
    "reference": [IR + "InfraredReference.swift", TESTS + "reference_selftest.swift"],
    "unlock-policy": [IR + "InfraredReference.swift", IR + "InfraredEnrollment.swift", TESTS + "unlock_policy_selftest.swift"],
    "enrollment": [IR + "InfraredReference.swift", IR + "InfraredEnrollment.swift", "glance/FaceEmbedder.swift",
                   "glance/FaceEnrollmentStore.swift", TESTS + "enrollment_selftest.swift"],
    "injection": ["glance/KeystrokeInjector.swift", TESTS + "injection_selftest.swift"],
    "liveness": ["glance/Liveness/" + name + ".swift" for name in
                 ("LandmarkGeometry", "GeometryLiveness", "GlareCue", "LivenessCues", "LivenessScoring", "LivenessAnalyzer")]
                 + ["tools/liveness_selftest.swift"],
}
cases["glare-crop"] = ["glance/CameraManager.swift", "glance/Liveness/GlareCueExtractor.swift"] + cases["liveness"][:-1] + [TESTS + "glare_crop_selftest.swift"]

with tempfile.TemporaryDirectory(prefix="glance-ir-tests-") as output:
    for name, sources in cases.items():
        binary = str(Path(output) / name)
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", *sources, "-o", binary], cwd=ROOT, check=True)
        subprocess.run([binary], cwd=ROOT, check=True)
    print(f"All {len(cases)} offline regression suites passed.")
