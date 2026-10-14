"""work/fit.json (table index → fitted stage parameters) → PCAlgo's CameraRawModel.json, by slider and stop:
`python export.py ../../../Packages/PCAlgo/Sources/PCAlgo/Tone/CameraRawModel.json`."""
import json, sys, os, numpy as np, acr, fit as fit_all
fits = {int(k): v for k, v in json.load(open(os.path.join(acr.WORK, "fit.json"))).items()}
# The second pass's stops replace the first's (refit.py), with their own blocks.
blocks_of = {}
_refit = os.path.join(acr.WORK, "refit.json")
if os.path.exists(_refit):
    for k, v in json.load(open(_refit)).items(): fits[int(k)] = v["params"]; blocks_of[int(k)] = v["blocks"]
missing = [i for i in range(763) if i not in fits and not (
    i == 91 or i in (106, 115, 124, 133) or (138 <= i < 285 and (i - 138) % 7 == 3) or (285 <= i < 455 and (i - 285) % 5 == 2)
    or (743 <= i < 763 and (i - 743) % 5 == 2) or i == 40)]
assert not missing, f"unfitted stops: {missing}"
def stop(i):
    p = fits.get(i)
    return None if p is None else [float(f"{v:.6g}") for v in p]
FAMILY_STOPS = {}
for i in fits: FAMILY_STOPS.setdefault(fit_all.family_of(i), []).append(i)
def slider(family, stops):
    blocks, gamma = fit_all.BLOCKS[family]
    layouts = {tuple(blocks_of.get(i, blocks)) for i in FAMILY_STOPS[family]}
    assert len(layouts) == 1, f"{family}: stops with different blocks {layouts}"
    return {"blocks": list(layouts.pop()), "hueGamma": gamma, "stops": stops}
grade = lambda base, wheel: [[stop(base + wheel * 36 + h * 3 + s) for s in range(3)] for h in range(12)]
model = {
    "format": 1,
    "about": "Camera Raw's per-pixel sliders fitted to Photoshop's Camera Raw Filter (AB-T-0241, AB-D-0139): the fitted "
             "parameters of PCAlgo's stage model (CameraRawModel.swift) at each slider stop. Model parameters and 1-D curves, "
             "not color tables (AB-D-0130).",
    "toProPhoto": [float(v) for v in acr.S2P.ravel()],
    "fromProPhoto": [float(v) for v in acr.P2S.ravel()],
    "exposure": slider("exposure", [stop(81 + i) for i in range(21)]),
    "whiteBalance": slider("wb", [[stop(r * 9 + c) for c in range(9)] for r in range(9)]),
    "contrast": slider("contrast", [[stop(138 + b * 7 + v) for v in range(7)] for b in range(7)]),
    "highlights": slider("highlights", [[stop(187 + b * 7 + v) for v in range(7)] for b in range(7)]),
    "shadows": slider("shadows", [[stop(236 + b * 7 + v) for v in range(7)] for b in range(7)]),
    "whites": slider("whites", [stop(102 + i) for i in range(9)]),
    "blacks": slider("blacks", [stop(111 + i) for i in range(9)]),
    "saturation": slider("saturation", [stop(120 + i) for i in range(9)]),
    "vibrance": slider("vibrance", [stop(129 + i) for i in range(9)]),
    "mixerLuminance": slider("mixer", [[stop(285 + (0 * 8 + c) * 5 + v) for v in range(5)] for c in range(8)]),
    "mixerSaturation": slider("mixer", [[stop(285 + (1 * 8 + c) * 5 + v) for v in range(5)] for c in range(8)]),
    "mixerHue": slider("mixer", [[stop(285 + (2 * 8 + c) * 5 + v) for v in range(5)] for c in range(8)]),
    "calibration": slider("calibration", [[stop(405 + k * 5 + v) for v in range(5)] for k in range(6)]),
    "parametric": slider("parametric", [[stop(435 + k * 5 + v) for v in range(5)] for k in range(4)]),
    "gradingLuminance": slider("grading luminance", [[stop(743 + k * 5 + v) for v in range(5)] for k in range(4)]),
    "gradingShadows": slider("grading", [grade(455, 0), grade(527, 0), grade(671, 0)]),
    "gradingHighlights": slider("grading", [grade(455, 1), grade(527, 1), grade(671, 1)]),
    "gradingMidtones": slider("grading", [grade(527, 2)]),
    "gradingGlobal": slider("grading", [grade(527, 3)]),
}
out = sys.argv[1]
json.dump(model, open(out, "w"), separators=(",", ":"))
n = sum(len(v) for v in fits.values())
print(f"{len(fits)} stops, {n} parameters, {len(open(out).read())} bytes")
