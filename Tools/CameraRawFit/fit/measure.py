"""PCAlgo's Camera Raw develop (through cr-measure) vs the reference tables at every table stop, per slider: max, p99 and
mean of |255 · PCAlgo − table| over every channel of every grid color. `python measure.py <name>` writes
work/<name>-report.json."""
import json, sys, time, numpy as np, acr, grid
from collections import OrderedDict
tables = acr.T
stops = grid.stops()
todo = [(i, s, lay) for i, _, _, s, lay in stops if s is not None]
t0 = time.time()
got = grid.run([(s, lay) for _, s, lay in todo], sys.argv[1] if len(sys.argv) > 1 else "measure")
print(f"{len(todo)} develop runs in {time.time() - t0:.0f} s", file=sys.stderr)
out = {}
for (i, _, _), g in zip(todo, got): out[i] = g
identity = grid.GRID * 255
by = OrderedDict()
for i, slider, label, s, lay in stops:
    pc = out.get(i, identity)         # no PCAlgo stage (Calibration): it leaves the color as it is
    d = np.abs(pc - tables[i])
    by.setdefault(slider, []).append((label, d))
rows = []
for slider, parts in by.items():
    allv = np.concatenate([d.ravel() for _, d in parts])
    worst_stop = max(parts, key=lambda p: np.percentile(p[1], 99))
    rows.append(dict(slider=slider, stops=len(parts), max=float(allv.max()), p99=float(np.percentile(allv, 99)),
                     mean=float(allv.mean()), worst_stop=worst_stop[0], worst_stop_p99=float(np.percentile(worst_stop[1], 99))))
json.dump(rows, open(grid.SP + f"/{sys.argv[1] if len(sys.argv) > 1 else 'measure'}-report.json", "w"), indent=1)
print(f"{'slider':34s} {'stops':>5s} {'max':>6s} {'p99':>6s} {'mean':>6s}  worst stop (p99)")
for r in rows:
    print(f"{r['slider']:34s} {r['stops']:5d} {r['max']:6.1f} {r['p99']:6.1f} {r['mean']:6.2f}  {r['worst_stop']} ({r['worst_stop_p99']:.1f})")
