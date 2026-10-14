"""Colour maths and the reference tables for fitting Camera Raw (AB-T-0241).

The reference is Compositor's Photoshop-captured Camera Raw tables (CRT3), which this repository does not hold: point
CRFIT_TABLES at a copy, e.g. `git -C ../PixelAgencyEditor show 4e33e99:Sources/PixelAgencyEditorKit/Resources/CameraRawTables.bin`.
"""
import os, lzma, numpy as np

WORK = os.environ.get("CRFIT_WORK", os.path.join(os.getcwd(), "work"))
os.makedirs(WORK, exist_ok=True)
N = 17

def load_tables(path):
    """CRT3 → (763, 4913, 3) floats, 0…255: [table, color (red slowest), channel]."""
    raw = open(path, "rb").read()
    assert raw[:4] == b"CRT3", "not a CRT3 file"
    f = lambda at: raw[at] | raw[at + 1] << 8
    size, count, step = f(4), f(6), f(8)
    assert size == N
    cells = N ** 3
    planes = np.frombuffer(lzma.decompress(raw[10:]), dtype=np.uint8).reshape(count, 3, cells)
    running = np.cumsum(planes.astype(np.int64), axis=2) % 256
    delta = np.where(running >= 128, running - 256, running) * step
    level = np.round(np.arange(N) * 255 / (N - 1)).astype(np.int64)
    idx = np.arange(cells)
    axes = [level[idx // (N * N)], level[(idx // N) % N], level[idx % N]]
    out = np.empty((count, cells, 3))
    for c in range(3): out[:, :, c] = np.clip(axes[c][None, :] + delta[:, c, :], 0, 255)
    return out

_cache = os.path.join(WORK, "tables.npy")
if not os.path.exists(_cache):
    np.save(_cache, load_tables(os.environ["CRFIT_TABLES"]))
T = np.load(_cache)

LEVELS = np.round(np.arange(N) * 255 / (N - 1)) / 255
G = np.stack(np.meshgrid(LEVELS, LEVELS, LEVELS, indexing="ij"), -1).reshape(-1, 3)

def dec(v): v = np.asarray(v, float); return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)
def enc(v): v = np.asarray(v, float); return np.where(v <= 0.0031308, v * 12.92, 1.055 * np.maximum(v, 0) ** (1 / 2.4) - 0.055)

SRGB_TO_XYZ = np.array([[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750], [0.0193339, 0.1191920, 0.9503041]])
BRADFORD_D65_D50 = np.array([[1.0478112, 0.0228866, -0.0501270], [0.0295424, 0.9904844, -0.0170491], [-0.0092345, 0.0150436, 0.7521316]])
XYZ_D50_TO_PROPHOTO = np.linalg.inv(np.array([[0.7976749, 0.1351917, 0.0313534], [0.2880402, 0.7118741, 0.0000857], [0.0, 0.0, 0.8252100]]))
S2P = XYZ_D50_TO_PROPHOTO @ BRADFORD_D65_D50 @ SRGB_TO_XYZ
S2P = S2P / S2P.sum(1, keepdims=True)        # white stays white exactly
P2S = np.linalg.inv(S2P)
LUMA = np.array([0.2126, 0.7152, 0.0722])
PPY = np.array([0.2880402, 0.7118741, 0.0000857])

def to_pp(srgb): return dec(srgb) @ S2P.T
def from_pp(pp): return enc(np.clip(pp @ P2S.T, 0, 1))

def rgbtone(rgb, f):
    """DNG SDK RefBaselineRGBTone: the curve on the largest and smallest channel, the middle one kept between them."""
    out = np.empty_like(rgb)
    order = np.argsort(rgb, axis=-1)
    lo = np.take_along_axis(rgb, order[..., :1], -1)[..., 0]
    mi = np.take_along_axis(rgb, order[..., 1:2], -1)[..., 0]
    hi = np.take_along_axis(rgb, order[..., 2:], -1)[..., 0]
    flo, fhi = f(lo), f(hi)
    span = hi - lo
    t = np.where(span > 1e-12, (mi - lo) / np.where(span > 1e-12, span, 1), 0)
    np.put_along_axis(out, order, np.stack([flo, flo + (fhi - flo) * t, fhi], -1), -1)
    return out
