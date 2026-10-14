"""Fits every table stop with the stage model (AB-T-0241 step 2) into work/fit.json. Chains of neighbouring stops
warm-start each other. `python fit.py [family …]` fits those families (all by default) and keeps finished stops between
runs; PROCS sets the processes, NFEV and HEAVY_NFEV the iterations."""
import numpy as np, acr, stage, json, sys, os, time
from multiprocessing import Pool
from scipy.optimize import least_squares
GREYS = np.array([k * 289 + k * 17 + k for k in range(17)])

def family_of(i):
    if i < 81: return "wb"
    if i < 102: return "exposure"
    if i < 111: return "whites"
    if i < 120: return "blacks"
    if i < 129: return "saturation"
    if i < 138: return "vibrance"
    if i < 187: return "contrast"
    if i < 236: return "highlights"
    if i < 285: return "shadows"
    if i < 405: return "mixer"
    if i < 435: return "calibration"
    if i < 455: return "parametric"
    if i < 743: return "grading"
    return "grading luminance"
BLOCKS = {"wb": (["matrix", "hue", "tone"], 1.0), "exposure": (["tone"], 1.0), "whites": (["tone"], 1.0), "blacks": (["tone"], 1.0),
          "saturation": (["hue", "tone"], 1.8), "vibrance": (["hue", "tone"], 1.0), "contrast": (["tone"], 1.0),
          "highlights": (["tone"], 1.0), "shadows": (["tone"], 1.0), "mixer": (["hue"], 1.0), "calibration": (["matrix", "hue"], 1.0),
          "parametric": (["tone"], 1.0), "grading": (["hue", "tint"], 1.8), "grading luminance": (["tone"], 1.0)}

def grey_curve(idx):
    ys = acr.T[idx][GREYS, 1] / 255
    yk = np.interp(stage.UF, acr.LEVELS, ys)
    return np.log(np.maximum(np.diff(np.maximum.accumulate(yk)), 1e-4))

def starts(idx, blocks, warm):
    base = stage.identity(blocks)
    out = [base]
    if "tone" in blocks:
        k = 0
        for b in blocks:
            if b == "tone": break
            k += stage.SIZES[b]
        for wl in ([2.0, -1.0, -1.0], [-1.0, 2.0, -1.0], [-1.0, -1.0, 2.0]):
            s = base.copy(); s[k:k + 3] = wl; s[k + 4 + stage.KB:k + stage.SIZES["tone"]] = grey_curve(idx); out.append(s)
    if warm is not None: out.append(np.asarray(warm))
    return out

HEAVY = {"grading", "wb", "saturation", "vibrance"}
SUB = np.random.default_rng(7).choice(4913, 1500, replace=False)
def fit_stop(idx, warm, nfev):
    fam = family_of(idx)
    blocks, g = BLOCKS[fam]
    if fam in HEAVY:
        # Many parameters: fit on a fixed subsample of the grid, from the neighbouring stop (or the identity).
        pin = stage.PIN[SUB]; target = acr.T[idx][SUB]
        def resid(q): return (stage.evaluate(q, blocks, g, pin) - target).ravel()
        tries = [np.asarray(warm)] if warm is not None else [s for s in starts(idx, blocks, None)[:2]]
        nfev = int(os.environ.get("HEAVY_NFEV", "60"))
    else:
        def resid(q): return (stage.evaluate(q, blocks, g) - acr.T[idx]).ravel()
        tries = starts(idx, blocks, warm)
    best = None
    for s in tries:
        try:
            r = least_squares(resid, s, loss="soft_l1", f_scale=1.5, max_nfev=nfev)
        except Exception as e:
            continue
        if best is None or r.cost < best.cost: best = r
    return best.x

def run_chain(args):
    chain, nfev, warm0 = args
    out, warm = {}, warm0
    for idx in chain:
        p = fit_stop(idx, warm, nfev)
        out[idx] = p.tolist(); warm = p
    return out

def chains():
    c = []
    out_from = lambda zero, lo, hi: [list(range(zero - 1, lo - 1, -1)), list(range(zero + 1, hi + 1))]
    c += out_from(91, 81, 101)
    for start in (102, 111, 120, 129): c += out_from(start + 4, start, start + 8)
    for start in (138, 187, 236):
        for row in range(7): b = start + row * 7; c += out_from(b + 3, b, b + 6)
    for s in range(24 + 6 + 4 + 4):
        b = (285 + 5 * s) if s < 24 else (405 + 5 * (s - 24)) if s < 30 else (435 + 5 * (s - 30)) if s < 34 else (743 + 5 * (s - 34))
        c += out_from(b + 2, b, b + 4)
    for base in [455 + w * 36 for w in range(2)] + [527 + w * 36 for w in range(4)] + [671 + w * 36 for w in range(2)]:
        for hue in range(12): c.append([base + hue * 3 + s for s in range(3)])
    return [ch for ch in c if ch]

def wb_chains():
    center = [[r * 9 + 4 for r in range(3, -1, -1)], [r * 9 + 4 for r in range(5, 9)]]
    rows = []
    for r in range(9):
        rows.append([r * 9 + col for col in range(3, -1, -1)]); rows.append([r * 9 + col for col in range(5, 9)])
    return center, rows

if __name__ == "__main__":
    nfev = int(os.environ.get("NFEV", "300")); procs = int(os.environ.get("PROCS", "8"))
    only = set(sys.argv[1:])
    results = {}
    OUT = os.path.join(acr.WORK, "fit.json")
    if os.path.exists(OUT): results = {int(k): v for k, v in json.load(open(OUT)).items()}
    t0 = time.time()
    todo = [ch for ch in chains() if not only or family_of(ch[0]) in only]
    with Pool(procs) as pool:
        for res in pool.imap_unordered(run_chain, [(ch, nfev, None) for ch in todo]):
            results.update(res); json.dump(results, open(OUT, "w"))
            print(f"{len(results)} stops fitted, {time.time() - t0:.0f} s", flush=True)
        if not only or "wb" in only:
            center, rows = wb_chains()
            for res in pool.imap_unordered(run_chain, [(ch, nfev, None) for ch in center]):
                results.update(res)
            json.dump(results, open(OUT, "w"))
            args = []
            for ch in rows:
                r = ch[0] // 9
                args.append((ch, nfev, results.get(r * 9 + 4)))
            for res in pool.imap_unordered(run_chain, args):
                results.update(res); json.dump(results, open(OUT, "w"))
                print(f"{len(results)} stops fitted, {time.time() - t0:.0f} s", flush=True)
