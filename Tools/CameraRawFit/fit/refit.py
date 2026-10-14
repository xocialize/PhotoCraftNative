"""Second pass (AB-T-0241): refits a family's stops on the full grid, near-neutral colours weighted up (3× for greys,
which matter most in photos), warm-started from work/fit.json; a block new to the family starts at the identity, and
per-channel curves at the table's grey ramp. `python refit.py <family> <block,block,…> [hue gamma]` adds the family's
stops to work/refit.json, which export.py prefers. White balance and Calibration went through it as
`refit.py wb matrix,curves,hue` and `refit.py calibration matrix,curves,hue`, Saturation as
`refit.py saturation chroma,hue,tone 1.8` and Vibrance as `refit.py vibrance hue,tone`."""
import numpy as np, json, os, sys, acr, stage, fit as fit_all
from multiprocessing import Pool
from scipy.optimize import least_squares
FITS = {int(k): v for k, v in json.load(open(os.path.join(acr.WORK, "fit.json"))).items()}
OUT = os.path.join(acr.WORK, "refit.json")
_, SAT, _ = stage.rgb2hsv(acr.G)
WEIGHT = (1 + 2 * (1 - SAT))[:, None]
GREYS = np.array([k * 289 + k * 17 + k for k in range(17)])

def grey_curves(idx):
    """Per-channel curves in linear ProPhoto through the table's greys."""
    out_pp = acr.to_pp(acr.T[idx][GREYS] / 255)
    parts = []
    for ch in range(3):
        yk = np.interp(acr.dec(stage.UF), acr.dec(acr.LEVELS), np.clip(out_pp[:, ch], 0, None))
        parts.append(np.log(np.maximum(np.diff(acr.enc(np.maximum.accumulate(yk))), 1e-4)))
    return np.concatenate(parts)

def chroma_scale(idx):
    """The log chroma scale that alone fits the stop best: where a new chroma block starts."""
    r = least_squares(lambda q: (stage.evaluate(q, ["chroma"]) - acr.T[idx]).ravel(), [0.0], loss="soft_l1", f_scale=1.5)
    return r.x

def start(idx, block, old):
    if block in old: return old[block]
    if block == "curves": return grey_curves(idx)
    if block == "chroma": return chroma_scale(idx)
    return stage.identity([block])

def run(args):
    idx, blocks, gamma, nfev = args
    old_blocks, old_gamma = fit_all.BLOCKS[fit_all.family_of(idx)]
    old = stage.unpack(np.array(FITS[idx]), old_blocks)
    if "chroma" in blocks: old.pop("hue", None)     # the hue map starts over around the new chroma scale
    p0 = np.concatenate([start(idx, b, old) for b in blocks])
    def resid(q): return ((stage.evaluate(q, blocks, gamma) - acr.T[idx]) * WEIGHT).ravel()
    r = least_squares(resid, p0, loss="soft_l1", f_scale=1.5, max_nfev=nfev)
    d = np.abs(stage.evaluate(r.x, blocks, gamma) - acr.T[idx])
    return idx, blocks, r.x.tolist(), float(np.percentile(d, 99)), float(d.mean())

if __name__ == "__main__":
    family, blocks = sys.argv[1], sys.argv[2].split(",")
    gamma = float(sys.argv[3]) if len(sys.argv) > 3 else fit_all.BLOCKS[family][1]
    out = json.load(open(OUT)) if os.path.exists(OUT) else {}
    jobs = [(i, blocks, gamma, int(os.environ.get("NFEV", "100"))) for i in sorted(FITS) if fit_all.family_of(i) == family]
    with Pool(int(os.environ.get("PROCS", "8"))) as pool:
        for idx, b, p, p99, mean in pool.imap_unordered(run, jobs):
            out[str(idx)] = {"blocks": b, "hueGamma": gamma, "params": p}
            json.dump(out, open(OUT, "w"))
            print(f"{idx} {'+'.join(b)}: p99 {p99:.1f} mean {mean:.2f}", flush=True)
