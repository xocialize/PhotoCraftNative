"""The Camera Raw stage model (the reference for PCAlgo's CameraRawModel.swift), on linear ProPhoto p:
   matrix → per-channel grey curves → chroma scale → hue map (HSV of p^(1/γ)) → tone (grey curve f mixed over RGBTone / per channel / luminance gain) →
   tint (Δc(L) added in p^(1/1.8)). Blocks are optional; parameters are packed per the block list."""
import numpy as np, acr
from scipy.interpolate import PchipInterpolator
from scipy.optimize import least_squares
# HSV with hue in turns (0…1), as the DNG HueSatMap and CameraRawModel.swift take it.
def rgb2hsv(c):
    mx = c.max(-1); mn = c.min(-1); d = mx - mn
    h = np.zeros_like(mx)
    r, g, b = c[..., 0], c[..., 1], c[..., 2]
    nz = d > 1e-12
    hr = np.where(nz & (mx == r), ((g - b) / np.where(nz, d, 1)) % 6, 0)
    hg = np.where(nz & (mx == g) & (mx != r), (b - r) / np.where(nz, d, 1) + 2, 0)
    hb = np.where(nz & (mx == b) & (mx != r) & (mx != g), (r - g) / np.where(nz, d, 1) + 4, 0)
    h = (hr + hg + hb) / 6.0                                   # 0…1
    s = np.where(mx > 1e-12, d / np.where(mx > 1e-12, mx, 1), 0)
    return h, s, mx
def hsv2rgb(h, s, v):
    h6 = (h % 1.0) * 6; i = np.floor(h6).astype(int) % 6; f = h6 - np.floor(h6)
    p = v * (1 - s); q = v * (1 - s * f); t = v * (1 - s * (1 - f))
    out = np.stack([np.choose(i, [v, q, p, p, t, v]), np.choose(i, [t, v, v, q, p, p]), np.choose(i, [p, p, t, v, v, q])], -1)
    return out
NH, SK = 24, np.array([0, 0.25, 0.5, 0.75, 1.0])
KF = 25; UF = np.linspace(0, 1, KF)          # tone curve knots (encoded)
KB = 9;  UB = np.linspace(0, 1, KB)
KG = 13; UG = np.linspace(0, 1, KG)
SIZES = {"matrix": 9, "curves": 3 * (KF - 1), "chroma": 1, "hue": 3 * NH + 3, "tone": 3 + 1 + KB + (KF - 1), "tint": (KG - 2) * 3}
def curve(steps):
    """Monotone encoded curve through UF from cumulative positive steps; returns f on linear light."""
    ys = np.concatenate([[0.0], np.cumsum(np.exp(np.clip(steps, -30, 5)))])
    c = PchipInterpolator(UF, ys)
    return lambda v: acr.dec(np.clip(c(acr.enc(np.clip(v, 0, 1))), 0, None)) + np.maximum(v - 1, 0)
def unpack(p, blocks):
    out, k = {}, 0
    for b in blocks: out[b] = p[k:k + SIZES[b]]; k += SIZES[b]
    return out
def identity(blocks, idx=None, init_curve=None):
    parts = []
    for b in blocks:
        if b == "matrix": parts.append(np.zeros(9))
        elif b == "curves": parts.append(np.tile(np.log(np.diff(UF)), 3))
        elif b == "chroma": parts.append(np.zeros(1))
        elif b == "hue": parts.append(np.concatenate([np.zeros(3 * NH), [0.25, 0.5, 0.75]]))
        elif b == "tone": parts.append(np.concatenate([[0.0, -1.0, 0.0], [0.0], np.zeros(KB), np.log(np.diff(UF)) if init_curve is None else init_curve]))
        elif b == "tint": parts.append(np.zeros((KG - 2) * 3))
    return np.concatenate(parts)
def apply(p, blocks, pin, hue_gamma=1.0):
    q = unpack(p, blocks); x = np.clip(pin, 0, None)
    if "matrix" in q: x = np.clip(x @ (np.eye(3) + q["matrix"].reshape(3, 3)).T, 0, None)
    if "curves" in q:
        c = q["curves"].reshape(3, KF - 1)
        x = np.stack([curve(c[ch])(x[:, ch]) for ch in range(3)], -1)
    if "chroma" in q:
        # Chroma about ProPhoto luminance, scaled by e^k.
        y = (x @ acr.PPY)[:, None]
        x = np.clip(y + (x - y) * np.exp(q["chroma"][0]), 0, None)
    if "hue" in q:
        e = x ** (1 / hue_gamma)
        nodes = q["hue"][:3 * NH].reshape(NH, 3); phi = np.concatenate([[0.0], q["hue"][3 * NH:], [1.0]])
        h, s, v = rgb2hsv(e)
        t = h * NH; i0 = np.floor(t).astype(int) % NH; i1 = (i0 + 1) % NH; t = t - np.floor(t)
        node = nodes[i0] * (1 - t)[:, None] + nodes[i1] * t[:, None]
        w = np.interp(s, SK, phi)
        e = hsv2rgb(h + node[:, 0] * w, np.clip(s * np.exp(node[:, 1] * w), 0, 1), v * np.exp(node[:, 2] * w))
        x = np.clip(e, 0, None) ** hue_gamma
    if "tone" in q:
        t = q["tone"]; wl, al, b, fc = t[:3], t[3], t[4:4 + KB], t[4 + KB:]
        w = np.exp(wl - wl.max()); w = w / w.sum(); a = 1 / (1 + np.exp(-al)); f = curve(fc)
        L = np.maximum((1 - a) * (x @ acr.PPY) + a * x.max(-1), 1e-7)
        B = PchipInterpolator(UB, b)(acr.enc(np.clip(L, 0, 1)))
        lg = np.log2(np.maximum(f(L) / L, 1e-9))[:, None] + B[:, None] * np.log2(np.maximum(x, 1e-7) / L[:, None])
        x = w[0] * acr.rgbtone(x, f) + w[1] * f(x) + w[2] * np.where(x > 0, x * 2.0 ** lg, 0)
    if "tint" in q:
        e = np.clip(x, 0, None) ** (1 / 1.8)
        L = np.clip(np.clip(x @ acr.PPY, 0, None) ** (1 / 1.8), 0, 1)
        knots = np.concatenate([np.zeros((1, 3)), q["tint"].reshape(KG - 2, 3), np.zeros((1, 3))])
        x = np.clip(e + PchipInterpolator(UG, knots)(L), 0, None) ** 1.8
    return x
PIN = acr.to_pp(acr.G)
def evaluate(p, blocks, hue_gamma=1.0, pin=PIN): return acr.from_pp(apply(p, blocks, pin, hue_gamma)) * 255
def fit(idx, blocks, hue_gamma=1.0, p0=None, nfev=300, sel=slice(None)):
    p0 = identity(blocks) if p0 is None else p0
    def resid(q): return (evaluate(q, blocks, hue_gamma, PIN[sel]) - acr.T[idx][sel]).ravel()
    return least_squares(resid, p0, loss="soft_l1", f_scale=1.5, max_nfev=nfev).x
