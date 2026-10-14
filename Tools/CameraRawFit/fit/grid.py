"""The Camera Raw tables' slider grid (CameraRawTables.swift's header) as jobs for PCAlgo's develop, and the comparison."""
import json, subprocess, numpy as np, os, acr
SP = acr.WORK
# Build it with `swift build -c release --product cr-measure` at the repository root.
HARNESS = os.environ.get("CRFIT_HARNESS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".build", "release", "cr-measure"))
N = 17
LEVELS = acr.LEVELS
GRID = acr.G
BRIGHTNESSES = [53, 80, 104, 130, 160, 190, 224]
ADAPTIVE = [-100, -50, -25, 0, 25, 50, 100]
FIFTY = [-100, -50, 0, 50, 100]
MIXER = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
# Grid-on-background layout for the adaptive sliders: 4 px patches 20 px apart, so the patches are 4 % of the picture
# and the background sets its brightness, as on the tables' backgrounds.
PATCH, PITCH = 4, 20
# Before AB-T-0241's fit PCAlgo had no Calibration: the gap was measured against no change.
CALIBRATION_IS_NOOP = False

decode, encode = acr.dec, acr.enc

def statistic(kind, bg):
    """The editor's measure (camera_raw_statistics) of the grid-on-background picture with background grey `bg`."""
    side = int(np.ceil(np.sqrt(len(GRID)))); w, h = side * PITCH, int(np.ceil(len(GRID) / side)) * PITCH
    share = len(GRID) * PATCH * PATCH / (w * h)
    lin = decode(GRID); b = float(decode(bg))
    if kind == "brightest": f = lambda c: c.max(-1); agg = lambda p, q: share * p.mean() + (1 - share) * q; return float(encode(agg(f(lin), b)))
    if kind == "luminance":
        y = lin @ np.array([0.2126, 0.7152, 0.0722]); return float(encode(share * y.mean() + (1 - share) * b))
    top = lin.max(-1)
    return float(encode(np.exp(share * np.log(top + 3e-4).mean() + (1 - share) * np.log(b + 3e-4)) - 3e-4))

def background(kind, target):
    lo, hi = 0.0, 1.0
    for _ in range(60):
        mid = (lo + hi) / 2
        if statistic(kind, mid) * 255 < target: lo = mid
        else: hi = mid
    return (lo + hi) / 2

def stops():
    """Every table: (index, slider, stop label, PCAlgo settings, layout)."""
    out = []
    for r in range(9):
        for c in range(9):
            t, n = -100 + 25 * r, -100 + 25 * c
            out.append((r * 9 + c, "white balance", f"T{t:+d} t{n:+d}", {"temperature": t, "tint": n}, None))
    for i in range(21):
        e = -5 + 0.5 * i
        out.append((81 + i, "exposure", f"{e:+.1f}", {"exposure": e}, None))
    for start, name in [(102, "whites"), (111, "blacks"), (120, "saturation"), (129, "vibrance")]:
        for i in range(9):
            v = -100 + 25 * i
            out.append((start + i, name, f"{v:+d}", {name: v}, None))
    for start, name, kind in [(138, "contrast", "brightest"), (187, "highlights", "logBrightest"), (236, "shadows", "luminance")]:
        for bi, b in enumerate(BRIGHTNESSES):
            bg = background(kind, b)
            for vi, v in enumerate(ADAPTIVE):
                out.append((start + bi * 7 + vi, name, f"B{b} {v:+d}", {name: v}, {"layout": "bg", "bg": bg, "patch": PATCH, "pitch": PITCH}))
    for kind, key in enumerate(["hslLum", "hslSat", "hslHue"]):
        for color in range(8):
            for vi, v in enumerate(FIFTY):
                vals = [0] * 8; vals[color] = v
                out.append((285 + (kind * 8 + color) * 5 + vi, f"mixer {key[3:].lower()} {MIXER[color]}", f"{v:+d}", {key: vals}, None))
    keys = ["calibrationRedHue", "calibrationRedSaturation", "calibrationGreenHue", "calibrationGreenSaturation",
            "calibrationBlueHue", "calibrationBlueSaturation"]
    for k, name in enumerate(["red hue", "red saturation", "green hue", "green saturation", "blue hue", "blue saturation"]):
        for vi, v in enumerate(FIFTY):
            out.append((405 + k * 5 + vi, f"calibration {name}", f"{v:+d}", None if CALIBRATION_IS_NOOP else {keys[k]: v}, None))
    for k, key in enumerate(["curveShadows", "curveDarks", "curveLights", "curveHighlights"]):
        for vi, v in enumerate(FIFTY):
            out.append((435 + k * 5 + vi, f"parametric {key[5:].lower()}", f"{v:+d}", {key: v}, None))
    wheels = ["gradeShadows", "gradeHighlights", "gradeMidtones", "gradeGlobal"]
    for blend_index, blending, count in [(0, 0, 2), (1, 50, 4), (2, 100, 2)]:
        base = 455 + [0, 72, 216][blend_index]
        for wheel in range(count):
            for hue in range(12):
                for si, sat in enumerate([25, 50, 100]):
                    out.append((base + wheel * 36 + hue * 3 + si, f"grading {wheels[wheel][5:].lower()} wheel",
                                f"blend {blending} hue {hue * 30} sat {sat}",
                                {wheels[wheel]: {"hue": hue * 30, "sat": sat, "lum": 0}, "gradeBlending": blending}, None))
    for k, key in enumerate(["gradeShadows", "gradeMidtones", "gradeHighlights", "gradeGlobal"]):
        for vi, v in enumerate(FIFTY):
            out.append((743 + k * 5 + vi, f"grading {key[5:].lower()} luminance", f"{v:+d}", {key: {"hue": 0, "sat": 0, "lum": v}}, None))
    assert sorted(i for i, *_ in out) == list(range(763)), "every table once"
    return out

def run(jobs, name="jobs"):
    """PCAlgo's develop for each (settings, layout); (len, 4913, 3) in 0…255, unrounded."""
    spec = []
    for settings, layout in jobs:
        job = {"settings": settings, "layout": "grid"}
        if layout: job.update(layout)
        spec.append(job)
    path = os.path.join(SP, f"{name}.json"); outp = os.path.join(SP, f"{name}.bin")
    json.dump(spec, open(path, "w"))
    subprocess.run([HARNESS, path, outp], check=True)
    return np.fromfile(outp, dtype=np.float32).reshape(len(jobs), len(GRID), 3).astype(float) * 255
